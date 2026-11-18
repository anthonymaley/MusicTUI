// tools/music/Sources/TUI/MacRoutePlayer.swift
import Foundation

// The TUI's half of the Mac route (mac-route-plan.md sections 3.1 and 3.3, the
// appendix's M1 to M5; score step P4): every play on the Mac DAC route goes
// through `RateAwareTransition`, and nothing else does.
//
// **What "on the route" means.** The Output tab's Mac row turned the route on
// (`MacDACRouteState`, written by `SpeakersScene` through its
// `onMacRateFollowWanted` / `onMacRouteOff` hooks) AND the sound is still the
// MusicTUI output (`routing.effectiveOutput == .musicApp`): selecting a SpanDAC
// on the network, or any other output, is off the route without anyone having
// to remember to clear the flag. Plays off the route are untouched: the callers
// ask `AppQueueStore.macRoute` and fall back to `playQueueTrack` byte for byte.
//
// **One owner of position and transitions (3.1).** This process holds the play
// lease from its first route play (`RateFence.begin` takes it under the output
// lock). The poller advances only while it still holds it and the queue's
// current entry is the one this process last started (`mayAdvance`); the
// title-based fallback never runs on the route. Closing the TUI changes
// nothing (D2): the current song finishes and nothing advances; the one thing
// `shutdown` adds is that a follower pause it may be holding is released.
//
// **Results, as the callers see them (`QueuePlayOutcome`).**
//   - `played`      Music's own `play` returned. Rate trouble of every kind
//                   (and a broken state directory) ends here: the song plays.
//   - `failed`      Music's own `play` threw: the ONLY value the poller feeds
//                   `AdvanceRetryGate`.
//   - `superseded`  a newer command owns the player; nothing was played, and
//                   the caller must not roll the queue back (the newer command
//                   moved it) or touch the gate.
//   - `notStarted`  the output lock stayed busy (a route switch in progress) or
//                   the TUI is closing; nothing was played.
//
// New AppleScript text lives in `MacRouteScripts` and is listed in the P4
// report: a script read is not a script run, so each gets one read-only live
// run in step L.

/// Whether the Mac DAC route is on. Thread-safe: the Output tab's action queue
/// writes it, every play and the poller read it.
final class MacDACRouteState {
    private let lock = NSLock()
    private var on: Bool
    private var dacAbsent = false

    /// `initial` is the persisted choice (P8), restored at launch.
    init(initial: Bool = false) { on = initial }

    /// True when plays should follow the rate: the route is chosen AND its DAC
    /// is not known to be absent. The choice itself is `chosen`.
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on && !dacAbsent }
    var chosen: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
    /// The Output tab saw the chosen DAC absent (true) or back (false): the
    /// choice is kept, the rate follow waits.
    func setDACAbsent(_ value: Bool) { lock.lock(); dacAbsent = value; lock.unlock() }
}

/// What one queue-entry play came to, for its caller.
enum QueuePlayOutcome: Equatable {
    case played
    case failed
    case superseded
    case notStarted(String)

    /// The old `Bool`: false only when the play did not happen and the caller
    /// should say so and roll back. A superseded play is accepted: the newer
    /// command that superseded it owns the queue now.
    var accepted: Bool {
        switch self {
        case .played, .superseded: return true
        case .failed, .notStarted: return false
        }
    }
}

/// The line when the song plays with no rate follow because the fence or lock
/// files cannot be used (the 2026-11-15 ruling: never refuse a song).
let macRouteRateNotFollowedLine =
    "Couldn't follow this song's sample rate, so it plays at the DAC's current rate."

// MARK: - the AppleScript text this step adds

/// Every NEW AppleScript text of P4, in one place. Variable names are chosen
/// away from Music's terms (a variable named like a property breaks at runtime,
/// and a fake interpreter cannot see it).
enum MacRouteScripts {
    /// Read-only: the persistent ID of the track at `position` of `playlist`,
    /// or "" when there is none.
    static func resolvePersistentID(playlist: String, position: Int) -> String {
        """
        try
            return persistent ID of track \(position) of playlist "\(escapeAppleScriptString(playlist))"
        end try
        return ""
        """
    }

    /// Read-only, the one script of section 3.3 step 4: persistent ID, database
    /// ID and the delivered sample rate of the CURRENT track, US-separated.
    /// A missing sample rate reads 0. "" when nothing is current.
    static let readCurrentTrack = """
        try
            set rateTrack to current track
            set rateHz to 0
            try
                set rateValue to sample rate of rateTrack
                if rateValue is not missing value then set rateHz to rateValue
            end try
            set rateSep to (ASCII character 31)
            return (persistent ID of rateTrack) & rateSep & (database ID of rateTrack) & rateSep & (rateHz as text)
        end try
        return ""
        """

    /// Read-only: player state, the current track's persistent ID ("" when none)
    /// and the position in whole centiseconds (an integer, so no locale's
    /// decimal comma can reach the parser), US-separated.
    static let readPlayerState = """
        set stateText to player state as text
        set trackKey to ""
        try
            set trackKey to persistent ID of current track
        end try
        set centis to 0
        try
            set centis to round ((player position) * 100)
        end try
        set stateSep to (ASCII character 31)
        return stateText & stateSep & trackKey & stateSep & (centis as text)
        """

