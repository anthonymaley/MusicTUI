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
            self.evidence.noteStatus(status)
            self.condition.lock(); self.statusReadInFlight = false; self.condition.unlock()
        }
    }

    private let condition = NSCondition()
    private var inFlight = 0
    private var closing = false
    /// The queue entry this process last started on the route.
    private var lastStarted: (playlist: String, position: Int)?
    /// A pause this follower may still be holding after a correction that
    /// could not resume it (`RateCorrectionStop.leavesOurPause`).
    private var ourPause: (persistentID: String, fence: Int)?

    init(route: MacDACRouteState, outputIsMusicApp: @escaping () -> Bool, fence: RateFence,
         owner: String = RateFence.newOwnerID(), makeMusic: @escaping MusicFactory,
         resolvePersistentID: @escaping (_ playlist: String, _ position: Int) -> String?,
         makeFollow: @escaping (RateToken) -> SourceRateFollow, post: @escaping (String) -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
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
                SourceRateFollow(token: token, control: SourceAppControl.macRate(observing: licence), offered: true)
            },
            post: post)
        player.readRateStatus = {
            (try? SourceAppControl.macRate(observing: licence).status())?.rateFollow
        }
        return player
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
    func play(playlist: String, position: Int, command: RateCommand,
              isCurrent: @escaping () -> Bool) -> QueuePlayOutcome {
        condition.lock()
        if closing { condition.unlock(); return .notStarted("MusicTUI is closing") }
        inFlight += 1
        condition.unlock()
        defer { condition.lock(); inFlight -= 1; condition.broadcast(); condition.unlock() }

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
            })
        let result = transition.run(RateTransitionPlan(command: command, sound: sound, isCurrent: isCurrent))
        record(result, playlist: playlist, position: position, persistentID: persistentID)
        evidence.record(result)
        onTransition?(result)

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
    func playStation(start: @escaping () throws -> Void,
                     isCurrent: @escaping () -> Bool = { true }) throws -> StationRouteOutcome {
        condition.lock()
        if closing { condition.unlock(); throw ActionError(message: stationNotStartedLine("MusicTUI is closing")) }
        inFlight += 1
        condition.unlock()
        defer { condition.lock(); inFlight -= 1; condition.broadcast(); condition.unlock() }

        let transition = RateAwareTransition(
            fence: fence, owner: owner, music: makeMusic(""), makeFollow: makeFollow, now: now,
            allowCorrection: { false })
        let result = transition.run(RateTransitionPlan(command: .station, sound: .other(start: start),
                                                       isCurrent: isCurrent))
        evidence.record(result)
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

    // MARK: closing (D2)

    /// The TUI is closing. Nothing new starts; a transition already running is
    /// waited for (bounded), so a correction is never cut off with our pause
    /// held; and a pause this follower still holds is released. The current
    /// song is left to finish and nothing advances (D2), exactly as before.
    func shutdown(wait: TimeInterval = 10) {
        condition.lock()
        closing = true
        let deadline = Date(timeIntervalSinceNow: wait)
        while inFlight > 0, condition.wait(until: deadline) {}
        let held = ourPause
        ourPause = nil
        condition.unlock()
        guard let held else { return }
        // Release only OUR pause: no command since, and Music still shows it
        // paused on that same track.
        guard (try? fence.fenceFileHolds(held.fence, timeout: 1)) == true else { return }
        let music = makeMusic("")
        guard let state = music.readPlayerState(), state.state == .paused,
              state.persistentID == held.persistentID else { return }
        try? music.resume()
    }

    // MARK: private

    private func record(_ result: RateTransitionResult, playlist: String, position: Int, persistentID: String?) {
        condition.lock(); defer { condition.unlock() }
        switch result {
        case .played(let played):
            lastStarted = (playlist, position)
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
