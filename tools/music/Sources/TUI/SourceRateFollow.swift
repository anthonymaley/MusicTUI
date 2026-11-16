// tools/music/Sources/TUI/SourceRateFollow.swift
import Foundation

// The client ops of one rate transition (mac-route-plan.md, "Appendix: rate
// transaction protocol", rules M1, M2, M4 and M5; score step P2). One
// `SourceRateFollow` serves one `RateToken`: it sends the token's fence in every
// message, keeps the `rate_seq` baseline M5 needs, and waits for the DAC to be
// quiet within M2's bound. It decides nothing about whether to play: the fence
// file and the lease (`RateFence`) do, and the transition (P3) puts them
// together.
//
// Wire bodies and answer decoding are `SpanDACRateFollow.swift`. Nothing here
// opens a socket: the `SourceAppControl` it is given carries the transport.

/// What one exchange, or one bounded wait, came to.
enum SourceRateOutcome: Equatable {
    /// SpanDAC answered, and the answer is final for this question.
    case answered(SourceRateAnswer)
    /// The cap passed without a final answer: `last` is the newest non-final
    /// answer (`queued`, `in_flight`), or nil when SpanDAC never answered. The
    /// song still plays (M4), and the line says the switch is unconfirmed.
    case unsettled(last: SourceRateAnswer?)
    /// An older SpanDAC, or one that does not serve rate follow: nothing was
    /// sent, or its `unknown_op` was the answer. The song plays at the DAC's
    /// rate and the line is `sourceRateFollowUpdateSentence`.
    case notOffered
    /// SpanDAC could not be asked: not running, refusing, a broken reply. The
    /// request is still current, so the song plays and the line says why.
    case failed(SourceAppError)
}

/// What the line says about the rate when the song starts (M4). The words are
/// P6's; this is which case it is.
enum SourceRateStartLine: Equatable {
    /// The DAC is at the song's rate and nothing older may still change it.
    case ownRate
    /// Own rate now, but an older write may still land: never "settled".
    case ownRatePriorPending
    case dacLimit
    case unknownRate
    /// Nothing was pending (a station, a resume): the line states the DAC's
    /// readback, with no conversion claim.
    case quiet
    /// The switch is not confirmed (cap, no answer, an unknown word).
    case unconfirmed
    /// `superseded` while the fence file still held our fence: the file was
    /// lost and SpanDAC cannot tell. The song plays at the DAC's rate.
    case regressed
    case noDAC
    /// An older SpanDAC: `sourceRateFollowUpdateSentence`.
    case notOffered
    /// SpanDAC could not be asked.
    case unavailable(SourceAppError)

    /// M4, from the terminal answer (or none). Call it for a token that just
    /// passed M3's revalidation: only then is a `superseded` answer a regression
    /// rather than a newer command.
    static func line(for outcome: SourceRateOutcome) -> SourceRateStartLine {
        switch outcome {
        case .notOffered: return .notOffered
        case .failed(let error): return .unavailable(error)
        case .unsettled: return .unconfirmed
        case .answered(let answer):
            switch answer.outcome {
            case .settled, .sameRate: return answer.priorUnresolved ? .ownRatePriorPending : .ownRate
            case .dacLimit: return .dacLimit
            case .unknownRate: return .unknownRate
            case .quiet: return answer.priorUnresolved ? .unconfirmed : .quiet
            case .superseded: return .regressed
            case .noDAC: return .noDAC
            default: return .unconfirmed
            }
        }
    }

    /// The sentence for the one case this step words: an older SpanDAC.
    var sentence: String? {
        if case .notOffered = self { return sourceRateFollowUpdateSentence }
        return nil
    }
}

final class SourceRateFollow {

