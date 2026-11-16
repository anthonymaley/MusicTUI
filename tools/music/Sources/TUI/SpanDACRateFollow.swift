// tools/music/Sources/TUI/SpanDACRateFollow.swift
import Foundation

// Rate follow on the Mac: the client half of SpanDAC's four rate ops.
//
// MusicTUI plays through Music.app to the DAC; SpanDAC on this Mac is the only
// writer of the DAC's rate. Each command MusicTUI makes moves a fence number
// (`rate.fence`, beside `output.lock`), and every rate message carries it, so
// SpanDAC never writes for a command a newer one has replaced.
//
// Protocol code only: request bodies, fail-closed reply decoders, the status's
// `rate` object, and the sentence for an older SpanDAC. The fence file, the
// lease and the revalidate-to-play step are score P2 and P3, written against
// the private plan's "Appendix: rate transaction protocol". Contract 3,
// additive, advertised as `output.rate_follow` by the Mac's local Unix-socket
// SpanDAC alone; a SpanDAC on the network never lists it, and an older one
// answers each op `unknown_op`.

/// The capability, and the four ops it covers.
let sourceRateFollowCapability = "output.rate_follow"
let sourceRateFenceOp = "slice.rateFence"
let sourcePrepareRateOp = "slice.prepareRate"
let sourceRateSettleOp = "slice.rateSettle"
let sourceConfirmRateOp = "slice.confirmRate"
/// Appended after the four, under the SAME capability (mac-route S11): MusicTUI
/// tells SpanDAC when the Mac DAC route (rate follow) turns on or off, and what
/// it reports is playing. An older SpanDAC answers each `unknown_op`; this side
/// then latches that op as not offered and never sends it again.
let sourceRateFollowOp = "slice.rateFollow"
let sourceNowPlayingOp = "slice.nowPlaying"

/// The step of one transition. The fence alone decides staleness.
enum SourceRateStep {
    static let prepare = 0
    static let confirm = 1
    static let correct = 2
}

/// What a SpanDAC too old for rate follow means for a person.
let sourceRateFollowUpdateSentence =
    "Playing each song at its own rate needs a newer SpanDAC. Update SpanDAC."

/// The `rate` object of a rate op's reply.
struct SourceRateAnswer: Decodable, Equatable {
    enum Outcome: Equatable {
        case quiet, inFlight, unresolved
        case queued, settled, sameRate, dacLimit, unknownRate, noDAC
        case ownRate, correct, converted, deliveredUnknown
        case superseded, unknownFence
        /// A word this build does not know (a newer SpanDAC). Never a success:
        /// a caller treats it as a current request that did not settle.
        case unrecognised(String)

        init(wire: String) {
            switch wire {
            case "quiet": self = .quiet
            case "in_flight": self = .inFlight
            case "unresolved": self = .unresolved
            case "queued": self = .queued
            case "settled": self = .settled
            case "same_rate": self = .sameRate
            case "dac_limit": self = .dacLimit
            case "unknown_rate": self = .unknownRate
            case "no_dac": self = .noDAC
            case "own_rate": self = .ownRate
            case "correct": self = .correct
            case "converted": self = .converted
            case "delivered_unknown": self = .deliveredUnknown
            case "superseded": self = .superseded
            case "unknown_fence": self = .unknownFence
            default: self = .unrecognised(wire)
            }
        }

        /// Whether polling `slice.rateSettle` may stop.
        var isTerminal: Bool {
            switch self {
            case .queued, .inFlight: return false
            default: return true
            }
        }
    }

    let fence: Int
    let step: Int?
    let outcome: Outcome
    let targetHz: Int?
    let dacRateHz: Int?
    /// An older write SpanDAC never proved: the DAC may still change by itself.
    let priorUnresolved: Bool
    let highestFence: Int?
    /// Rate notifications SpanDAC had seen when it answered. Keep the value of
    /// the answer sound was started on: a later status with more means the
    /// DAC's rate changed after that decision, so the line says so.
    let rateSeq: Int?
    /// false: this DAC's rate will not be put back (SpanDAC has no restore record
    /// for it). nil: unknown (an older SpanDAC omits it), which changes nothing.
    let restorable: Bool?

