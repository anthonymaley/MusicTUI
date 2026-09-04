// tools/music/Sources/Commands/BoundedAlbumPlay.swift
import Foundation

enum BoundedAlbumOutcome: Equatable {
    case playing
    case notFound
    case nonePlayable(matched: Int)
    /// §16.6: the query matched more than one distinct album with no unique
    /// exact match — nothing is built, nothing is played.
    case ambiguous(albums: [String])
    /// Container creation or seeding failed. `containerRemoved` is false when
    /// the rollback delete ALSO failed, so a partial container may remain in
    /// the user's library and the caller must not claim otherwise.
    case buildFailed(containerRemoved: Bool)
    case playFailed(containerRemoved: Bool)
    case watcherFailed(containerRemoved: Bool)
}

/// What the container layer alone can produce. The album layer's own outcomes
/// (`notFound`, `nonePlayable`, `ambiguous`) are decisions about which rows to
/// seed with and stay above this.
enum ContainerPlayOutcome: Equatable {
    case playing
    case buildFailed(containerRemoved: Bool)
    case playFailed(containerRemoved: Bool)
    case watcherFailed(containerRemoved: Bool)
}

/// Build a container, play it bounded, and hand it to the detached watcher.
///
/// Lifted out from under `playBoundedAlbum` so a single song reuses the same
/// mechanism instead of growing a second one (Anthony, 2026-09-03). Behaviour
/// for the album path is unchanged: the same build, the same id read, the same
/// `play playlist` form, the same watcher spawn, and the same rollback at every
/// failure.
///
/// The stale sweep is deliberately NOT here. In `playBoundedAlbum` it runs
/// before album resolution, so folding it in would move it after, and it would
/// stop running when a query matches no album. Each caller runs it at its own
/// correct point.
///
/// `confirm` is the fail-closed hook the song path needs and the album path
/// does not use: it sees the ids read back from the container itself and can
/// reject the build before a note is played. Returning false rolls the
/// container back and reports `.buildFailed`.
func playBoundedContainer(name: String,
                          seed: ContainerSeed,
                          uuid: String,
                          run: ScriptRunner,
                          launch: @escaping ProcessLauncher = detachedLaunch,
                          confirm: (Set<String>?) -> Bool = { _ in true })
    -> ContainerPlayOutcome {

    switch buildContainer(name: name, seed: seed, run: run) {
    case .built:
        break
    case .noTracks:
        // Unreachable from the album path, which screens for a playable row in
        // `decideAlbumPlay` first. Reachable from the song path, where an empty
        // seed means the caller resolved nothing. Nothing was built, so there
        // is nothing to roll back.
        return .buildFailed(containerRemoved: true)
    case .createFailed:
        // buildContainer already rolled back successfully in this case.
        return .buildFailed(containerRemoved: true)
    case .seedMismatch(let expected, let got):
        // §18.5: this diagnostic used to be computed and discarded, so a
        // required test case produced no diagnostic at all. The rollback
        // already ran successfully (same as `.createFailed`).
        //
        // For a `.persistentID` seed this is also the fail-closed path for an
        // id that matched nothing (got 0) or matched more than one row
        // (got > 1), both of which roll back rather than play.
        verbose("container \(name): seed mismatch (expected \(expected), got \(got)); rolled back")
        return .buildFailed(containerRemoved: true)
    case .cleanupFailed:
        // The build failed AND its own rollback delete also failed.
        return .buildFailed(containerRemoved: false)
    }

    // Read identity from the container itself, before playing.
    let idsRaw = run(containerTrackIDsScript(name: name))
    if idsRaw == nil {
        // A genuine AppleScript failure, not "no tracks". Safe to continue for
        // the album path: since Task 6 an empty id set makes the watcher run
        // context-only rather than delete. That degradation happens silently in
        // a subsystem whose stdout and stderr both go to /dev/null, so it is
        // worth a diagnostic even though the control flow does not change.
        // A caller that passes `confirm` turns this into a refusal instead,
        // because an unreadable id set cannot confirm anything.
        verbose("container \(name): could not read track ids; watcher will run context-only")
    }
    let ids = parseContainerTrackIDs(idsRaw ?? "")

    // Fail closed BEFORE playing. A caller that cannot confirm what it built
    // must not fall through to playing something else. `confirm` sees nil when
    // the read itself failed, so it can tell "unknown" from "wrong" — those are
    // different states with different messages.
    guard confirm(idsRaw == nil ? nil : ids) else {
        let removed = run(playlistDeleteScript(name: name)) != nil
        verbose("container \(name): identity confirmation failed; rolled back")
        return .buildFailed(containerRemoved: removed)
    }

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
        if let manifestPath = albumManifestPath(uuid: uuid) {
            removeAlbumManifest(path: manifestPath)
        }
        return .watcherFailed(containerRemoved: removed)
    }

    return .playing
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

    // §16.1: sweep stale __album__ containers a crashed or killed watcher
    // left behind, BEFORE this play creates its own — design §6.2 path 2,
    // the recovery this comment used to promise without anything building it.
    // Spares anything in use and spares on any unreadable signal, so a failed
    // or inconclusive sweep must never block THIS play from starting; its
    // result is intentionally discarded.
    _ = run(albumStaleSweepScript())

    let albumRows: [LibraryAlbumRow]
    var resolvedTitle = title
    switch decideAlbumPlay(rows, query: title) {
    case .notFound:
        return .notFound
    case .nonePlayable(let matched):
        return .nonePlayable(matched: matched)
    case .ambiguous(let albums):
        return .ambiguous(albums: albums)
    case .play(let chosenRows, let displayName, _, _, _):
        // §17.1: the container must be seeded from the CHOSEN album's own
        // rows, never the full (possibly multi-album) `rows` parameter — that
        // was the defect this fix wave exists to close. `position` is not
        // used on this path: it names a Library index for the pre-Task-6
        // single-track play, which this bounded path never issues.
        albumRows = chosenRows
        // §18.5: name the container after the RESOLVED album title, not the
        // raw query — `--album "moon"` should show "Moon Safari" in Music's
        // sidebar and Now Playing, not "moon". `displayName` comes from a
        // real library row's `album` field, but falls back to the query on
        // the (untested-in-the-wild) chance a matching row's own album tag
        // is itself blank, so the container is never named with an empty
        // title.
        if !displayName.isEmpty { resolvedTitle = displayName }
    }

    let indices = orderedPlayableAlbumTracks(albumRows).tracks.map { $0.index }
    let name = albumContainerName(title: resolvedTitle, uuid: uuid)

    switch playBoundedContainer(name: name, seed: .libraryIndices(indices),
                                uuid: uuid, run: run, launch: launch) {
    case .playing:
        return .playing
    case .buildFailed(let removed):
        return .buildFailed(containerRemoved: removed)
    case .playFailed(let removed):
        return .playFailed(containerRemoved: removed)
    case .watcherFailed(let removed):
        return .watcherFailed(containerRemoved: removed)
    }
}