    static let pause = "pause"
    /// Resume the current track where it stands (no argument).
    static let resume = "play"
    static let seekToStart = "set player position to 0"

    // MARK: parsing

    static func parseTrackRead(_ raw: String) -> RateTrackRead? {
        let f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: asFieldSep, maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, !f[0].isEmpty else { return nil }
        let hz = Int(f[2]).flatMap { $0 > 0 ? $0 : nil }
        return RateTrackRead(persistentID: f[0].uppercased(), databaseID: Int(f[1]), sampleRateHz: hz)
    }

    static func parsePlayerState(_ raw: String) -> RatePlayerState? {
        let f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: asFieldSep, maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, let centis = Int(f[2]) else { return nil }
        let state: RatePlayerState.State
        switch f[0].lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        case "stopped": state = .stopped
        default: return nil   // fast forwarding, rewinding: not a state this guarantee reasons about
        }
        return RatePlayerState(state: state, persistentID: f[1].isEmpty ? nil : f[1].uppercased(),
                               position: TimeInterval(centis) / 100)
    }
}

/// The play script of one queue entry, exactly as `playQueueTrack` has always
/// run it: by persistent ID for an identity-addressed queue, else by position in
/// the named playlist.
func queueTrackPlayScript(playlist: String, position: Int) -> String {
    if playlist == persistentIDQueueSource { return persistentIDPlayScript(persistentIDOfQueueEntry(position)) }
    return "play track \(position) of playlist \"\(escapeAppleScriptString(playlist))\""
}

// MARK: - the real Music.app adapter

/// `RateMusicControlling` over AppleScript. One value per play: `playScript` is
/// what that entry's queue addressing plays (`queueTrackPlayScript`), so the
/// rate-aware play is the same play the queue always made; the persistent ID
/// only names the entry for the identity check and SpanDAC.
struct AppleScriptRateMusic: RateMusicControlling {
    let backend: AppleScriptBackend
    let playScript: String

    /// Reads, pause, resume and seek run under the output lock or inside the
    /// 3 s correction window; a wedged Music must not hold them for the
    /// backend's 45 s. CHOSEN, NOT MEASURED.
    static let shortTimeout: TimeInterval = 3

    func playTrack(persistentID: String) throws {
        _ = try backend.runMusicBlocking(playScript)
    }
    func pause() throws { _ = try backend.runMusicBlocking(MacRouteScripts.pause, timeout: Self.shortTimeout) }
    func resume() throws { _ = try backend.runMusicBlocking(MacRouteScripts.resume, timeout: Self.shortTimeout) }
    func seekToStart() throws {
        _ = try backend.runMusicBlocking(MacRouteScripts.seekToStart, timeout: Self.shortTimeout)
    }
    func readCurrentTrack() -> RateTrackRead? {
        (try? backend.runMusicBlocking(MacRouteScripts.readCurrentTrack, timeout: Self.shortTimeout))
            .flatMap(MacRouteScripts.parseTrackRead)
    }
    func readPlayerState() -> RatePlayerState? {
        (try? backend.runMusicBlocking(MacRouteScripts.readPlayerState, timeout: Self.shortTimeout))
            .flatMap(MacRouteScripts.parsePlayerState)
    }
}

// MARK: - the player

final class MacRoutePlayer {

    /// One value per play: the Music control for that entry's play script.
    typealias MusicFactory = (_ playScript: String) -> RateMusicControlling

    private let route: MacDACRouteState
    private let outputIsMusicApp: () -> Bool
    let fence: RateFence
    let owner: String
    private let makeMusic: MusicFactory
    private let resolvePersistentID: (_ playlist: String, _ position: Int) -> String?
    private let makeFollow: (RateToken) -> SourceRateFollow
    private let post: (String) -> Void
    private let now: () -> TimeInterval
    private let streamWait: RateStreamWait
    /// Runs the later re-check of a start whose stream was not up in time
    /// (`RateAwareTransition.recheck`), off the caller's thread. A test passes
    /// `{ $0() }` to run it in place.
    var runFollowUp: (@escaping () -> Void) -> Void = { DispatchQueue.global().async(execute: $0) }
    /// S11: what this process tells SpanDAC about the route and what is playing.
    /// nil in every test that predates it: then nothing is sent.
    let reporter: MacRouteFollowReporter?

    /// What Music's decoder opened, while a route song plays (finding 6). nil: never
    /// followed (every test that predates it; the AppleScript rate read stands).
    var decoderFeed: DecoderRateFeed?

    /// The song this process last started on the route, as a decoder report is
    /// matched to it (finding 6).
    private struct SongFollow {
        let transition: RateAwareTransition
        let played: RateTransitionPlayed
        let playlist: String
        let position: Int
        let persistentID: String?
        /// Wall time just before the play: a report stamped earlier is an older stream's.
        let startedAt: Date
        /// The rate last confirmed for this song; a report that says the same is nothing new.
        var lastHz: Int?
        /// A correction for this song is running (a re-check or a decoder's): the next report waits.
        var busy = false
        var pendingHz: Int?
    }
    private var song: SongFollow?