    /// M2: how long a prepare's reply is waited for. Sent as the exchange's own
    /// timeout (`SourceAppControl.rateRequest(_:timeout:)`, which the Mac's
    /// control, `SourceAppControl.macRate`, honours at fractions of a second),
    /// and shrunk to what is left of the cap.
    static let prepareReplyWait: TimeInterval = 2.5
    /// How long one poll's reply is waited for. SpanDAC answers `rateSettle`,
    /// `rateFence` and `confirmRate` without waiting behind a job (S1), so a
    /// poll that has not answered in this long is a busy SpanDAC, asked again.
    static let pollReplyWait: TimeInterval = 1.0
    /// M2: the poll interval.
    static let pollInterval: TimeInterval = 0.25
    /// M2: the cap, measured from the send. The wait never exceeds it and never refuses.
    static let cap: TimeInterval = 4.5

    let token: RateToken
    private let control: SourceAppControl
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    /// False once SpanDAC is known not to serve rate follow; then nothing is sent.
    private(set) var offered: Bool
    /// The `rate_seq` of the LAST rate answer received before the song played
    /// (the fence ack, the prepare's answer, or a settle poll; for a correction,
    /// the correction's). nil when SpanDAC never answered: the song is
    /// "unconfirmed" throughout. M5 compares the status's `rate_seq` with it.
    private(set) var baseline: Int?

    /// The process's route reporter (S11), nil in every test that predates it:
    /// then a transition sends exactly the messages it always sent.
    private let routeFollow: MacRouteFollowReporter?

    init(token: RateToken, control: SourceAppControl, offered: Bool,
         routeFollow: MacRouteFollowReporter? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.token = token
        self.control = control
        self.offered = offered
        self.routeFollow = routeFollow
        self.now = now
        self.sleep = sleep
    }

    /// Rate follow is offered when `slice.status` lists `output.rate_follow`.
    convenience init(token: RateToken, control: SourceAppControl, status: SourceStatus,
                     now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.init(token: token, control: control, offered: status.offersRateFollow, now: now, sleep: sleep)
    }

    // MARK: M1

    /// `slice.rateFence {fence}`, sent after the increment by every command
    /// whose next message is not a prepare. One exchange, no waiting for rate
    /// work: `in_flight` is an answer.
    func announce() -> SourceRateOutcome {
        guard offered else { return .notOffered }
        switch exchange(SourceAppControl.rateFenceBody(fence: token.fence)) {
        case .success(let answer): return .answered(answer)
        case .failure(let error): return outcome(for: error)
        }
    }

    // MARK: M2

    /// A song: `slice.prepareRate {fence, step 0}` carries the fence itself (no
    /// separate announce), then polls `slice.rateSettle {fence, step 0}` every
    /// 250 ms until the answer is final or the cap passes.
    func prepare(dacUID: String?, persistentID: String?, catalogID: String?) -> SourceRateOutcome {
        wait(announcesRoute: true, first: SourceAppControl.prepareRateBody(fence: token.fence, dacUID: dacUID,
                                                      persistentID: persistentID, catalogID: catalogID),
             poll: SourceAppControl.rateSettleBody(fence: token.fence, step: SourceRateStep.prepare))
    }

    /// A sound start with no rate work (a station, a resume): polls
    /// `slice.rateSettle {fence}` with no step until `quiet` or `unresolved`
    /// (or any other final word), or the cap. Its first poll carries the fence
    /// if the announce was lost.
    func awaitQuiet() -> SourceRateOutcome {
        wait(announcesRoute: true, first: nil, poll: SourceAppControl.rateSettleBody(fence: token.fence, step: nil))
    }

    // MARK: M5

    /// The correction: `slice.prepareRate {fence, step 2, rate_hz}`, waited on
    /// as a prepare is. Its answer becomes the baseline.
    func correct(toHz rateHz: Int, dacUID: String?, persistentID: String?) -> SourceRateOutcome {
        wait(announcesRoute: false, first: SourceAppControl.prepareRateBody(fence: token.fence, step: SourceRateStep.correct,
                                                      dacUID: dacUID, persistentID: persistentID, catalogID: nil,
                                                      rateHz: rateHz),
             poll: SourceAppControl.rateSettleBody(fence: token.fence, step: SourceRateStep.correct))
    }

