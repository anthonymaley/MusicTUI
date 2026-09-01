// tools/music/Sources/Commands/BoundedAlbumPlay.swift
import Foundation

enum BoundedAlbumOutcome: Equatable {
    case playing
    case notFound
    case nonePlayable(matched: Int)
    /// Container creation or seeding failed. `containerRemoved` is false when
    /// the rollback delete ALSO failed, so a partial container may remain in
    /// the user's library and the caller must not claim otherwise.
    case buildFailed(containerRemoved: Bool)
    case playFailed(containerRemoved: Bool)
    case watcherFailed(containerRemoved: Bool)
}

/// The ONE bounded album implementation. Both `--album` and positional album
/// resolution call this, so equivalent album requests cannot diverge.
///
/// Fail closed throughout. There is deliberately no fallback to
/// `playQueueTrack(playlist: "Library", ...)`: that is the unbounded form this
/// work exists to remove, and falling back to it would silently restore the
/// defect after the command has promised a boundary.
///
/// `shuffle enabled` is never written. With shuffle on the album plays shuffled
/// WITHIN its container, which is bounded and strictly better than shuffling the
/// whole library, and it does not clear a setting the user turned on elsewhere.
func playBoundedAlbum(title: String,
                      rows: [LibraryAlbumRow],
                      uuid: String = UUID().uuidString,
                      run: ScriptRunner,
                      launch: @escaping ProcessLauncher = detachedLaunch)
    -> BoundedAlbumOutcome {

    switch decideAlbumPlay(rows) {
    case .notFound:
        return .notFound
    case .nonePlayable(let matched):
        return .nonePlayable(matched: matched)
    case .play:
        break
    }

    let indices = orderedPlayableAlbumTracks(rows).tracks.map { $0.index }
    let name = albumContainerName(title: title, uuid: uuid)

    switch buildAlbumContainer(name: name, indices: indices, run: run) {
    case .built:
        break
    case .noTracks:
        // Unreachable in practice: decideAlbumPlay already screened for a
        // playable row. Handle it rather than crashing — nothing was built,
        // so there is nothing to roll back.
        return .buildFailed(containerRemoved: true)
    case .createFailed, .seedMismatch:
        // buildAlbumContainer already rolled back successfully in these cases.
        return .buildFailed(containerRemoved: true)
    case .cleanupFailed:
        // The build failed AND its own rollback delete also failed.
        return .buildFailed(containerRemoved: false)
    }

    // Read identity from the container itself, before playing.
    let idsRaw = run(containerTrackIDsScript(name: name))
    if idsRaw == nil {
        // A genuine AppleScript failure, not "no tracks". Safe to continue:
        // since Task 6 an empty id set makes the watcher run context-only
        // rather than delete, but that degradation happens silently in a
        // subsystem whose stdout/stderr both go to /dev/null, so it is worth
        // a diagnostic even though the control flow does not change.
        verbose("album container \(name): could not read track ids; watcher will run context-only")
    }
    let ids = parseContainerTrackIDs(idsRaw ?? "")

    let esc = escapeAppleScriptString(name)
    guard run("play playlist \"\(esc)\"") != nil else {
        let removed = run(playlistDeleteScript(name: name)) != nil
        return .playFailed(containerRemoved: removed)
    }

    guard spawnAlbumWatcher(name: name, uuid: uuid, ids: ids, launch: launch) else {
        // Audio is already running, so ending the promise means stopping it.
        // Pausing rather than stopping is deliberate: it is the smallest
        // action that ends the promise and leaves the player recoverable.
        _ = run("pause")
        let removed = run(playlistDeleteScript(name: name)) != nil
        return .watcherFailed(containerRemoved: removed)
    }

    return .playing
}