    /// Called after every transition (after the evidence line is recorded).
    var onTransition: ((RateTransitionResult) -> Void)?

    /// The line of step P6: what is playing and why, for Now and the Mac row.
    let evidence = MacRouteEvidence()
    /// Reads SpanDAC's status `rate` object (late switches, M5). nil: never read.
    var readRateStatus: (() -> SourceRateFollowStatus?)?
    private var statusReadInFlight = false
    private var lastStatusRead: TimeInterval = -.infinity
    /// How often the poller may ask while a song plays on the route.
    static let statusReadInterval: TimeInterval = 3

    /// The evidence line, or nil off the route (nothing new renders).
    var evidenceLine: String? { isOnRoute ? evidence.line : nil }

    /// Called from the poller while a song plays: at most one read in flight,
    /// no oftener than `statusReadInterval`, off the caller's thread.
    func refreshRateStatus() {
        guard isOnRoute, let read = readRateStatus else { return }
        condition.lock()
        let t = now()
        if statusReadInFlight || t - lastStatusRead < Self.statusReadInterval { condition.unlock(); return }
        statusReadInFlight = true; lastStatusRead = t
        condition.unlock()
        DispatchQueue.global().async { [weak self] in
            let status = read()
            guard let self else { return }
            self.noteRateStatus(status)
            self.condition.lock(); self.statusReadInFlight = false; self.condition.unlock()
        }
    }

    /// A status read's `rate` object: the evidence line's, and the follow latch's.
    /// `following: false` while on the route means SpanDAC holds no restore record
    /// (it restarted, or its record failed): the next sound start sends follow-on
    /// again before its prepare. Missing (an older SpanDAC) changes nothing.
    func noteRateStatus(_ status: SourceRateFollowStatus?) {
        evidence.noteStatus(status)
        if isOnRoute, status?.following == false { reporter?.followRecordLost() }
    }

    /// Fix round 2, finding 4: SpanDAC's status is read ONCE before the first
    /// prepare of a route session, so a SpanDAC that restarted since the route was
    /// chosen (its restore record gone, the confirmed-on latch still set here) is
    /// told follow-on BEFORE any rate write, not on a later poll. A session is the
    /// span between route changes (`routeChanged`); the CLI runner has one. A
    /// status that cannot be read tells nothing and does not count: the next play
    /// tries again (the read is bounded by the control's 2.5 s reply wait).
    ///
    /// Fix round 3, finding B: this read can block (2.5 s), so it runs only AFTER
    /// the play's ordering was reserved (`reserve`), never before. A newer command
    /// that starts while it blocks takes a newer fence, and this play then fails
    /// its revalidation instead of taking a still newer fence and replacing it.
    private var statusReadThisSession = false

    private func readStatusBeforeFirstPrepare() {
        guard let read = readRateStatus else { return }
        condition.lock(); let done = statusReadThisSession; condition.unlock()
        guard !done, let status = read() else { return }
        noteRateStatus(status)
        condition.lock(); statusReadThisSession = true; condition.unlock()
    }

    // MARK: reserving the ordering (fix round 3, finding B)

    /// Serializes this process's reservations so the request serial and the fence
    /// are taken in the same order. Held across `fence.begin` (which can wait for
    /// the output lock), so nothing that runs UNDER the output lock may take it.
    private let reserveLock = NSLock()
    /// Guards `requestSerial` alone; short, and safe to read under the output lock.
    private let serialLock = NSLock()
    private var requestSerial = 0

    /// M1, taken at the START of a command, before any read that can block: the
    /// fence moves and the lease is taken now. nil token: the fence could not be
    /// taken (a busy lock, or a broken state directory); `RateAwareTransition.run`
    /// then takes it itself and decides, as it always did. `serial` numbers this
    /// request among this process's reservations.
    private func reserve(_ command: RateCommand) -> (token: RateToken?, serial: Int) {
        reserveLock.lock(); defer { reserveLock.unlock() }
        serialLock.lock(); requestSerial += 1; let serial = requestSerial; serialLock.unlock()
        return (try? fence.begin(command, owner: owner), serial)
    }

    private func isLatestRequest(_ serial: Int) -> Bool {
        serialLock.lock(); defer { serialLock.unlock() }
        return requestSerial == serial
    }

    /// Waits (bounded) for the reports handed over so far; for a process that is
    /// about to exit (a CLI station).
    func flushReports() { reporter?.flush() }