    /// `slice.confirmRate {fence, step 1, delivered_hz}` from the one
    /// identity-checked read. It leaves the baseline alone: the baseline is what
    /// was known when the sound started.
    func confirm(persistentID: String?, deliveredHz: Int?) -> SourceRateOutcome {
        guard offered else { return .notOffered }
        let body = SourceAppControl.confirmRateBody(fence: token.fence, persistentID: persistentID,
                                                    deliveredHz: deliveredHz)
        switch exchange(body, updatesBaseline: false) {
        case .success(let answer): return .answered(answer)
        case .failure(let error): return outcome(for: error)
        }
    }

    /// M5's warning while a song plays: the status's `rate_seq` is above the
    /// baseline, so the DAC's rate changed after the decision (never corrected
    /// mid-song; the next transition's prepare is the correction). With no
    /// baseline the warning stands for the whole song.
    static func warnsOfRateChange(baseline: Int?, status: SourceRateFollowStatus) -> Bool {
        guard let baseline else { return true }
        return status.rateSeq > baseline
    }

    // MARK: private

    /// S11: before a sound start's first rate message, tell SpanDAC the route is
    /// on (once, until it confirms), under this transition's own fence, so its
    /// restore record is taken before SpanDAC changes the DAC's rate. Counted in
    /// the cap like every other wait of this start. Nothing for a correction.
    private func wait(announcesRoute: Bool, first: [String: Any]?, poll: [String: Any]) -> SourceRateOutcome {
        guard offered else { return .notOffered }
        let started = now()
        if announcesRoute, let routeFollow {
            routeFollow.ensureOn(fence: token.fence,
                                 timeout: Self.replyTimeout(MacRouteFollowReporter.ensureTimeout, left: Self.cap))
        }
        var last: SourceRateAnswer?
        if let first {
            switch exchange(first, timeout: Self.replyTimeout(Self.prepareReplyWait, left: Self.cap - (now() - started))) {
            case .success(let answer):
                if answer.outcome.isTerminal { return .answered(answer) }
                last = answer
            case .failure(let error):
                if let ending = ending(for: error) { return ending }
            }
        }
        while now() - started < Self.cap {
            let left = Self.cap - (now() - started)
            switch exchange(poll, timeout: Self.replyTimeout(Self.pollReplyWait, left: left)) {
            case .success(let answer):
                if answer.outcome.isTerminal { return .answered(answer) }
                last = answer
            case .failure(let error):
                if let ending = ending(for: error) { return ending }
            }
            let remaining = Self.cap - (now() - started)
            if remaining <= 0 { break }
            sleep(min(Self.pollInterval, remaining))
        }
        return .unsettled(last: last)
    }

    /// A timeout or a busy SpanDAC is a reason to ask again within the cap;
    /// everything else ends the wait.
    private func ending(for error: SourceAppError) -> SourceRateOutcome? {
        switch error {
        case .timedOut, .busy: return nil
        default: return outcome(for: error)
        }
    }

    private func outcome(for error: SourceAppError) -> SourceRateOutcome {
        if case .unsupported = error { offered = false; return .notOffered }
        return .failed(error)
    }

    /// A reply wait never runs past the cap: it is `wanted`, or what is left of
    /// the cap if that is less (the socket layer floors it above zero).
    static func replyTimeout(_ wanted: TimeInterval, left: TimeInterval) -> TimeInterval {
        min(wanted, max(left, 0))
    }

    private func exchange(_ body: [String: Any], updatesBaseline: Bool = true,
                          timeout: TimeInterval = SourceRateFollow.prepareReplyWait) -> Result<SourceRateAnswer, SourceAppError> {
        do {
            let answer = try control.rateRequest(body, timeout: timeout)
            if updatesBaseline, let seq = answer.rateSeq { baseline = seq }
            return .success(answer)
        } catch let error as SourceAppError {
            return .failure(error)
        } catch {
            return .failure(.unreadable)
        }
    }
}
