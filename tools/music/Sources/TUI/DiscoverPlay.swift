// Discover's play transaction, as pure decisions.
//
// The safety property this file exists to hold: Discover may delete ONLY the
// library rows it demonstrably created. A first draft of the design swept every
// track of the temp playlist, which deletes pre-owned music whenever a Discover
// album overlaps the user's library. Everything here is shaped so that the
// uncertain case leaves residue rather than deleting.
import Foundation

/// Which of a set of catalog songs the user already has in their library.
/// `owned` maps catalog id -> library id. `unowned` is the deletion candidate
/// set. A song that appears in NEITHER is deliberately excluded from both: the
/// API said nothing about it, and silence is not evidence of absence.
struct LibraryMembership: Equatable {
    var owned: [String: String] = [:]
    var unowned: [String] = []
}

/// GET path for a batched membership check. nil for an empty id list, so callers
/// cannot accidentally issue a query that returns everything.
func libraryMembershipPath(storefront: String, catalogIDs: [String]) -> String? {
    guard !catalogIDs.isEmpty else { return nil }
    return "/v1/catalog/\(storefront)/songs?ids=\(catalogIDs.joined(separator: ","))&include=library"
}

/// Probed live 2026-08-26, both directions: an owned song carries one entry under
/// relationships.library.data whose id is the library id; an unowned song carries
/// an empty array.
///
/// Anything unparseable yields an EMPTY partition rather than a partition that
/// claims everything is unowned — the difference between "nothing to clean up"
/// and "delete all of it".
func parseLibraryMembership(_ data: Data) -> LibraryMembership {
    var out = LibraryMembership()
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = root["data"] as? [[String: Any]] else { return out }
    for row in rows {
        guard let id = row["id"] as? String else { continue }

        // Three-valued on purpose. Every `continue` below is a song the API said
        // nothing useful about, and an unknown must never become deletable.
        //
        // Do NOT collapse this chain with `?? []`. That was the original bug: it
        // turns an absent relationships block, an absent library key, an absent
        // data key, and a non-array data value all into "empty", which reads as
        // "not in the library", which makes the user's own music eligible for
        // deletion. Only an explicitly present empty array proves absence.
        guard let rels = row["relationships"] as? [String: Any] else { continue }
        guard let library = rels["library"] as? [String: Any] else { continue }
        guard let entries = library["data"] as? [[String: Any]] else { continue }

        if entries.isEmpty {
            out.unowned.append(id)                       // proven absent
        } else if let libID = entries.first?["id"] as? String, !libID.isEmpty {
            out.owned[id] = libID                        // proven present
        }
        // else: entries exist but carry no usable id — unknown, so neither.
    }
    return out
}

enum DiscoverReadiness: Equatable { case wait, ready, timedOut }

/// Library adds return 202 and materialize asynchronously — about two seconds for
/// one song (docs/platform-notes.md:229). Poll until the expected count lands, or
/// give up. `>= expected` rather than `==` so an extra row from Apple's side does
/// not deadlock the poll.
func discoverReadiness(observed: Int, expected: Int,
                       elapsed: TimeInterval, timeout: TimeInterval) -> DiscoverReadiness {
    if observed >= expected { return .ready }
    return elapsed >= timeout ? .timedOut : .wait
}

/// 1-based position of a track within the playlist that actually materialized.
///
/// Keyed on CATALOG ID, not title. Repeated titles are common (DJ mixes with
/// several `ID` entries, albums with a reprise, movements sharing a name) and a
/// title match plays whichever came first rather than the row the user selected.
///
/// `materializedCatalogIDs` comes from GET /v1/me/library/playlists/{id}/tracks,
/// in order, reading `attributes.playParams.catalogId` — the materialized
/// playlist, not the catalog list, because unplayable rows never land and every
/// position after a missing row shifts.
///
/// nil means the selected track did not materialize. The caller must report that
/// and play nothing; falling back to 1 plays a different song than the one
/// chosen, and a warning does not make that acceptable.
func discoverPlayPosition(catalogID: String, in materializedCatalogIDs: [String]) -> Int? {
    guard let idx = materializedCatalogIDs.firstIndex(of: catalogID) else { return nil }
    return idx + 1
}