    private let condition = NSCondition()
    private var inFlight = 0
    private var closing = false
    /// The queue entry this process last started on the route.
    private var lastStarted: (playlist: String, position: Int)?
    /// The fence of the last play this process started on the route: a re-check's
    /// answer is kept only while that is still the song it was made for.
    private var lastStartedFence: Int?
    /// How many songs this process has started on the route. The poller compares
    /// it between ticks: a start in between means the position it last saw
    /// belongs to the song before.
    private var starts = 0
    var startCount: Int { condition.lock(); defer { condition.unlock() }; return starts }
    /// A pause this follower may still be holding after a correction that
    /// could not resume it (`RateCorrectionStop.leavesOurPause`).
    private var ourPause: (persistentID: String, fence: Int)?
    /// The last song this process started on the route, as it reported it: the
    /// poller's reports of that song carry its identity and its rate.
    private var lastStartedReport: SourceNowPlayingReport?
    /// What the poller last reported, to report a change and not a tick.
    private var lastObserved: (state: SourceNowPlayingReport.State, track: String, position: TimeInterval, at: TimeInterval)?

    init(streamWait: RateStreamWait = .live,
         route: MacDACRouteState, outputIsMusicApp: @escaping () -> Bool, fence: RateFence,
         owner: String = RateFence.newOwnerID(), makeMusic: @escaping MusicFactory,
         resolvePersistentID: @escaping (_ playlist: String, _ position: Int) -> String?,
         makeFollow: @escaping (RateToken) -> SourceRateFollow, post: @escaping (String) -> Void,
         reporter: MacRouteFollowReporter? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.streamWait = streamWait
        self.reporter = reporter
        self.route = route
        self.outputIsMusicApp = outputIsMusicApp
        self.fence = fence
        self.owner = owner
        self.makeMusic = makeMusic
        self.resolvePersistentID = resolvePersistentID
        self.makeFollow = makeFollow
        self.post = post
        self.now = now
    }

    /// The Shell's composition: real Music, SpanDAC over the Mac's socket with
    /// the licence observing every reply, the coordinator's output lock.
    ///
    /// **Start-retry is deliberately NOT wrapped** (P3 left the choice): the
    /// Mac row's selection already started and used SpanDAC (`slice.useDAC`),
    /// and a rate op that finds it gone is `failed`, the song plays, and the
    /// line says so. Launching an app inside a 4.5 s sound start would only
    /// delay the song.
    static func live(backend: AppleScriptBackend, routing: RoutingCoordinator, route: MacDACRouteState,
                     post: @escaping (String) -> Void) -> MacRoutePlayer {
        let lock = routing.outputLock ?? OutputLock(path: PlaybackModeStore().lockPath)
        let licence = routing.licence
        // One reporter per process, over the same socket and licence observer as
        // the transitions: its `ensureOn` precedes each route's first prepare.
        let reporter = MacRouteFollowReporter(control: SourceAppControl.macRate(observing: licence))
        let player = MacRoutePlayer(
            route: route,
            outputIsMusicApp: { routing.effectiveOutput == .musicApp },
            fence: RateFence(lock: lock),
            makeMusic: { AppleScriptRateMusic(backend: backend, playScript: $0) },
            resolvePersistentID: { playlist, position in
                let raw = try? backend.runMusicBlocking(
                    MacRouteScripts.resolvePersistentID(playlist: playlist, position: position),
                    timeout: AppleScriptRateMusic.shortTimeout)
                let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
                return id.isEmpty ? nil : id
            },
            makeFollow: { token in
                SourceRateFollow(token: token, control: SourceAppControl.macRate(observing: licence), offered: true,
                                 routeFollow: reporter)
            },
            post: post,
            reporter: reporter)
        player.readRateStatus = {
            (try? SourceAppControl.macRate(observing: licence).status())?.rateFollow
        }
        player.decoderFeed = LogStreamDecoderFeed()
        return player
    }

    // MARK: telling SpanDAC (S11)

    /// The Mac DAC route was chosen or restored (on) or left (off): SpanDAC
    /// starts or ends recording the DAC's rate to restore. Asynchronous and
    /// repeatable; closing the TUI sends nothing (D2: the song finishes, and
    /// SpanDAC restores when the route is left or SpanDAC quits).
    func routeChanged(on: Bool) {
        condition.lock(); statusReadThisSession = false; condition.unlock()
        reporter?.routeChanged(on: on, fence: fence, owner: owner)
    }

    // MARK: the route

    /// True while a play should take the rate-aware path.
    var isOnRoute: Bool {
        guard route.isOn else { return false }
        condition.lock(); let isClosing = closing; condition.unlock()
        return !isClosing && outputIsMusicApp()
    }

    /// The poller's question before it advances (section 3.1: "an owner advances
    /// only while it holds the lease and the current track is its own entry").
    /// A process that has not played on the route yet owns nothing to lose, so
    /// it may advance (the route can be selected mid-queue).
    func mayAdvance(from queue: AppQueue?) -> Bool {
        condition.lock(); let started = lastStarted; condition.unlock()
        guard let started else { return true }
        guard let queue, queue.playlistName == started.playlist,
              queue.currentSourcePosition == started.position else { return false }
        switch fence.leaseStatus(owner: owner) {
        case .ours, .none, .unreadable: return true
        case .another, .busy: return false
        }
    }

    /// True once `shutdown` has begun.
    var isClosing: Bool { condition.lock(); defer { condition.unlock() }; return closing }

