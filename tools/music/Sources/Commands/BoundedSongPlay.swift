// tools/music/Sources/Commands/BoundedSongPlay.swift
import Foundation

/// The outcome of a bounded single-song play.
///
/// Deliberately NOT `BoundedAlbumOutcome`. A song has no album ambiguity, and
/// it has two failure states an album path never meets: an unreadable source
/// identifier and an unconfirmable container. Anthony, 2026-09-03: distinguish
/// "persistent ID unreadable" from "container read failed" in tests and user
/// messages, while both remain fail-closed.
enum SongPlayOutcome: Equatable {
    case playing
    /// No library row matched the query.
    case notFound
    /// Rows matched, but every one of them is pre-release or removed.
    case nonePlayable(matched: Int)
    /// The chosen row's `persistent ID` could not be read. Nothing was built:
    /// there is no identifier to confirm a container by, so none is made.
    case identifierUnreadable
    /// The container was built, but reading its own track ids failed. Distinct
    /// from a mismatch: we do not know what is in there, rather than knowing it
    /// is wrong. Rolled back either way.
    case containerReadFailed
    /// The container was built and read, and it does not hold exactly the one
    /// track we seeded it with. This is the state a count check cannot reach:
    /// `buildContainer` already agreed the count was 1.
    case containerIdentityMismatch(expected: String)
    case buildFailed(containerRemoved: Bool)
    case playFailed(containerRemoved: Bool)
    case watcherFailed(containerRemoved: Bool)
}

/// The container name for a bounded-playback container.
///
/// Shares the `__album__ ` prefix with the album path by decision (Anthony,
/// 2026-09-03, in CONTEXT Key Decisions): a second prefix would have to be
/// taught to the sweep scripts and the watcher allowlist, which are delete
/// paths, and expanding deletion scope is not worth a naming nicety. The
/// container is a temporary bounded-playback container internally; what the
/// user sees is the bare title, because `cleanContextName` strips the prefix
/// and the uuid.
func boundedContainerName(title: String, uuid: String) -> String {
    albumContainerName(title: title, uuid: uuid)
}

/// Play exactly one song, bounded, and stop when it ends.
///
/// "Play this song" means exactly one song (Anthony, 2026-09-03): continuing
/// into the library or into the song's own album adds an intent the user did
/// not state. The named loss is that playback stops rather than continuing.
///
/// The row is addressed by `persistent ID`, never by Library index. A single
/// song is often played immediately after being added from the catalog, and a
/// freshly synced row's index is the least trustworthy handle available then
/// (measured 2026-09-03: not resolvable at all until t+3s). Duplicating a track
/// preserves its persistent ID, measured four times on two albums the same day,
/// which is what makes the container confirmable by identity.
///
/// Fail closed at every step. There is deliberately no fallback to
/// `playQueueTrack(playlist: "Library", ...)`: that is the unbounded form this
/// work removes, and falling back to it would silently restore the defect.
func playBoundedSong(title: String,
                     rows: [LibraryAlbumRow],
                     readIdentifier: (Int) -> String?,
                     uuid: String = UUID().uuidString,
                     run: ScriptRunner,
                     launch: @escaping ProcessLauncher = detachedLaunch)
    -> SongPlayOutcome {

    guard !rows.isEmpty else { return .notFound }
    guard let position = firstPlayablePosition(rows) else {
        return .nonePlayable(matched: rows.count)
    }

    // Read the stable handle BEFORE building anything. An identifier we cannot
    // read is an identifier we cannot confirm the container by, and an
    // unconfirmable container is exactly what this path refuses to play.
    guard let rawID = readIdentifier(position) else { return .identifierUnreadable }
    let identifier = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { return .identifierUnreadable }

    // Same recovery the album path gets, at the same point in the sequence:
    // collect containers a crashed or killed watcher left behind BEFORE this
    // play creates its own. Its result is intentionally discarded, so a failed
    // or inconclusive sweep never blocks this play.
    _ = run(albumStaleSweepScript())

    let name = boundedContainerName(title: title, uuid: uuid)

    // `confirm` runs after the container is built and read, and before a note
    // plays. It is the only place the wrong-track case is caught: the build's
    // own check counts tracks, and a container holding one WRONG track counts
    // as one.
    var refusal: SongPlayOutcome?
    let outcome = playBoundedContainer(
        name: name, seed: .persistentID(identifier), uuid: uuid,
        run: run, launch: launch,
        confirm: { ids in
            guard let ids else {
                refusal = .containerReadFailed
                return false
            }
            guard ids == [identifier] else {
                refusal = .containerIdentityMismatch(expected: identifier)
                return false
            }
            return true
        })

    switch outcome {
    case .playing:
        return .playing
    case .buildFailed(let removed):
        // A refusal recorded by `confirm` is more specific than the generic
        // build failure it is reported as, so it wins. `removed` is not lost:
        // both refusal states roll the container back, and when that rollback
        // itself fails the generic `.buildFailed(containerRemoved: false)`
        // still surfaces through the message.
        if let refusal, removed { return refusal }
        return .buildFailed(containerRemoved: removed)
    case .playFailed(let removed):
        return .playFailed(containerRemoved: removed)
    case .watcherFailed(let removed):
        return .watcherFailed(containerRemoved: removed)
    }
}

/// User facing text for a song outcome, or nil when playback started.
///
/// Every failure names its own stage. The two unreadable states are worded
/// differently on purpose: one means we never had a handle on the track, the
/// other means we had one and then could not verify what we built.
func songOutcomeMessage(_ outcome: SongPlayOutcome, title: String) -> String? {
    switch outcome {
    case .playing:
        return nil
    case .notFound:
        return "No tracks found matching '\(title)'"
    case .nonePlayable(let matched):
        return "Found \(matched) track(s) matching '\(title)', but none are playable yet (pre-release or removed)."
    case .identifierUnreadable:
        return "Could not read a stable identifier for '\(title)', so nothing was played. "
            + "Nothing was created either. Try again, and if it persists the track may not be fully synced yet."
    case .containerReadFailed:
        return "Could not verify the temporary playlist built for '\(title)', so nothing was played. "
            + "It has been removed."
    case .containerIdentityMismatch:
        return "The temporary playlist built for '\(title)' did not hold that track, so nothing was played. "
            + "It has been removed."
    case .buildFailed(let removed):
        return removed
            ? "Could not build a temporary playlist for '\(title)', so nothing was played."
            : "Could not build a temporary playlist for '\(title)', and a leftover playlist may remain. "
                + "Run: music playlist cleanup"
    case .playFailed(let removed):
        return removed
            ? "Built a temporary playlist for '\(title)' but could not play it."
            : "Built a temporary playlist for '\(title)', could not play it, and a leftover playlist may remain. "
                + "Run: music playlist cleanup"
    case .watcherFailed(let removed):
        return removed
            ? "Could not start the cleanup helper for '\(title)', so playback was stopped rather than left unbounded."
            : "Could not start the cleanup helper for '\(title)', and a leftover playlist may remain. "
                + "Run: music playlist cleanup"
    }
}