// MARK: - The transaction

/// Serializes the pre-check-through-ledger-write span of `playDiscoverContainer`
/// across concurrent calls IN THIS PROCESS, so two plays racing the same catalog
/// song can't both observe it as unowned and each create a library row before
/// either writes its ledger entry.
///
/// A plain `NSLock` cannot hold across an `await`: nothing guarantees the task
/// resumes on the same thread after a suspension, and unlocking a non-recursive
/// lock from a different thread than the one that locked it is undefined
/// behavior. This is an actor-based async mutex instead: `acquire()`/`release()`
/// are actor-isolated, so the check-and-set of `isLocked` and the enqueue of a
/// waiting continuation are each atomic with respect to every other caller —
/// only one task's synchronous slice of `acquire()` or `release()` runs at a
/// time, and the `await` inside `acquire()` suspends the CALLING task, not the
/// actor, so the actor stays free to service `release()` from whoever currently
/// holds the lock.
///
/// This narrows the race; it does not close it, because a lock is per-process.
/// Two separate `music` processes (the TUI and a CLI run, say) can each pass
/// their own `acquire()`/`release()` uncontested and still both pre-check the
/// same song as unowned. The sweep's retain set (Task 6) is what actually holds
/// the safety property across processes: a library row claimed by any surviving
/// transaction is never deleted, no matter which transaction created it.
actor DiscoverTransactionLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends the caller until it holds the lock exclusively.
    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock to the oldest waiter, or frees it if none are queued.
    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Shared across every call in this process. File-private: nothing outside
/// `playDiscoverContainer` needs to touch it.
private let discoverTransactionLock = DiscoverTransactionLock()

/// What a play attempt resolved to. The caller (Task 7, `DiscoverScene`) turns
/// this into a toast or a push to Now Playing; nothing here owns UI.
enum DiscoverPlayOutcome: Equatable {
    case playing(title: String, position: Int)
    case needsSignIn
    /// Covers both "the pre-check or create request failed" (nothing was
    /// created, there is no residue) and "the transaction was created but its
    /// attribution could not be confirmed" (the playlist is left behind for the
    /// orphan sweep, which is the safe direction — see the module doc).
    case createFailed(String)
    case notReady                  // materialization timed out; playlist left for the sweep
    case selectedTrackMissing      // the chosen row never materialized
    case playFailed(String)
}

/// The outcome of the locked pre-check-through-ledger-write phase: either a
/// terminal `DiscoverPlayOutcome` (nothing left to do) or the identity of a
/// playlist that was created, materialized, and ledgered, ready for the
/// (unlocked) position-resolution + play phase.
private enum DiscoverLockedPhaseResult {
    case failed(DiscoverPlayOutcome)
    case ready(playlistName: String, playlistID: String)
}