    enum CodingKeys: String, CodingKey {
        case rateSeq = "rate_seq"
        case fence, step, outcome, restorable
        case targetHz = "target_hz"
        case dacRateHz = "dac_rate_hz"
        case priorUnresolved = "prior_unresolved"
        case highestFence = "highest_fence"
    }

    init(fence: Int, step: Int? = nil, outcome: Outcome, targetHz: Int? = nil, dacRateHz: Int? = nil,
         priorUnresolved: Bool = false, highestFence: Int? = nil, rateSeq: Int? = nil,
         restorable: Bool? = nil) {
        self.rateSeq = rateSeq
        self.restorable = restorable
        self.fence = fence
        self.step = step
        self.outcome = outcome
        self.targetHz = targetHz
        self.dacRateHz = dacRateHz
        self.priorUnresolved = priorUnresolved
        self.highestFence = highestFence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fence = try c.decode(Int.self, forKey: .fence)
        step = try c.decodeIfPresent(Int.self, forKey: .step)
        outcome = Outcome(wire: try c.decode(String.self, forKey: .outcome))
        targetHz = try c.decodeIfPresent(Int.self, forKey: .targetHz)
        dacRateHz = try c.decodeIfPresent(Int.self, forKey: .dacRateHz)
        priorUnresolved = try c.decodeIfPresent(Bool.self, forKey: .priorUnresolved) ?? false
        highestFence = try c.decodeIfPresent(Int.self, forKey: .highestFence)
        rateSeq = try c.decodeIfPresent(Int.self, forKey: .rateSeq)
        restorable = try c.decodeIfPresent(Bool.self, forKey: .restorable)
    }
}

/// `slice.status`'s `rate` object, where rate follow is served.
struct SourceRateFollowStatus: Decodable, Equatable {
    enum Write: String, Decodable, Equatable {
        case idle
        case inFlight = "in_flight"
        case unresolved
    }
    struct Moved: Decodable, Equatable {
        enum Cause: String, Decodable, Equatable {
            case lateSwitch = "late_switch"
            case outside
        }
        /// The highest fence when it happened (the newest song that may be playing).
        let fence: Int
        let toHz: Int?
        let cause: Cause
        /// The `rate_seq` it was counted at.
        let seq: Int
        enum CodingKeys: String, CodingKey {
            case fence, cause, seq
            case toHz = "to_hz"
        }
    }
    let fence: Int?
    let dacRateHz: Int?
    let write: Write
    let startedFence: Int?
    /// Rate notifications seen so far.
    let rateSeq: Int
    /// The last change no settled write explains. It concerns a playing song
    /// when its `fence` is that song's and its `seq` is above the `rate_seq`
    /// the song started on: corrected at the next song, said on the line meanwhile.
    let moved: Moved?
    /// true only while SpanDAC holds a restore record for the followed DAC; false
    /// after it restarted or the record failed; nil from an older SpanDAC
    /// (unknown: change nothing).
    let following: Bool?
    let followedUID: String?
    /// false: this DAC's rate will not be put back. nil: unknown.
    let restorable: Bool?

    enum CodingKeys: String, CodingKey {
        case rateSeq = "rate_seq"
        case fence, write, moved, following, restorable
        case followedUID = "followed_uid"
        case dacRateHz = "dac_rate_hz"
        case startedFence = "started_fence"
    }

    /// The status's `rate` object, or nil when absent (an older SpanDAC, or rate
    /// follow not served) or not readable whole.
    init?(status: [String: Any]) {
        guard let raw = status["rate"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let decoded = try? JSONDecoder().decode(SourceRateFollowStatus.self, from: data) else { return nil }
        self = decoded
    }

    init(fence: Int?, dacRateHz: Int?, write: Write, startedFence: Int?, rateSeq: Int, moved: Moved?,
         following: Bool? = nil, followedUID: String? = nil, restorable: Bool? = nil) {
        self.following = following
        self.followedUID = followedUID
        self.restorable = restorable
        self.rateSeq = rateSeq
        self.fence = fence
        self.dacRateHz = dacRateHz
        self.write = write
        self.startedFence = startedFence
        self.moved = moved
    }
}

extension SourceStatus {
    /// Whether this SpanDAC sets the DAC's rate per song. An older one does
    /// not, and every song plays at the DAC's current rate with
    /// `sourceRateFollowUpdateSentence` on the line.
    var offersRateFollow: Bool { capabilities.contains(sourceRateFollowCapability) }
}

extension SourceAppControl {

