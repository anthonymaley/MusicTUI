// tools/music/Sources/Commands/RunQueueCommand.swift
import ArgumentParser
import Foundation

// The CLI's half of the Mac DAC route (mac-route-plan.md, section 3.1, D1; score
// step P5). Off the route, `music play` hands Music a temporary playlist that
// Music plays straight through, so nothing can change the DAC's sample rate
// between songs. ON the route the CLI instead starts this detached child, which
// plays the queue one song at a time, each through `MacRoutePlayer` and so
// through `RateAwareTransition` (fence, prepare, revalidate, play, confirm,
// correct), exactly as the TUI's poller does.
//
// **One owner of position (3.1).** The runner holds the play lease from its
// first transition (`RateFence.begin` takes it). A newer play from the TUI or
// from another runner takes the lease, and this one stops at its next look: its
// transition in flight is invalidated and plays nothing, and between songs it
// leaves the queue alone. The runner never takes the lease back. It does not
// create the temporary playlist, so there is no container for a watcher to
// clean up.
//
// **The wait.** Between songs it watches Music like the poller does: a song
// ended when Music is stopped and the last position seen was within 4 seconds of
// the end (Autoplay off). Music stopped sooner than that is the person pressing
// stop; Music on a song that is not ours is the person (or another command)
// starting something else; Music not running is not launched. Each of those ends
// the runner with nothing more played. A paused song is waited for.
//
// **Never a follower pause.** However the runner ends, `MacRoutePlayer.shutdown`
// releases a pause a correction may have left (only OUR pause, only if no command
// has moved the fence since), the same as closing the TUI.
//
// The Music reads are behind `RunQueueWatching`; the transition's Music control
// is `AppleScriptRateMusic`. Tests run with neither.

// MARK: - the manifest

/// The runner's private hand-off file for a queue too long for an argument list:
/// one persistent ID per line, IN PLAY ORDER (the watcher's manifest is a set).
/// Written by the CLI, OWNED BY THE RUNNER, which removes it as soon as it has
/// read it. `directory` is a seam for tests; production is `~/.config/music`,
/// where the watcher's manifest lives. nil for anything that is not a UUID, so
/// no path component can be smuggled in.
func runQueueManifestPath(uuid: String, directory: String? = nil) -> String? {
    guard UUID(uuidString: uuid) != nil else { return nil }
    let dir = directory ?? "\(NSHomeDirectory())/.config/music"
    return "\(dir)/run-queue-\(uuid).ids"
}

@discardableResult
func writeRunQueueManifest(uuid: String, ids: [String], directory: String? = nil) throws -> String {
    guard let path = runQueueManifestPath(uuid: uuid, directory: directory) else {
        throw NSError(domain: "RunQueueManifest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid uuid"])
    }
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try ids.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    return path
}