/// Steps 1-7 of the transaction (see module doc / design spec "The transaction"),
/// run while `discoverTransactionLock` is held. Never plays, never deletes.
private func discoverPrepareTransaction(title: String,
                                        catalogIDs: [String],
                                        api: RESTAPIBackend,
                                        backend: AppleScriptBackend,
                                        ledgerStore: DiscoverLedgerStore,
                                        storefront: String,
                                        now: @escaping () -> Date,
                                        pollInterval: TimeInterval,
                                        readinessTimeout: TimeInterval) async -> DiscoverLockedPhaseResult {
    // Step 1: guard a user token. No token, no library to ask about.
    guard api.userToken != nil else { return .failed(.needsSignIn) }

    // Step 2: mint the transaction id. Never the album title — two plays of
    // same-titled albums would otherwise collide on the playlist name.
    let txID = UUID().uuidString
    let name = discoverPlaylistPrefix + txID

    // Step 3: pre-check ownership. `membership.owned` is never eligible for
    // deletion, and neither is anything the API said nothing about — only
    // `membership.unowned` is a deletion candidate.
    let membership: LibraryMembership
    do {
        membership = try await api.libraryMembership(catalogIDs: catalogIDs, storefront: storefront)
    } catch {
        if isExpiredToken(error) { return .failed(.needsSignIn) }
        return .failed(.createFailed("membership check failed: \(error.localizedDescription)"))
    }

    // Step 4: create and seed the playlist in one request.
    let playlistID: String
    do {
        playlistID = try await api.createPlaylist(name: name, songIDs: catalogIDs)
    } catch {
        if isExpiredToken(error) { return .failed(.needsSignIn) }
        return .failed(.createFailed(error.localizedDescription))
    }

    // Step 5: poll readiness against the playlist's AppleScript track count. On
    // timeout, return without playing and without deleting — the playlist is
    // left for the sweep, which has the full ledger context this call does not.
    let start = now()
    pollLoop: while true {
        let observed = await discoverReadPlaylistTrackCount(name: name, backend: backend)
        let elapsed = now().timeIntervalSince(start)
        switch discoverReadiness(observed: observed, expected: catalogIDs.count,
                                 elapsed: elapsed, timeout: readinessTimeout) {
        case .ready:
            break pollLoop
        case .timedOut:
            return .failed(.notReady)
        case .wait:
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // Step 6: re-check membership for the unowned candidates ONLY, to capture
    // the library ids that now exist for them. Those, and only those, become
    // createdLibraryIDs — ids that were already owned, or unknown, at the
    // pre-check are never added here, no matter what the re-check says.
    var createdLibraryIDs: [String] = []
    if !membership.unowned.isEmpty {
        do {
            let recheck = try await api.libraryMembership(catalogIDs: membership.unowned, storefront: storefront)
            createdLibraryIDs = Array(recheck.owned.values)
        } catch {
            // Attribution is now uncertain: the playlist exists but we cannot
            // safely say which rows it created. Per the governing rule, leave
            // it un-ledgered — the orphan sweep collects the CONTAINER only,
            // and every library row survives.
            return .failed(.createFailed("could not confirm created rows: \(error.localizedDescription)"))
        }
    }

    // Step 7: write the ledger BEFORE playing, so a crash between here and
    // playback is still recoverable — the sweep sees a real ledger entry
    // instead of an orphan and can delete exactly the rows this transaction
    // created.
    let transaction = DiscoverTransaction(id: txID, playlistName: name, title: title,
                                          createdLibraryIDs: createdLibraryIDs,
                                          createdAt: ISO8601DateFormatter().string(from: now()))
    do {
        try ledgerStore.save(ledgerStore.load() + [transaction])
    } catch {
        return .failed(.createFailed("could not write ledger: \(error.localizedDescription)"))
    }

    return .ready(playlistName: name, playlistID: playlistID)
}

private func isExpiredToken(_ error: Error) -> Bool {
    guard let authError = error as? AuthError else { return false }
    if case .userTokenExpired = authError { return true }
    return false
}

/// Track count of a (possibly not-yet-visible) playlist, read through
/// AppleScript. A failed script or a playlist AppleScript can't see yet both
/// read as 0, which is safe: `discoverReadiness` treats 0 as "not ready" and
/// keeps polling until the timeout, never falsely claiming readiness.
private func discoverReadPlaylistTrackCount(name: String, backend: AppleScriptBackend) async -> Int {
    let esc = escapeAppleScriptString(name)
    guard let raw = try? await backend.runMusic("return (count of tracks of playlist \"\(esc)\") as text")
    else { return 0 }
    return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

/// The materialized tracks of a library playlist, in playlist order, each as
/// its catalog id — `GET /v1/me/library/playlists/{id}/tracks`, walked to the
/// end via `next` the same way `libraryPlaylists()` does.
///
/// A row is kept as an empty-string placeholder rather than dropped when it
/// somehow carries no `playParams.catalogId`: position N in the returned array
/// must line up with AppleScript position N, and dropping a row would shift
/// every later position out from under `discoverPlayPosition`.
private func discoverFetchMaterializedCatalogIDs(api: RESTAPIBackend, playlistID: String) async throws -> [String] {
    var out: [String] = []
    var path: String? = "/v1/me/library/playlists/\(playlistID)/tracks?limit=100"
    while let p = path {
        let (data, status) = try await api.get(p)
        guard (200...299).contains(status) else { throw APIError.requestFailed(status) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        for item in json?["data"] as? [[String: Any]] ?? [] {
            let attrs = item["attributes"] as? [String: Any] ?? [:]
            let catalogId = (attrs["playParams"] as? [String: Any])?["catalogId"] as? String ?? ""
            out.append(catalogId)
        }
        path = json?["next"] as? String
    }
    return out
}

/// The single entry point for playing a Discover album or playlist. Orchestrates
/// Tasks 1-3 (membership, ledger, readiness/position) into one transaction; owns
/// no decision logic of its own — every branch here defers to an already-tested
/// pure function.
///
/// THIS FUNCTION ONLY CREATES. It never deletes a playlist or a library row,
/// including on its own failure paths: a failed transaction leaves its playlist
/// behind on purpose, because at the moment of failure it may not yet know which
/// rows it created, and guessing is exactly how the user's own music gets
/// deleted. Deletion is Task 6's sweep, run separately, with the full ledger.
///
/// - Parameters:
///   - title: display title for the ledger and the `.playing` outcome only —
///     NEVER used as the playlist name or any other identifier.
///   - catalogIDs: every track in the container, in catalog order.
///   - selectedCatalogID: nil plays from the top (position 1); set, it must
///     resolve to a materialized position or the call fails rather than
///     silently playing a different track.
func playDiscoverContainer(title: String,
                           catalogIDs: [String],
                           startingAt selectedCatalogID: String?,
                           api: RESTAPIBackend,
                           backend: AppleScriptBackend,
                           ledgerStore: DiscoverLedgerStore,
                           storefront: String,
                           now: @escaping () -> Date = Date.init,
                           pollInterval: TimeInterval = 0.5,
                           readinessTimeout: TimeInterval = 20) async -> DiscoverPlayOutcome {
    await discoverTransactionLock.acquire()
    let phase = await discoverPrepareTransaction(
        title: title, catalogIDs: catalogIDs, api: api, backend: backend,
        ledgerStore: ledgerStore, storefront: storefront, now: now,
        pollInterval: pollInterval, readinessTimeout: readinessTimeout)
    await discoverTransactionLock.release()

    let playlistName: String
    let playlistID: String
    switch phase {
    case .failed(let outcome):
        return outcome
    case .ready(let name, let id):
        playlistName = name
        playlistID = id
    }

    // Step 8: resolve position on the MATERIALIZED playlist, never the catalog
    // list — unplayable rows never land and every position after a missing row
    // shifts.
    let materializedCatalogIDs: [String]
    do {
        materializedCatalogIDs = try await discoverFetchMaterializedCatalogIDs(api: api, playlistID: playlistID)
    } catch {
        // The transaction is already ledgered; only the read that resolves a
        // starting position failed. The playlist is a legitimate transaction,
        // not an orphan, so it is left exactly as ledgered for a future sweep.
        return .playFailed("could not read materialized tracks: \(error.localizedDescription)")
    }

    let position: Int
    if let selected = selectedCatalogID {
        guard let resolved = discoverPlayPosition(catalogID: selected, in: materializedCatalogIDs) else {
            // Never fall back to position 1 — that plays a different song than
            // the one the user chose.
            return .selectedTrackMissing
        }
        position = resolved
    } else {
        position = 1
    }

    // Step 9: play by position via AppleScript, reusing the codebase's existing
    // AppleScript string escaping rather than writing a second one.
    let esc = escapeAppleScriptString(playlistName)
    do {
        _ = try await backend.runMusic("play track \(position) of playlist \"\(esc)\"")
    } catch {
        return .playFailed(error.localizedDescription)
    }

    return .playing(title: title, position: position)
}
