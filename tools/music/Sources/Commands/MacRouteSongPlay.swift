// tools/music/Sources/Commands/MacRouteSongPlay.swift
import Foundation

// One seam for "play these library songs, by persistent ID, in this order, on the
// Mac DAC route" (mac-route-plan.md; score step P9). On the route Music must not
// be handed a temporary playlist it plays straight through (nothing could change
// the DAC's rate between songs), so the bounded album, artist and song plays, the
// catalogue add-then-play and the TUI's search plays all hand their songs here
// instead of building a container.
//
//   - CLI: `cli` starts the detached `__run-queue` runner (P5), exactly as the
//     SpanDAC-data hand-off does.
//   - TUI: `MacRouteSongPlay.tui` sets the app queue to persistent-ID entries and
//     plays the first through `playQueueEntry` (P4), so the poller advances one
//     song at a time through the same transition.
//
// Nil seam, or `isOn()` false: every caller is exactly what it was.

struct MacRouteSongPlay {
    /// Whether the route is the chosen route now. Read at the moment of the play.
    var isOn: () -> Bool
    /// Plays `ids` (sixteen-hex persistent IDs) in order under `label`. False when
    /// nothing was started.
    var play: (_ label: String, _ ids: [String]) -> Bool
}

/// The line the CLI prints in place of the shipped now-playing read once a runner
/// was started: the runner's first song starts after this command returns, so
/// Music has nothing to read yet. `showNowPlaying` consumes it.
enum MacRouteCLIStart {
    private static let lock = NSLock()
    private static var line: String?
    static func record(_ text: String) { lock.lock(); line = text; lock.unlock() }
    static func take() -> String? { lock.lock(); defer { lock.unlock() }; let l = line; line = nil; return l }
}

extension MacRouteSongPlay {
    /// The CLI's: the route is the choice persisted beside mode.json; a play
    /// starts the detached runner. `isOnRoute` and `launch` are the test seams.
    static func cli(isOnRoute: @escaping () -> Bool = { MacRouteStore(beside: PlaybackModeStore()).isOn },
                    launch: @escaping ProcessLauncher = detachedLaunch,
                    json: @escaping () -> Bool = { Music.isJSON }) -> MacRouteSongPlay {
        MacRouteSongPlay(isOn: isOnRoute, play: { label, ids in
            guard spawnRunQueue(label: label, uuid: UUID().uuidString, ids: ids, launch: launch) else { return false }
            MacRouteCLIStart.record(macRoutePlayingLine(label: label, count: ids.count, json: json()))
            return true
        })
    }

    /// The TUI's: the app queue holds the songs (addressed by persistent ID) and
    /// the first one plays through the rate-aware transition. A play that did not
    /// start leaves no queue behind.
    static func tui(backend: AppleScriptBackend, appQueue: AppQueueStore) -> MacRouteSongPlay {
        MacRouteSongPlay(
            isOn: { appQueue.macRoute?.isOnRoute ?? false },
            play: { label, ids in
                let entries = ids.compactMap {
                    persistentIDQueueEntry(persistentID: $0, name: label, artist: "", album: nil)
                }
                guard !entries.isEmpty, entries.count == ids.count else { return false }
                let queue = AppQueue(playlistName: persistentIDQueueSource, tracks: entries, currentIndex: 1,
                                     displayName: label)
                appQueue.set(queue)
                let played = playRequestedQueueTrack(backend: backend, appQueue: appQueue,
                                                     playlist: persistentIDQueueSource,
                                                     position: queue.currentSourcePosition, title: label)
                if !played { appQueue.clear() }
                return played
            })
    }
}

/// Said when the route could not start a play (nothing was played, nothing was built).
let macRouteSongPlayNotStarted = macRouteRunnerNotStartedMessage

/// Read-only: the persistent ID of each `Library` track at `indices`, in that
/// order, US-separated. The same `track N of playlist "Library"` addressing the
/// container build uses. Errors (so the runner never starts) if any index is gone.
func libraryPersistentIDsScript(indices: [Int]) -> String {
    let reads = indices
        .map { "    set routeOut to routeOut & (persistent ID of track \($0) of playlist \"Library\") & routeSep" }
        .joined(separator: "\n")
    return """
    set routeSep to (ASCII character 31)
    set routeOut to ""
    \(reads)
    return routeOut
    """
}

/// The route's version of `playBoundedContainer`: no container is built. Returns
/// nil when the route is not on (the caller continues as it always has).
func playContainerOnRoute(label: String, seed: ContainerSeed, route: MacRouteSongPlay?,
                          run: ScriptRunner) -> ContainerPlayOutcome? {
    guard let route, route.isOn() else { return nil }
    let ids: [String]
    switch seed {
    case .persistentID(let id):
        ids = [id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    case .libraryIndices(let indices):
        guard !indices.isEmpty, let raw = run(libraryPersistentIDsScript(indices: indices)) else {
            return .routeNotStarted
        }
        ids = parseContainerTrackIDsInOrder(raw).map { $0.uppercased() }
        guard ids.count == indices.count else { return .routeNotStarted }
    }
    guard ids.allSatisfy({ $0.count == 16 && $0.allSatisfy(\.isHexDigit) }) else { return .routeNotStarted }
    return route.play(label, ids) ? .playing : .routeNotStarted
}
