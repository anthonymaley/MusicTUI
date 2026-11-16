// tools/music/Sources/TUI/MacRouteFollowReport.swift
import Foundation

// What MusicTUI tells SpanDAC about the Mac DAC route (mac-route S11; the wire is
// `SpanDACRateFollow.swift`, protocol code only).
//
//   `slice.rateFollow {fence, on}`  when the route is chosen or restored (on) and
//       when it is left (off). SpanDAC feeds its restore lifecycle from it: on
//       records the DAC's rate before SpanDAC first changes it, off puts it back.
//       It MUST arrive before the first rate write of a route, so a transition
//       sends it (once, while it is not confirmed) just before its prepare
//       (`SourceRateFollow.ensureRouteFollowOn`): this is also how the CLI
//       runner sends it, and how it is re-sent when SpanDAC was not running at
//       launch. SpanDAC answers the same state twice with no effect.
//   `slice.nowPlaying {fence, state, ...}`  on each transition and each state
//       change the poller sees, for the Mac screen (D6).
//
// **Never in the way.** A route change and a report run on one serial queue, off
// the caller's thread (the Output tab's tick, the poller); only a transition's
// own `ensureOn` is synchronous, and it is bounded (`ensureTimeout`) and counted
// in the sound start's 4.5 s cap. A report is coalesced: a slow SpanDAC gets the
// latest, not a backlog.
//
// **Older peers.** An older SpanDAC answers each op `unknown_op`; that op is then
// latched as not offered for the life of this process and nothing more is sent
// (the song plays, the route works, SpanDAC records nothing and restores
// nothing). Every other failure leaves the state unconfirmed, so the next play's
// `ensureOn` tries again.

/// Which song a route play is, for the report: the queue entry's own words.
struct RouteSubject: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var durationMS: Int?

    /// The current entry of an app queue; nil when it names nothing.
    init?(current queue: AppQueue?) {
        guard let queue, queue.currentIndex >= 1, queue.currentIndex <= queue.tracks.count else { return nil }
        let entry = queue.tracks[queue.currentIndex - 1]
        guard !entry.name.isEmpty else { return nil }
        title = entry.name
        artist = entry.artist.isEmpty ? nil : entry.artist
        album = entry.album.flatMap { $0.isEmpty ? nil : $0 }
        durationMS = nil
    }

    init(title: String?, artist: String? = nil, album: String? = nil, durationMS: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMS = durationMS
    }
}

final class MacRouteFollowReporter {

    /// A transition's own `ensureOn`: counted in the 4.5 s cap.
    static let ensureTimeout: TimeInterval = 1.0
    /// A route change, off the caller's thread.
    static let followTimeout: TimeInterval = 3.0
    static let reportTimeout: TimeInterval = 1.0

    private let control: SourceAppControl
    private let schedule: (@escaping () -> Void) -> Void
    private let log: (String) -> Void
    private let lock = NSLock()
    /// What SpanDAC last confirmed: true after a confirmed on, false after a
    /// confirmed off, nil when unknown (never sent, or the last send failed).
    private var confirmedOn: Bool?
    private var followOffered = true
    private var nowPlayingOffered = true
    private var pending: SourceNowPlayingReport?
    private var draining = false

    /// `schedule` runs one unit of work off the caller's thread, in order; a test
    /// passes `{ $0() }` to run it in place.
    init(control: SourceAppControl,
         schedule: ((@escaping () -> Void) -> Void)? = nil,
         log: @escaping (String) -> Void = { _ in }) {
        self.control = control
        let queue = DispatchQueue(label: "music.macroute.report")
        self.schedule = schedule ?? { queue.async(execute: $0) }
        self.log = log
    }

    /// What SpanDAC last confirmed (for the callers that must not repeat work).
    var confirmed: Bool? { lock.lock(); defer { lock.unlock() }; return confirmedOn }
    var isFollowOffered: Bool { lock.lock(); defer { lock.unlock() }; return followOffered }
    var isNowPlayingOffered: Bool { lock.lock(); defer { lock.unlock() }; return nowPlayingOffered }

    // MARK: follow