    // MARK: plays

    /// One queue entry on the route. `isCurrent` is the rest of the token (the
    /// queue generation and entry), checked under the output lock with the
    /// fence and the lease. The caller has already asked `isOnRoute`.
    ///
    /// `token` is a fence and lease taken for this play beforehand (a detached
    /// runner's parent reserves one); it is revalidated before the play like any
    /// token, and nil takes one here.
    func play(playlist: String, position: Int, command: RateCommand,
              subject: RouteSubject? = nil, token: RateToken? = nil,
              isCurrent: @escaping () -> Bool) -> QueuePlayOutcome {
        condition.lock()
        if closing { condition.unlock(); return .notStarted("MusicTUI is closing") }
        inFlight += 1
        condition.unlock()
        defer { condition.lock(); inFlight -= 1; condition.broadcast(); condition.unlock() }
        let startedAt = Date()
        startDecoderFeedIfNeeded()

        // The ordering first (fix round 3, finding B): the status read below can
        // block, and a newer command that starts meanwhile must win. With no
        // usable fence there is no ordering to protect, so nothing is read first.
        let reserved = token ?? reserve(command).token
        if reserved != nil { readStatusBeforeFirstPrepare() }
        let music = makeMusic(queueTrackPlayScript(playlist: playlist, position: position))
        let persistentID = playlist == persistentIDQueueSource
            ? persistentIDOfQueueEntry(position) : resolvePersistentID(playlist, position)
        // An entry whose identity cannot be read still plays (never refuse): as
        // a start with no rate work, which waits for the DAC to be quiet.
        let sound: RateSound = persistentID.map { .track(persistentID: $0, catalogID: nil) }
            ?? .other(start: { try music.playTrack(persistentID: "") })
        let transition = RateAwareTransition(
            fence: fence, owner: owner, music: music, makeFollow: makeFollow, now: now,
            allowCorrection: { [unowned self] in
                self.condition.lock(); defer { self.condition.unlock() }
                return !self.closing
            },
            streamWait: streamWait)
        let result = transition.run(RateTransitionPlan(command: command, sound: sound, isCurrent: isCurrent),
                                    token: reserved)
        record(result, playlist: playlist, position: position, persistentID: persistentID)
        evidence.record(result)
        reportStarted(result, persistentID: persistentID, subject: subject)
        onTransition?(result)
        if case .played(let played) = result {
            condition.lock()
            song = SongFollow(transition: transition, played: played, playlist: playlist, position: position,
                              persistentID: persistentID, startedAt: startedAt, lastHz: played.delivered?.sampleRateHz)
            condition.unlock()
            if transition.needsRecheck(played) {
                scheduleRecheck(transition, played: played, playlist: playlist, position: position,
                                persistentID: persistentID)
            }
        }

        switch result {
        case .played:
            return .played
        case .playedUnfollowed:
            post(macRouteRateNotFollowedLine)
            return .played
        case .playFailed:
            return .failed
        case .invalidated:
            return .superseded
        case .notStarted(let reason):
            return .notStarted(reason)
        }
    }

    /// A station on the route (3.9; P7): one `RateAwareTransition` with no rate
    /// work (`RateSound.other`): the fence moves (`.station`), SpanDAC is told,
    /// the open waits for the DAC to be quiet, then `start` runs under the
    /// revalidation. Nothing is converted or confirmed. Throws only when the
    /// station did not start for a reason the person should read.
    ///
    /// The ordering is reserved before anything that can block, and the station
    /// is current only while no NEWER station request of this process has been
    /// reserved (`isCurrent` is the caller's own check on top of that); any other
    /// newer command, in this process or another, moves the fence.
    func playStation(start: @escaping () throws -> Void, subject: RouteSubject? = nil,
                     isCurrent: @escaping () -> Bool = { true }) throws -> StationRouteOutcome {
        condition.lock()
        if closing { condition.unlock(); throw ActionError(message: stationNotStartedLine("MusicTUI is closing")) }
        inFlight += 1
        condition.unlock()
        defer { condition.lock(); inFlight -= 1; condition.broadcast(); condition.unlock() }

        let reservation = reserve(.station)
        if reservation.token != nil { readStatusBeforeFirstPrepare() }
        let transition = RateAwareTransition(
            fence: fence, owner: owner, music: makeMusic(""), makeFollow: makeFollow, now: now,
            allowCorrection: { false })
        let result = transition.run(
            RateTransitionPlan(command: .station, sound: .other(start: start),
                               isCurrent: { [weak self] in isCurrent() && (self?.isLatestRequest(reservation.serial) ?? true) }),
            token: reservation.token)
        evidence.record(result)
        reportStarted(result, persistentID: nil, subject: subject)
        onTransition?(result)
        switch result {
        case .played(let played):
            var dacRate: Int?
            if case .answered(let answer) = played.rateOutcome { dacRate = answer.dacRateHz }
            // No delivered rate is known for a station in v1: never "converted".
            return .played(line: stationRateLine(dacRateHz: dacRate, deliveredHz: nil))
        case .playedUnfollowed:
            post(macRouteRateNotFollowedLine)
            return .played(line: nil)
        case .playFailed:
            throw ActionError(message: stationCouldNotStartLine)
        case .invalidated:
            return .superseded
        case .notStarted(let reason):
            throw ActionError(message: stationNotStartedLine(reason))
        }
    }