    // MARK: Request bodies

    static func rateFenceBody(fence: Int) -> [String: Any] {
        ["op": sourceRateFenceOp, "fence": fence]
    }

    /// A predicted prepare (`rateHz` nil) or a correction to Music's delivered
    /// rate (`step` `correct`, `rateHz` set). Absent identities are left out.
    static func prepareRateBody(fence: Int, step: Int = SourceRateStep.prepare, dacUID: String?,
                                persistentID: String?, catalogID: String?, rateHz: Int? = nil) -> [String: Any] {
        var body: [String: Any] = ["op": sourcePrepareRateOp, "fence": fence, "step": step]
        if let dacUID { body["dac_uid"] = dacUID }
        if let persistentID { body["persistent_id"] = persistentID }
        if let catalogID { body["catalog_id"] = catalogID }
        if let rateHz { body["rate_hz"] = rateHz }
        return body
    }

    /// `step` nil asks for the write state relative to `fence` (a sound start
    /// with no prepare, such as a station).
    static func rateSettleBody(fence: Int, step: Int?) -> [String: Any] {
        var body: [String: Any] = ["op": sourceRateSettleOp, "fence": fence]
        if let step { body["step"] = step }
        return body
    }

    static func confirmRateBody(fence: Int, persistentID: String?, deliveredHz: Int?) -> [String: Any] {
        var body: [String: Any] = ["op": sourceConfirmRateOp, "fence": fence, "step": SourceRateStep.confirm]
        if let persistentID { body["persistent_id"] = persistentID }
        if let deliveredHz { body["delivered_hz"] = deliveredHz }
        return body
    }

    // MARK: Reply

    /// A successful reply, fail closed, for the fence that was asked about: a
    /// `rate` object that decodes whole and echoes `fence`. Anything less is a
    /// peer that broke the contract, never an answer.
    static func rateAnswer(from reply: [String: Any], op: String, fence: Int) throws -> SourceRateAnswer {
        guard let raw = reply["rate"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let answer = try? JSONDecoder().decode(SourceRateAnswer.self, from: data) else {
            throw SourceAppError.malformedReply("SpanDAC's \(op) reply has no readable rate answer")
        }
        guard answer.fence == fence else {
            throw SourceAppError.malformedReply("SpanDAC's \(op) reply is for another fence")
        }
        return answer
    }

    /// Sends one rate op on the command transport and decodes its answer. An
    /// older SpanDAC's `unknown_op` arrives as `SourceAppError.unsupported(op)`.
    ///
    /// `timeout` is how long this one exchange may wait for the reply, where the
    /// control has a rate sender (the Mac's Unix socket); otherwise the
    /// transport's own timeout applies.
    func rateRequest(_ body: [String: Any], timeout: TimeInterval? = nil) throws -> SourceRateAnswer {
        let op = body["op"] as? String ?? "slice"
        guard let fence = body["fence"] as? Int else {
            throw SourceAppError.refused("a rate request needs its fence")
        }
        let reply: [String: Any]
        if let timeout, let rateSender {
            reply = try send(body, over: rateSender(timeout))
        } else {
            reply = try send(body)
        }
        return try Self.rateAnswer(from: reply, op: op, fence: fence)
    }
}

// MARK: - mac-route S11: `slice.rateFollow` and `slice.nowPlaying`

/// `slice.rateFollow`'s reply: the `rate` answer of the fence it published (a
/// `superseded` one means a newer command replaced this message and SpanDAC
/// applied nothing), and the `follow` object when it did.
struct SourceRateFollowAck: Equatable {
    let answer: SourceRateAnswer
    /// False when `on` named no DAC and SpanDAC's Output tab has none.
    let applied: Bool?
    /// How the restore of the DAC left behind ended, on a turn-off.
    let restore: String?