/// User facing text for an outcome, or nil when there is nothing to say because
/// playback started. Each failure names its stage so the three are
/// distinguishable in a bug report, and each is doubled on `containerRemoved`:
/// a message must never claim a cleanup that did not actually happen, so when
/// removal failed it instead names the leftover playlist and points at
/// `music playlist cleanup` to collect it.
func albumOutcomeMessage(_ outcome: BoundedAlbumOutcome, title: String) -> String? {
    switch outcome {
    case .playing:
        return nil
    case .notFound:
        return "No albums found matching '\(title)'"
    case .nonePlayable(let matched):
        return "Found \(matched) track(s) matching '\(title)', but none are playable yet (pre-release or removed)."
    case .ambiguous(let albums):
        // §19.4: this is one of two different problems, and the message
        // must not claim to know which, because the CLI cannot tell them
        // apart. Offer both remedies rather than the one that only fixes
        // one of them: --artist only ever narrows the fetch, so for a
        // metadata-split album no --artist value reassembles it (§19.4).
        let shown = albums.prefix(8).map { $0.isEmpty ? "(untitled album)" : $0 }
        let list = shown.joined(separator: ", ")
        let more = albums.count > shown.count ? ", and \(albums.count - shown.count) more" : ""
        return "'\(title)' matches \(albums.count) different albums: \(list)\(more). "
            + "If these are different albums, add --artist to pick one. If this is one album "
            + "with inconsistent album-artist credits, fix that metadata in Music — the CLI "
            + "won't merge it for you."
    case .buildFailed(let containerRemoved):
        if containerRemoved {
            return "Couldn't build the temporary album container for '\(title)'. Nothing was played."
        }
        return "Couldn't build the temporary album container for '\(title)'. Nothing was played, but a partial "
            + "temporary playlist may remain in your library; run `music playlist cleanup` to collect it."
    case .playFailed(let containerRemoved):
        if containerRemoved {
            return "Couldn't start bounded playback for '\(title)'. The container was removed."
        }
        return "Couldn't start bounded playback for '\(title)'. A temporary playlist may remain in your library; "
            + "run `music playlist cleanup` to collect it."
    case .watcherFailed(let containerRemoved):
        if containerRemoved {
            return "Couldn't start the cleanup watcher for '\(title)'. Playback was paused and the container removed."
        }
        return "Couldn't start the cleanup watcher for '\(title)'. Playback was paused, but a temporary playlist "
            + "may remain in your library; run `music playlist cleanup` to collect it."
    }
}