    /// A TUI transport command that is not a play (pause, quiet): it still moves
    /// the fence (M1), so a follower's correction in flight sees a newer command
    /// and never resumes over a pause the person just asked for. Short wait: it
    /// must not hold a key press for the lock's 30 s, and a failure to move the
    /// fence changes nothing about the command itself.
    func noteCommand(_ command: RateCommand) {
        guard isOnRoute else { return }
        _ = try? fence.begin(command, owner: owner, timeout: 1)
    }

    // MARK: the re-check of a stream that was not up (2026-11-16)

    /// The start's confirm gave up waiting for this song's stream (Music kept
    /// reporting the previous stream, or refused its position), so nothing was
    /// confirmed. Tries again off the caller's thread, bounded, counted as work in
    /// flight so a closing TUI waits for it (and tells it to stop). Never touches
    /// the song unless the follow-up finds the DAC is not at its rate, and then
    /// only through `correct`'s guarantees.
    private func scheduleRecheck(_ transition: RateAwareTransition, played: RateTransitionPlayed,
                                 playlist: String, position: Int, persistentID: String?) {
        condition.lock()
        if closing { condition.unlock(); return }
        inFlight += 1
        condition.unlock()
        setSongBusy(fence: played.token.fence, true)
        runFollowUp { [self] in
            defer {
                condition.lock(); inFlight -= 1; condition.broadcast(); condition.unlock()
                finishSongWork(fence: played.token.fence)
            }
            guard let updated = transition.recheck(played, cancelled: { [self] in self.isClosing }) else { return }
            applyRecheck(updated, playlist: playlist, position: position, persistentID: persistentID)
        }
    }

    // MARK: Music's decoder, mid-song (finding 6)

    /// Start and stop of the feed are ONE critical section (`feedLock`): a stop that
    /// arrives while the child is starting waits for the start and then ends it, and a
    /// start after a stop never happens, so no child is left running by the race.
    private let feedLock = NSLock()
    private var feedStarted = false
    private var feedStopped = false

    private func startDecoderFeedIfNeeded() {
        guard let feed = decoderFeed else { return }
        feedLock.lock(); defer { feedLock.unlock() }
        guard !feedStarted, !feedStopped else { return }
        feedStarted = true
        feed.start { [weak self] report in self?.noteDecoderReport(report) }
    }

    private func stopDecoderFeed() {
        guard let feed = decoderFeed else { return }
        feedLock.lock(); defer { feedLock.unlock() }
        feedStopped = true
        feed.stop()
    }

    private func setSongBusy(fence: Int, _ busy: Bool) {
        condition.lock()
        if song?.played.token.fence == fence { song?.busy = busy }
        condition.unlock()
    }

    /// A correction (the re-check's or a decoder's) for the song of `fence` ended: a
    /// report that arrived meanwhile is handled now.
    private func finishSongWork(fence: Int) {
        condition.lock()
        var next: Int?
        if song?.played.token.fence == fence {
            song?.busy = false
            next = song?.pendingHz
            song?.pendingHz = nil
        }
        condition.unlock()
        if let next { noteDecoderRate(next, at: Date.distantFuture) }
    }

    /// One report from Music's decoder (any thread). Acts only on a report that is
    /// NEW for the song being played: stamped after the song started, and a rate other
    /// than the one last confirmed for it. Once per upgrade: the rate is taken as
    /// handled at once, whatever the correction's outcome, so the same report twice
    /// never corrects twice.
    func noteDecoderReport(_ report: DecoderReport) {
        noteDecoderRate(report.sampleRateHz, at: report.at)
    }

    private func noteDecoderRate(_ hz: Int, at: Date) {
        // Off the route (the output moved, the route was turned off) the DAC is not ours
        // to follow. Asked before the lock is taken: the output check has its own.
        guard route.isOn, outputIsMusicApp() else { return }
        condition.lock()
        guard !closing, var current = song, at >= current.startedAt.addingTimeInterval(-1),
              hz != current.lastHz else { condition.unlock(); return }
        if current.busy { current.pendingHz = hz; song = current; condition.unlock(); return }
        current.busy = true
        current.lastHz = hz
        song = current
        inFlight += 1
        condition.unlock()
        let fence = current.played.token.fence
        runFollowUp { [self] in
            defer {
                condition.lock(); inFlight -= 1; condition.broadcast(); condition.unlock()
                finishSongWork(fence: fence)
            }
            guard let updated = current.transition.adoptDecoderRate(current.played, hz: hz,
                                                                    cancelled: { [self] in self.isClosing }) else { return }
            applyRecheck(updated, playlist: current.playlist, position: current.position,
                         persistentID: current.persistentID)
        }
    }


