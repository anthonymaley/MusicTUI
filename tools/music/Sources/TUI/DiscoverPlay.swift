// Discover's play transaction, as pure decisions.
//
// The safety property this file exists to hold: Discover NEVER deletes a
// library row. A membership pre-check and a re-check after creation can prove
// a row appeared between two observations, but never that this transaction
// created it — a user adding the same catalog song in Music.app during that
// window produces the identical library id, and a sweep keyed on that
// evidence would delete music they deliberately added. Apple exposes no
// authorship for a library row, and no lock helps, because the user is not a
// transaction. So the songs this feature adds stay in the library,
// permanently. Only the temp playlist CONTAINER is ever removed later, by
// its own name prefix — exactly as the shipped `sweepQueuePlaylists` does for
// `__queue__ `.
import Foundation

let discoverPlaylistPrefix = "__discover__ "

/// The separator between the transaction uuid and the display title in a
/// Discover playlist's name: "__discover__ <uuid> — <title>". Without a
/// ledger there is no title mapping stored elsewhere, so the title has to
/// live in the name itself for Now Playing to show it.
let discoverPlaylistNameSeparator = " — "

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

// MARK: - Play from here

/// The id list for "play from here": the container sliced from the selected
/// row to its end.
///
/// This is the whole mechanism behind track-level `Enter`, and it is why the
/// feature stopped being blocked. The deferral reason recorded in the docs was
/// that the only bounded play form starts a playlist from its beginning — true,
/// and unchanged. Slicing sidesteps it rather than fighting it: the slice's
/// beginning IS the selected track, so `play playlist` on the sliced container
/// starts where the user pointed and still stops at the album's end.
///
/// An out-of-range index returns an empty slice rather than clamping. Clamping
/// would play position 1, i.e. a DIFFERENT song than the one chosen, which is
/// the single failure the design doc refuses outright ("report and play
/// nothing"). The caller's non-empty guard turns the empty slice into a toast.
func discoverPlaySlice(catalogIDs: [String], from index: Int) -> [String] {
    guard index >= 0, index < catalogIDs.count else { return [] }
    return Array(catalogIDs[index...])
}

/// The ordered AppleScript commands one Discover play emits.
///
/// Kept pure and separate because `playDiscoverContainer` takes a concrete
/// `AppleScriptBackend`, so the emission itself cannot be asserted in a unit
/// test — the ORDER can, and the order is the part that carries the promise.
///
/// Two commands, never one block: combining a `set` with a `play` in a single
/// script is what produced parameter error -50 in the shipped playlist code
/// (see `PlaylistCommands`' "Split into separate calls" comment), so they stay
/// separate `runMusic` calls.
///
/// `disableShuffle` defaults to off at the call site that plays a whole
/// container, leaving `p` exactly as it shipped.
func discoverPlayScripts(playlistName: String, disableShuffle: Bool) -> [String] {
    let esc = escapeAppleScriptString(playlistName)
    var scripts: [String] = []
    if disableShuffle {
        scripts.append("set shuffle enabled to false")
    }
    scripts.append("play playlist \"\(esc)\"")
    return scripts
}

// MARK: - The transaction

/// What a play attempt resolved to. The caller (Task 7, `DiscoverScene`) turns
/// this into a toast or a push to Now Playing; nothing here owns UI.
enum DiscoverPlayOutcome: Equatable {
    case playing(title: String)
    case needsSignIn
    /// The create request failed outright (nothing was created, there is no
    /// residue).
    case createFailed(String)
    case notReady                  // materialization timed out; playlist left behind
    case playFailed(String)
}

func isExpiredToken(_ error: Error) -> Bool {
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

/// The single entry point for playing a Discover album or playlist. Creates a
/// temp playlist, waits for it to materialize, and plays it — the whole
/// container, from the top, bounded to its own tracks. It never deletes a
/// playlist or a library row, on any path — see the module doc for why.
///
/// - Parameters:
///   - title: folded into the playlist name (after `discoverPlaylistNameSeparator`)
///     so Now Playing can show it — NEVER used as an identifier.
///   - catalogIDs: every track in the container, in catalog order — or, for
///     track-level `Enter`, the slice of it from the selected row onward
///     (`discoverPlaySlice`).
///   - disableShuffle: turns Music's shuffle off immediately before the play.
///     Track-level `Enter` passes true, because it promises the SELECTED track
///     starts and `play playlist` honours `shuffle enabled` (measured
///     2026-08-30). `p` passes false by default and is unchanged: the producer
///     scoped this guard to Enter alone rather than have "play all" reach out
///     and clear a setting the user turned on elsewhere.
func playDiscoverContainer(title: String,
                           catalogIDs: [String],
                           api: RESTAPIBackend,
                           backend: AppleScriptBackend,
                           storefront: String,
                           disableShuffle: Bool = false,
                           now: @escaping () -> Date = Date.init,
                           pollInterval: TimeInterval = 0.5,
                           readinessTimeout: TimeInterval = 20) async -> DiscoverPlayOutcome {
    // Step 1: guard a user token. No token, no library to add to.
    guard api.userToken != nil else { return .needsSignIn }

    // Step 2: mint the playlist name. The uuid keeps two plays of same-titled
    // albums from colliding on the playlist name; the title after the
    // separator is display only, read back out by `cleanContextName`.
    let txID = UUID().uuidString
    let name = discoverPlaylistPrefix + txID + discoverPlaylistNameSeparator + title

    // Step 3: create and seed the playlist in one request. The returned id
    // is not needed after this: readiness below polls by NAME through
    // AppleScript, and playback plays the playlist by name too.
    do {
        _ = try await api.createPlaylist(name: name, songIDs: catalogIDs)
    } catch {
        if isExpiredToken(error) { return .needsSignIn }
        return .createFailed(error.localizedDescription)
    }

    // Step 4: poll readiness against the playlist's AppleScript track count. On
    // timeout, return without playing; the playlist is left behind.
    let start = now()
    pollLoop: while true {
        let observed = await discoverReadPlaylistTrackCount(name: name, backend: backend)
        let elapsed = now().timeIntervalSince(start)
        switch discoverReadiness(observed: observed, expected: catalogIDs.count,
                                 elapsed: elapsed, timeout: readinessTimeout) {
        case .ready:
            break pollLoop
        case .timedOut:
            return .notReady
        case .wait:
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // Step 5: play the playlist itself, not a track position within it.
    // `play track N of playlist "X"` is a track-play command that merely
    // NAMES a playlist — Music.app discards the playlist as context and
    // roots the queue in the library, so playback runs past the end of the
    // album into unrelated artists instead of stopping. `play playlist "X"`
    // establishes the playlist as `current playlist`, which plays every
    // track and then stops. Measured live 2026-08-25; `set current playlist`
    // is not writable (-10006), so this is the only lever. Reuses the
    // codebase's existing AppleScript string escaping rather than writing a
    // second one.
    do {
        for script in discoverPlayScripts(playlistName: name, disableShuffle: disableShuffle) {
            _ = try await backend.runMusic(script)
        }
    } catch {
        return .playFailed(error.localizedDescription)
    }

    return .playing(title: title)
}