    /// A transition's first message of a route: `slice.rateFollow on` under the
    /// transition's own fence, unless SpanDAC confirmed it already or is known
    /// not to serve it. Synchronous and bounded.
    ///
    /// Returns whether a rate may now be written: true when follow is on
    /// (already confirmed, or confirmed by this call) or SpanDAC does not serve
    /// it at all; false when the follow-on failed, timed out or was not applied.
    /// A false is NOT recorded as confirmed, so the next call asks again.
    @discardableResult
    func ensureOn(fence: Int, timeout: TimeInterval = MacRouteFollowReporter.ensureTimeout) -> Bool {
        lock.lock()
        let offered = followOffered
        let already = confirmedOn == true
        lock.unlock()
        guard offered, !already else { return true }
        sendFollow(fence: fence, on: true, timeout: timeout)
        lock.lock(); defer { lock.unlock() }
        return !followOffered || confirmedOn == true
    }

    /// A status read said SpanDAC holds no restore record (it restarted, or the
    /// record failed): the confirmed-on latch is cleared, so the next sound start
    /// re-sends follow-on before its prepare. A state that was not "confirmed on"
    /// is left as it is.
    func followRecordLost() {
        lock.lock(); defer { lock.unlock() }
        if confirmedOn == true { confirmedOn = nil }
    }

    /// The route was chosen or restored (on) or left (off). Takes a fence (M1:
    /// a route change is a command), tells SpanDAC, and on off clears the Mac
    /// screen. Asynchronous: never on the caller's thread. A state SpanDAC
    /// already confirmed sends nothing, so the Output tab may call it as often
    /// as it likes.
    func routeChanged(on: Bool, fence: RateFence, owner: String) {
        schedule { [self] in
            lock.lock()
            let offered = followOffered
            let already = confirmedOn == on
            lock.unlock()
            guard offered, !already else { return }
            let token: RateToken
            do { token = try fence.begin(.routeChange, owner: owner, timeout: 1) } catch {
                log("route change not reported: the fence could not move (\(error))")
                return
            }
            sendFollow(fence: token.fence, on: on, timeout: Self.followTimeout)
            guard !on else { return }
            lock.lock(); pending = nil; lock.unlock()
            sendNowPlaying(SourceNowPlayingReport(fence: token.fence, state: .none))
        }
    }

    private func sendFollow(fence: Int, on: Bool, timeout: TimeInterval) {
        do {
            let ack = try control.rateFollowRequest(fence: fence, on: on, timeout: timeout)
            lock.lock(); confirmedOn = ack.wasApplied ? on : nil; lock.unlock()
        } catch SourceAppError.unsupported {
            lock.lock(); followOffered = false; confirmedOn = nil; lock.unlock()
            log("SpanDAC does not serve \(sourceRateFollowOp): nothing will be recorded or restored")
        } catch {
            lock.lock(); confirmedOn = nil; lock.unlock()
            log("\(sourceRateFollowOp) \(on ? "on" : "off") not confirmed: \(error)")
        }
    }

    // MARK: now playing

    /// Reports what is playing, coalesced: only the latest waiting report is sent.
    func report(_ report: SourceNowPlayingReport) {
        lock.lock()
        guard nowPlayingOffered else { lock.unlock(); return }
        pending = report
        let start = !draining
        draining = true
        lock.unlock()
        guard start else { return }
        schedule { [self] in drain() }
    }

    /// Waits (bounded) until every report handed over so far was tried: a process
    /// that exits right after a report (a CLI station) must not take it with it.
    func flush(timeout: TimeInterval = 1.5) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            lock.lock(); let busy = draining || pending != nil; lock.unlock()
            if !busy { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Says nothing is playing from this process any more, now, under `fence`
    /// (best effort, bounded by the report timeout). Drops any report still waiting.
    func reportIdle(fence: Int) {
        lock.lock(); pending = nil; lock.unlock()
        flush(timeout: Self.reportTimeout)
        sendNowPlaying(SourceNowPlayingReport(fence: fence, state: .none))
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else { draining = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            sendNowPlaying(next)
        }
    }

    private func sendNowPlaying(_ report: SourceNowPlayingReport) {
        lock.lock(); let offered = nowPlayingOffered; lock.unlock()
        guard offered else { return }
        do { _ = try control.nowPlayingRequest(report, timeout: Self.reportTimeout) } catch SourceAppError.unsupported {
            lock.lock(); nowPlayingOffered = false; lock.unlock()
            log("SpanDAC does not serve \(sourceNowPlayingOp): nothing more is reported")
        } catch {
            log("\(sourceNowPlayingOp) not delivered: \(error)")
        }
    }
}

// MARK: - the reports a transition and the poller make

extension SourceNowPlayingReport {