    /// The line and the report take the re-check's evidence, only while the song
    /// it was made for is still the last one this process started.
    private func applyRecheck(_ updated: RateTransitionPlayed, playlist: String, position: Int,
                              persistentID: String?) {
        condition.lock()
        let current = lastStartedFence == updated.token.fence
        condition.unlock()
        guard current else { return }
        record(.played(updated), playlist: playlist, position: position, persistentID: persistentID, newStart: false)
        evidence.replace(updated)
        condition.lock()
        if song?.played.token.fence == updated.token.fence, let hz = updated.delivered?.sampleRateHz {
            song?.lastHz = hz
        }
        condition.unlock()
        // The poller's next look reports the song with the new rate: its reports
        // of this song copy the rate fields from `lastStartedReport`, and a
        // cleared `lastObserved` makes that next look a change.
        condition.lock()
        if var report = lastStartedReport, report.fence == updated.token.fence {
            let fresh = SourceNowPlayingReport.started(updated, persistentID: persistentID, subject: nil)
            report.databaseID = fresh.databaseID
            report.rateOutcome = fresh.rateOutcome
            report.targetHz = fresh.targetHz
            report.deliveredHz = fresh.deliveredHz
            report.dacRateHz = fresh.dacRateHz
            report.priorUnresolved = fresh.priorUnresolved
            lastStartedReport = report
            lastObserved = nil
        }
        condition.unlock()
    }

    // MARK: closing (D2)

    /// The TUI is closing. Nothing new starts; a transition already running is
    /// waited for (bounded), so a correction is never cut off with our pause
    /// held; and a pause this follower still holds is released. The current
    /// song is left to finish and nothing advances (D2), exactly as before.
    func shutdown(wait: TimeInterval = 10) {
        condition.lock()
        closing = true
        condition.unlock()
        stopDecoderFeed()
        condition.lock()
        let deadline = Date(timeIntervalSinceNow: wait)
        while inFlight > 0, condition.wait(until: deadline) {}
        let held = ourPause
        ourPause = nil
        let reportedHere = lastStartedReport != nil || lastObserved != nil
        condition.unlock()
        // S10: leaving, the Mac screen goes idle, but only if this process is the
        // one it is showing: it reported something, and still holds the lease (a
        // newer command, from the TUI or another runner, owns the screen now).
        // The ownership check and the fence for the report are ONE lock span
        // (`fenceIfLeaseIs`): a newer play that took the lease between two
        // separate reads would otherwise be reported under its own fence and have
        // its screen cleared by this departing process.
        if reportedHere, let reporter, let current = fence.fenceIfLeaseIs(owner: owner, timeout: 0.5) {
            reporter.reportIdle(fence: current)
        }
        guard let held else { return }
        // Release only OUR pause: no command since, and Music still shows it
        // paused on that same track. The fence check, the state read and the resume
        // are ONE output-lock span (fix round 3, finding C): a newer command that
        // pauses the same track between a separate check and read would otherwise
        // be resumed over.
        let music = makeMusic("")
        _ = fence.withFenceHeld(held.fence, timeout: 1) { () -> Void in
            guard let state = music.readPlayerState(), state.state == .paused,
                  state.persistentID == held.persistentID else { return }
            try? music.resume()
        }
    }

    // MARK: what is playing (S11)

    private func reportStarted(_ result: RateTransitionResult, persistentID: String?, subject: RouteSubject?) {
        guard let reporter else { return }
        let report: SourceNowPlayingReport
        switch result {
        case .played(let played):
            report = .started(played, persistentID: persistentID, subject: subject)
        case .playedUnfollowed:
            // The fence file is unusable: the last fence this process held is the
            // best ordering there is; none means nothing can be reported.
            guard let current = try? fence.current(timeout: 0.2) else { return }
            report = .startedUnfollowed(fence: current, persistentID: persistentID, subject: subject)
        case .playFailed, .invalidated, .notStarted:
            return
        }
        condition.lock()
        lastStartedReport = report
        lastObserved = (.playing, subject?.title ?? "", 0, now())
        condition.unlock()
        reporter.report(report)
    }