    /// Whether SpanDAC applied this message: its fence was current and it had a DAC.
    var wasApplied: Bool {
        if case .superseded = answer.outcome { return false }
        return applied == true
    }
}

/// What MusicTUI reports is playing, for SpanDAC's Mac screen (D6). Every field
/// but `fence` and `state` is omitted from the wire when unknown. `persistentID`
/// is Music.app's own (sixteen hex digits); `rateOutcome` is a word of
/// MusicTUI's own (see `SourceNowPlayingReport.rateWord`), free on the wire.
struct SourceNowPlayingReport: Equatable {
    enum State: String, Equatable {
        case playing, paused, stopped
        /// Nothing is playing on the route (left, or closed): clears the screen.
        case none
    }

    var fence: Int
    var state: State
    var persistentID: String? = nil
    var databaseID: Int? = nil
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var durationMS: Int? = nil
    var positionMS: Int? = nil
    var rateOutcome: String? = nil
    var targetHz: Int? = nil
    var deliveredHz: Int? = nil
    var dacRateHz: Int? = nil
    var priorUnresolved = false

    var body: [String: Any] {
        var body: [String: Any] = ["op": sourceNowPlayingOp, "fence": fence, "state": state.rawValue]
        if let persistentID { body["persistent_id"] = persistentID }
        if let databaseID { body["database_id"] = databaseID }
        if let title, !title.isEmpty { body["title"] = title }
        if let artist, !artist.isEmpty { body["artist"] = artist }
        if let album, !album.isEmpty { body["album"] = album }
        if let durationMS { body["duration_ms"] = durationMS }
        if let positionMS { body["position_ms"] = positionMS }
        if let rateOutcome { body["rate_outcome"] = rateOutcome }
        if let targetHz { body["target_hz"] = targetHz }
        if let deliveredHz { body["delivered_hz"] = deliveredHz }
        if let dacRateHz { body["dac_rate_hz"] = dacRateHz }
        if priorUnresolved { body["prior_unresolved"] = true }
        return body
    }
}

extension SourceAppControl {

    /// `dacUID` nil: SpanDAC uses the DAC its Output tab chose.
    static func rateFollowBody(fence: Int, on: Bool, dacUID: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["op": sourceRateFollowOp, "fence": fence, "on": on]
        if let dacUID { body["dac_uid"] = dacUID }
        return body
    }

    /// A successful `slice.rateFollow` reply, fail closed: a readable `rate`
    /// answer echoing `fence`; `follow` is optional (absent when superseded).
    static func rateFollowAck(from reply: [String: Any], fence: Int) throws -> SourceRateFollowAck {
        let answer = try rateAnswer(from: reply, op: sourceRateFollowOp, fence: fence)
        let follow = reply["follow"] as? [String: Any]
        return SourceRateFollowAck(answer: answer, applied: follow?["applied"] as? Bool,
                                   restore: follow?["restore"] as? String)
    }

    /// One `slice.rateFollow` exchange at a stated timeout. An older SpanDAC's
    /// `unknown_op` arrives as `SourceAppError.unsupported`.
    func rateFollowRequest(fence: Int, on: Bool, dacUID: String? = nil,
                           timeout: TimeInterval) throws -> SourceRateFollowAck {
        let body = Self.rateFollowBody(fence: fence, on: on, dacUID: dacUID)
        let reply: [String: Any]
        if let rateSender { reply = try send(body, over: rateSender(timeout)) } else { reply = try send(body) }
        return try Self.rateFollowAck(from: reply, fence: fence)
    }

    /// One `slice.nowPlaying` exchange; true when SpanDAC took the report (false:
    /// it holds a newer fence). Fail closed on a reply with no `now_playing`.
    func nowPlayingRequest(_ report: SourceNowPlayingReport, timeout: TimeInterval) throws -> Bool {
        let reply: [String: Any]
        if let rateSender { reply = try send(report.body, over: rateSender(timeout)) } else { reply = try send(report.body) }
        guard let ack = reply["now_playing"] as? [String: Any], let accepted = ack["accepted"] as? Bool else {
            throw SourceAppError.malformedReply("SpanDAC's \(sourceNowPlayingOp) reply has no readable answer")
        }
        return accepted
    }
}