func readRunQueueManifest(path: String) -> [String]? {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// The queue's IDs in order, from `--ids` or the validated manifest; nil when
/// neither yields a non-empty list of sixteen-hex-digit persistent IDs.
func resolveRunQueueIDs(idsOption: String?, manifestPath: String?) -> [String]? {
    let ids: [String]
    if let idsOption, !idsOption.isEmpty {
        ids = idsOption.split(separator: ",").map(String.init)
    } else if let manifestPath, let fromFile = readRunQueueManifest(path: manifestPath) {
        ids = fromFile
    } else {
        return nil
    }
    guard !ids.isEmpty, ids.allSatisfy({ $0.count == 16 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
    return ids
}

/// The runner's queue: the same `AppQueue` the poller drives, each entry
/// addressed by persistent ID (`persistentIDQueueSource`).
func runQueueAppQueue(ids: [String], label: String) -> AppQueue? {
    let entries = ids.compactMap {
        persistentIDQueueEntry(persistentID: $0, name: "", artist: "", album: nil)
    }
    guard !entries.isEmpty, entries.count == ids.count else { return nil }
    return AppQueue(playlistName: persistentIDQueueSource, tracks: entries, currentIndex: 1,
                    displayName: label.isEmpty ? nil : label)
}

// MARK: - the Music reads

/// Music's player, as the runner's wait reads it.
struct RunQueuePlayback: Equatable {
    enum State: Equatable { case playing, paused, stopped }
    let state: State
    /// "" read as nil: nothing is current.
    let persistentID: String?
    let position: TimeInterval
    /// 0 when Music reports none (a stream).
    let duration: TimeInterval
}

protocol RunQueueWatching {
    /// Whether Music is running, WITHOUT launching it (the watcher's own probe).
    func musicIsRunning() -> Bool
    /// nil when Music cannot be read.
    func readPlayback() -> RunQueuePlayback?
}

/// The NEW AppleScript text of step P5: one read-only script. Variable names are
/// chosen away from Music's terms (a variable named like a property breaks at
/// runtime, and a fake interpreter cannot see it).
enum RunQueueScripts {
    /// Read-only: player state, the current track's persistent ID ("" when none),
    /// the position and the duration in whole centiseconds (integers, so no
    /// locale's decimal comma can reach the parser; 0 when unreadable),
    /// US-separated.
    static let readPlayback = """
        set stateText to player state as text
        set trackKey to ""
        try
            set trackKey to persistent ID of current track
        end try
        set centis to 0
        try
            set centis to round ((player position) * 100)
        end try
        set lengthCentis to 0
        try
            set lengthCentis to round ((duration of current track) * 100)
        end try
        set stateSep to (ASCII character 31)
        return stateText & stateSep & trackKey & stateSep & (centis as text) & stateSep & (lengthCentis as text)
        """

    static func parsePlayback(_ raw: String) -> RunQueuePlayback? {
        let f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: asFieldSep, maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, let centis = Int(f[2]), let length = Int(f[3]) else { return nil }
        let state: RunQueuePlayback.State
        switch f[0].lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        case "stopped": state = .stopped
        default: return nil   // fast forwarding, rewinding: not a state the wait reasons about
        }
        return RunQueuePlayback(state: state, persistentID: f[1].isEmpty ? nil : f[1].uppercased(),
                                position: TimeInterval(centis) / 100, duration: TimeInterval(length) / 100)
    }
}

struct AppleScriptRunQueueWatcher: RunQueueWatching {
    let backend: AppleScriptBackend
    func musicIsRunning() -> Bool { musicIsRunningNow() }
    func readPlayback() -> RunQueuePlayback? {
        (try? backend.runMusicBlocking(RunQueueScripts.readPlayback, timeout: AppleScriptRateMusic.shortTimeout))
            .flatMap(RunQueueScripts.parsePlayback)
    }
}

// MARK: - the runner

/// Why the runner ended. Every case but `finished` leaves the rest of the queue
/// unplayed; none of them leaves a pause of the runner's own.
enum RunQueueExit: Equatable {
    /// The last song of the queue ended.
    case finished
    /// A newer command or play (the TUI, another runner) holds the lease.
    case superseded
    /// Music is on a song that is not the runner's.
    case takenOver
    /// The Mac DAC route was turned off (or the output left MusicTUI).
    case routeLeft
    /// Music stopped before the song's end, or never started it.
    case stoppedEarly
    /// Music is not running, or cannot be read for too long.
    case musicUnavailable
    /// The output lock stayed busy (a route switch in progress) too many times.
    case couldNotStart
    /// One song was waited for longer than the watcher's own lifetime.
    case timedOut
}

final class RunQueueRunner {
    /// Section 3.1 and the poller: a song ended when Music stopped within this
    /// many seconds of its end.
    static let endTolerance: TimeInterval = 4

    private let queue: AppQueueStore
    private let player: MacRoutePlayer
    private let route: MacDACRouteState
    private let routeStillChosen: () -> Bool
    private let watcher: RunQueueWatching
    private let sleep: (TimeInterval) -> Void
    private let now: () -> TimeInterval
    private let pollInterval: TimeInterval
    private let startGracePolls: Int
    private let maxUnreadablePolls: Int
    private let maxNotStarted: Int
    private let maxLifetime: TimeInterval

    /// `route` is the state `player` was built with; the runner refreshes it from
    /// `routeStillChosen` (the persisted choice) before every play, so a route the
    /// person turned off stops the queue at the next song.
    init(queue: AppQueueStore, player: MacRoutePlayer, route: MacDACRouteState,
         routeStillChosen: @escaping () -> Bool, watcher: RunQueueWatching,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pollInterval: TimeInterval = 1, startGracePolls: Int = 8, maxUnreadablePolls: Int = 20,
         maxNotStarted: Int = 5, maxLifetime: TimeInterval = albumWatcherMaxLifetime) {
        self.queue = queue
        self.player = player
        self.route = route
        self.routeStillChosen = routeStillChosen
        self.watcher = watcher
        self.sleep = sleep
        self.now = now
        self.pollInterval = pollInterval
        self.startGracePolls = startGracePolls
        self.maxUnreadablePolls = maxUnreadablePolls
        self.maxNotStarted = maxNotStarted
        self.maxLifetime = maxLifetime
    }

    /// Plays the queue to its end or until something else owns the player.
    func run() -> RunQueueExit {
        let exit = drive()
        // However it ended: release a pause a correction left, if it is still ours.
        player.shutdown()
        return exit
    }

    private func drive() -> RunQueueExit {
        guard let first = queue.read() else { return .finished }
        var playlist = first.playlistName
        var position = first.currentSourcePosition
        var command = RateCommand.play
        var gate = AdvanceRetryGate()
        var notStarted = 0

        while true {
            route.set(routeStillChosen())
            guard player.isOnRoute else { return .routeLeft }
            let generation = queue.generation
            switch player.play(playlist: playlist, position: position, command: command,
                               isCurrent: { [queue] in queue.generation == generation }) {
            case .superseded:
                return .superseded
            case .notStarted:
                notStarted += 1
                if notStarted >= maxNotStarted { return .couldNotStart }
                sleep(pollInterval)
                continue
            case .failed:
                notStarted = 0
                // Only Music's own play failure counts: retry the same song, then
                // skip it, as the poller's gate does.
                if gate.playFailed() == .retry { sleep(pollInterval); continue }
            case .played:
                notStarted = 0
                gate.playSucceeded()
                switch waitForEnd(persistentID: persistentIDOfQueueEntry(position)) {
                case .ended: break
                case .exit(let reason): return reason
                }
                // The song ended: advance only while the lease is still ours.
                guard mayAdvance() else { return .superseded }
            }
            guard let next = queue.step(1) else { return .finished }
            (playlist, position) = next
            command = .advance
        }
    }

    /// `MacRoutePlayer.mayAdvance` (the lease is ours and the entry is the one
    /// this process started), with a busy lock waited out rather than read as
    /// "another owner".
    private func mayAdvance() -> Bool {
        for _ in 0..<5 {
            if player.mayAdvance(from: queue.read()) { return true }
            guard player.fence.leaseStatus(owner: player.owner) == .busy else { return false }
            sleep(pollInterval)
        }
        return false
    }

    private enum Wait { case ended, exit(RunQueueExit) }

    private func waitForEnd(persistentID: String) -> Wait {
        var lastPosition: TimeInterval = 0
        var lastDuration: TimeInterval = 0
        var seenPlaying = false
        var graceLeft = startGracePolls
        var unreadable = 0
        let deadline = now() + maxLifetime
        while true {
            sleep(pollInterval)
            if now() >= deadline { return .exit(.timedOut) }
            // Section 3.1: a newer owner holds the lease. Look before anything else.
            if player.fence.leaseStatus(owner: player.owner) == .another { return .exit(.superseded) }
            guard watcher.musicIsRunning() else { return .exit(.musicUnavailable) }
            guard let playback = watcher.readPlayback() else {
                unreadable += 1
                if unreadable >= maxUnreadablePolls { return .exit(.musicUnavailable) }
                continue
            }
            unreadable = 0
            if let other = playback.persistentID, other != persistentID { return .exit(.takenOver) }
            switch playback.state {
            case .playing, .paused:
                seenPlaying = true
                lastPosition = playback.position
                lastDuration = playback.duration
            case .stopped:
                if seenPlaying, lastDuration > 0, lastPosition >= max(0, lastDuration - Self.endTolerance) {
                    return .ended
                }
                if seenPlaying { return .exit(.stoppedEarly) }
                graceLeft -= 1
                if graceLeft <= 0 { return .exit(.stoppedEarly) }
            }
        }
    }
}

// MARK: - the live composition

/// The production runner: real Music, SpanDAC over the Mac's socket, the output
/// lock beside the real mode file. nil when the queue cannot be built.
func liveRunQueue(ids: [String], label: String) -> RunQueueRunner? {
    guard let appQueue = runQueueAppQueue(ids: ids, label: label) else { return nil }
    let backend = AppleScriptBackend()
    let modes = PlaybackModeStore()
    let data = DataProviderStore(beside: modes)
    let routeStore = MacRouteStore(beside: modes)
    let route = MacDACRouteState(initial: routeStore.isOn)
    let queue = AppQueueStore()
    queue.set(appQueue)
    let player = MacRoutePlayer(
        route: route,
        // The CLI play's own test: SpanDAC data on the MusicTUI output. A route
        // whose DAC is absent is not readable from here, so the follow stays on
        // (SpanDAC answers with what it can).
        outputIsMusicApp: {
            if case .consistent(_, .musicApp) = effectiveSelection(data: data, modes: modes) { return true }
            return false
        },
        fence: RateFence(lock: OutputLock(path: modes.lockPath)),
        makeMusic: { AppleScriptRateMusic(backend: backend, playScript: $0) },
        resolvePersistentID: { _, _ in nil },
        makeFollow: { token in
            SourceRateFollow(token: token, control: SourceAppControl.macRate(observing: nil), offered: true)
        },
        post: { verbose($0) })
    return RunQueueRunner(queue: queue, player: player, route: route, routeStillChosen: { routeStore.isOn },
                          watcher: AppleScriptRunQueueWatcher(backend: backend))
}

/// Internal plumbing: the detached runner for a CLI play on the Mac DAC route.
///
/// Spawned by `music play` and reparented to launchd, like `__watch-container`
/// (all three standard streams are /dev/null, so there is no console to report
/// to). It plays the queue one song at a time and exits at the end, when
/// something else owns the player, or when the route is left.
struct RunQueue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__run-queue",
        abstract: "Internal: play a queue one song at a time on the Mac DAC route.",
        shouldDisplay: false)

    @Argument(help: "The run's UUID") var uuid: String
    @Option(name: .customLong("label"), help: "The queue's name") var label: String = ""
    @Option(name: .long, help: "Comma separated persistent IDs, in play order") var ids: String?
    @Option(name: .long, help: "Path to a manifest of persistent IDs, in play order") var manifest: String?
    @Flag(name: [.customShort("v"), .customLong("verbose")], help: "Show diagnostic output") var verboseFlag = false

    func run() throws {
        Music.verbose = verboseFlag
        // Ownership is checked, not assumed, BEFORE the manifest is read: this
        // removes the file it is given, so only the path built from this UUID
        // may be named.
        guard UUID(uuidString: uuid) != nil else {
            verbose("__run-queue: refusing invalid uuid \(uuid)")
            Foundation.exit(1)
        }
        if let manifest, manifest != runQueueManifestPath(uuid: uuid) {
            verbose("__run-queue: refusing invalid manifest path \(manifest)")
            Foundation.exit(1)
        }
        let resolved = resolveRunQueueIDs(idsOption: ids, manifestPath: manifest)
        // Owned by this process from here: removed whether or not it parsed.
        if let manifest { removeAlbumManifest(path: manifest) }
        guard let queueIDs = resolved, let runner = liveRunQueue(ids: queueIDs, label: label) else {
            verbose("__run-queue: no usable queue")
            Foundation.exit(1)
        }
        let exit = runner.run()
        verbose("__run-queue: \(exit)")
        Foundation.exit(0)
    }
}