    /// The poller's look at Music, on the route: a CHANGE of state or of song, or
    /// a position that jumped (a seek), is reported; a tick that changed nothing
    /// is not. The song's identity and rate come from the transition that started
    /// it when the title matches; with none known they are left out.
    func observePlayback(_ outcome: PollOutcome) {
        guard let reporter, isOnRoute else { return }
        let state: SourceNowPlayingReport.State
        var title = "", artist = "", album = ""
        var position: TimeInterval = 0, duration: TimeInterval = 0
        switch outcome {
        case .active(let np):
            state = np.state.lowercased() == "paused" ? .paused : .playing
            title = np.track; artist = np.artist; album = np.album
            position = TimeInterval(np.position); duration = TimeInterval(np.duration)
        case .stopped:
            state = .stopped
        case .unavailable:
            return
        }
        let stamp = now()
        condition.lock()
        let last = lastObserved
        // A song started with no name of its own (the CLI runner's queue) takes
        // the title of the first look at Music after its start; after that the
        // identity follows the title, so a song someone else started in Music
        // never inherits it.
        if lastStartedReport?.title == nil, last?.track == "", state != .stopped, !title.isEmpty {
            lastStartedReport?.title = title
        }
        let started = lastStartedReport
        let expected = last.map { $0.position + (state == .playing && $0.state == .playing ? stamp - $0.at : 0) }
        let changed = last == nil || last!.state != state || last!.track != title
            || (state == .playing && abs(position - (expected ?? position)) > Self.seekJump)
        if changed { lastObserved = (state, title, position, stamp) }
        condition.unlock()
        guard changed, let current = try? fence.current(timeout: 0.2) else { return }
        var report = SourceNowPlayingReport(fence: current, state: state)
        if state != .stopped {
            report.title = title; report.artist = artist; report.album = album
            report.durationMS = duration > 0 ? Int(duration * 1000) : nil
            report.positionMS = Int(position * 1000)
        }
        if let started, started.title == title, state != .stopped {
            report.persistentID = started.persistentID
            report.databaseID = started.databaseID
            report.rateOutcome = started.rateOutcome
            report.targetHz = started.targetHz
            report.deliveredHz = started.deliveredHz
            report.dacRateHz = started.dacRateHz
            report.priorUnresolved = started.priorUnresolved
        }
        reporter.report(report)
    }

    /// Whole seconds are what Music's poll gives, so a drift of one is noise.
    static let seekJump: TimeInterval = 3

    // MARK: private

    private func record(_ result: RateTransitionResult, playlist: String, position: Int, persistentID: String?,
                        newStart: Bool = true) {
        condition.lock(); defer { condition.unlock() }
        if newStart { switch result { case .played, .playedUnfollowed: starts += 1; default: break } }
        switch result {
        case .played(let played):
            lastStarted = (playlist, position)
            lastStartedFence = played.token.fence
            if case .stopped(let stop, _) = played.correction, stop.leavesOurPause, let persistentID {
                ourPause = (persistentID, played.token.fence)
            } else {
                ourPause = nil
            }
        case .playedUnfollowed:
            lastStarted = (playlist, position)
            ourPause = nil
        case .playFailed, .invalidated, .notStarted:
            break
        }
    }
}

// MARK: - the lease, read

extension RateFence {
    enum LeaseStatus: Equatable {
        case ours, none, another
        /// The lock stayed busy past `timeout`: not known now.
        case busy
        /// The files cannot be read (a broken state directory): no one can be
        /// said to hold anything, and the song plays regardless.
        case unreadable
    }

    /// The fence file's number, but only while `owner` holds the lease: the
    /// ownership check and the fence read are ONE output-lock span, so no newer
    /// play can take the lease between them. nil when the lease is anyone else's
    /// (or no one's), or the lock stayed busy, or the files cannot be read.
    func fenceIfLeaseIs(owner: String, timeout: TimeInterval = 1) -> Int? {
        try? lock.withLock(timeout: timeout) {
            guard let holder = try readLeaseHoldingLock(), holder == owner else { return nil }
            return try readFenceHoldingLock()
        }
    }

    /// Runs `body` inside ONE output-lock span, and only while the fence file
    /// still holds `fence`. nil when the fence moved, the lock stayed busy past
    /// `timeout`, or the files cannot be read.
    func withFenceHeld<T>(_ fence: Int, timeout: TimeInterval = 1, _ body: () -> T) -> T? {
        let result: T?? = try? lock.withLock(timeout: timeout) { () -> T? in
            guard try readFenceHoldingLock() == fence else { return nil }
            return body()
        }
        return result ?? nil
    }

    /// Who holds the play lease, read under the output lock. Short wait: the
    /// poller must not stall a tick for a route switch.
    func leaseStatus(owner: String, timeout: TimeInterval = 1) -> LeaseStatus {
        do {
            return try lock.withLock(timeout: timeout) {
                guard let holder = try readLeaseHoldingLock() else { return LeaseStatus.none }
                return holder == owner ? .ours : (holder.isEmpty ? .none : .another)
            }
        } catch OutputLockError.busy {
            return .busy
        } catch {
            return .unreadable
        }
    }
}

// MARK: - the Mac's rate socket, observed

extension SourceAppControl {
    /// `macRate`, with SpanDAC's licence told every reply (the same
    /// `observingLicence` the Mac's other client uses). With `licence` nil it is
    /// `macRate` exactly. `senderFor` is the seam a test replaces; the default
    /// is the Unix socket at the stated timeout.
    static func macRate(observing licence: SpanDACServingCache?,
                        path: String = SourceAppStationSearch.socketPath,
                        senderFor: @escaping (TimeInterval) -> (String, String) throws -> String
                            = { SourceAppStationSearch.sender(timeout: $0) }) -> SourceAppControl {
        guard let licence else { return macRate(path: path) }
        var control = SourceAppControl(
            path: path,
            transport: observingLicence(senderFor(SourceRateFollow.prepareReplyWait), cache: licence))
        control.rateSender = { observingLicence(senderFor($0), cache: licence) }
        return control
    }
}