    /// MusicTUI's word for how the song's rate went, from the transition (M4's
    /// case, then what the confirm and the correction found).
    static func rateWord(_ played: RateTransitionPlayed) -> String {
        // After a correction that resumed the song, its second confirm is the
        // evidence: it is what the DAC is at now.
        if case .answered(let after)? = played.confirmAfterCorrection {
            switch after.outcome {
            case .ownRate: return "corrected"
            case .converted: return "converted"
            case .deliveredUnknown: return "delivered_unknown"
            case .correct: return "mismatch"
            default: break
            }
        }
        if case .answered(let confirm)? = played.confirm {
            switch confirm.outcome {
            case .converted: return "converted"
            case .deliveredUnknown: return "delivered_unknown"
            case .correct:
                if case .resumed = played.correction { return "corrected" }
                return "mismatch"
            default: break
            }
        }
        switch played.startLine {
        case .ownRate, .ownRatePriorPending: return "own_rate"
        case .dacLimit: return "dac_limit"
        case .unknownRate: return "unknown_rate"
        case .quiet: return "quiet"
        case .unconfirmed: return "unconfirmed"
        case .regressed: return "regressed"
        case .noDAC: return "no_dac"
        case .notOffered: return "not_offered"
        case .unavailable: return "unavailable"
        }
    }

    /// The report of a song that just started on the route.
    static func started(_ played: RateTransitionPlayed, persistentID: String?, subject: RouteSubject?) -> SourceNowPlayingReport {
        func answer(_ outcome: SourceRateOutcome?) -> SourceRateAnswer? {
            switch outcome {
            case .answered(let a)?: return a
            case .unsettled(let last)?: return last
            default: return nil
            }
        }
        let prepare = answer(played.rateOutcome)
        // After a correction that resumed the song, the second confirm (the
        // corrected song's own read) is the evidence; the first one, and the
        // prepare's, describe the DAC before the switch. With no second answer,
        // the correction's own is the freshest DAC rate there is, and the
        // earlier ones are left out rather than reported stale.
        var confirm = answer(played.confirm)
        var dacRate = (confirm?.dacRateHz ?? prepare?.dacRateHz)
        if case .resumed(_, let corrected) = played.correction {
            let after = answer(played.confirmAfterCorrection)
            confirm = after ?? confirm
            dacRate = after?.dacRateHz ?? answer(corrected)?.dacRateHz
        }
        var report = SourceNowPlayingReport(fence: played.token.fence, state: .playing)
        report.persistentID = persistentID
        report.databaseID = played.delivered?.databaseID
        report.title = subject?.title
        report.artist = subject?.artist
        report.album = subject?.album
        report.durationMS = subject?.durationMS
        report.positionMS = 0
        report.rateOutcome = rateWord(played)
        report.targetHz = confirm?.targetHz ?? prepare?.targetHz
        report.deliveredHz = played.delivered?.sampleRateHz
        report.dacRateHz = dacRate
        report.priorUnresolved = (prepare?.priorUnresolved ?? false) || (confirm?.priorUnresolved ?? false)
        return report
    }

    /// A song that played with no rate follow (the fence or lock files unusable).
    static func startedUnfollowed(fence: Int, persistentID: String?, subject: RouteSubject?) -> SourceNowPlayingReport {
        var report = SourceNowPlayingReport(fence: fence, state: .playing)
        report.persistentID = persistentID
        report.title = subject?.title
        report.artist = subject?.artist
        report.album = subject?.album
        report.durationMS = subject?.durationMS
        report.positionMS = 0
        report.rateOutcome = "not_followed"
        return report
    }
}
