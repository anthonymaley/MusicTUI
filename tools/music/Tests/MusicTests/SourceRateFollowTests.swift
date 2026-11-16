// tools/music/Tests/MusicTests/SourceRateFollowTests.swift
//
// The client ops of one rate transition (mac-route-plan.md, "Appendix: rate
// transaction protocol", M1, M2, M4, M5), against a fixture SpanDAC and a fake
// clock, and together with the real fence file where the appendix's client
// interleavings need it. No socket, no player, no real time.
import XCTest
@testable import music

final class SourceRateFollowTests: XCTestCase {

    // MARK: support

    /// A fake clock that moves only when a wait or a slow reply moves it.
    private final class Clock {
        var t: TimeInterval = 0
        var sleeps: [TimeInterval] = []
    }

    /// One scripted SpanDAC: each request is recorded with the time it was
    /// sent, and answered from `script` (nil answer = the transport times out
    /// after `timeoutCost` seconds).
    private final class Wire {
        let clock: Clock
        var requests: [(at: TimeInterval, body: [String: Any])] = []
        var script: ([String: Any]) throws -> String = { _ in throw SourceAppError.timedOut }
        var timeoutCost: TimeInterval = 2.5
        init(_ clock: Clock) { self.clock = clock }
        var ops: [String] { requests.compactMap { $0.body["op"] as? String } }
    }

    private func make(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent", transport: { _, line in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            wire.requests.append((wire.clock.t, body))
            do { return try wire.script(body) } catch SourceAppError.timedOut {
                wire.clock.t += wire.timeoutCost
                throw SourceAppError.timedOut
            }
        })
    }

    private func follow(_ token: RateToken, _ wire: Wire, offered: Bool = true) -> SourceRateFollow {
        SourceRateFollow(token: token, control: make(wire), offered: offered,
                         now: { wire.clock.t },
                         sleep: { wire.clock.sleeps.append($0); wire.clock.t += $0 })
    }

    private func answer(_ fence: Int, _ outcome: String, seq: Int? = nil, prior: Bool = false, step: Int? = nil) -> String {
        var rate: [String: Any] = ["fence": fence, "outcome": outcome]
        if let seq { rate["rate_seq"] = seq }
        if prior { rate["prior_unresolved"] = true }
        if let step { rate["step"] = step }
        let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "rate": rate])
        return String(decoding: data, as: UTF8.self)
    }

    private let token = RateToken(fence: 41, owner: "tui", command: .play)

    // MARK: M1: every command's first message carries the fence the file just took

    /// For every command, the fence message names the fence that was in the
    /// file when it was sent, and each is one past the last.
    func testEveryCommandsFenceMessageCarriesTheFileFence() throws {
        let dir = OutputLockTestSupport.tempDir()
        let f = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let clock = Clock()
        let wire = Wire(clock)
        var fileAtSend: [Int] = []
        wire.script = { body in
            let text = (try? String(contentsOfFile: dir + "/rate.fence", encoding: .utf8)) ?? ""
            fileAtSend.append(Int(text) ?? -1)
            return self.answer(body["fence"] as? Int ?? -1, "quiet", seq: 1)
        }
        for command in RateCommand.allCases {
            _ = try f.run(command, owner: "tui") { token in follow(token, wire).announce() }
        }
        XCTAssertEqual(wire.ops, Array(repeating: sourceRateFenceOp, count: RateCommand.allCases.count))
        let sent = wire.requests.compactMap { $0.body["fence"] as? Int }
        XCTAssertEqual(sent, Array(1...RateCommand.allCases.count))
        XCTAssertEqual(fileAtSend, sent, "a message went out before the file moved to its fence")
    }

    func testAnnounceIsOneMessageAndDoesNotWaitForRateWork() {
        let wire = Wire(Clock())
        wire.script = { _ in self.answer(41, "in_flight", seq: 4) }
        let f = follow(token, wire)
        XCTAssertEqual(f.announce(), .answered(SourceRateAnswer(fence: 41, outcome: .inFlight, rateSeq: 4)))
        XCTAssertEqual(wire.ops, [sourceRateFenceOp])
        XCTAssertEqual(Set(wire.requests[0].body.keys), ["op", "fence"])
        XCTAssertEqual(wire.clock.sleeps, [], "a fence announce never waits")
        XCTAssertEqual(f.baseline, 4)
    }

    /// M1's exception: a song's prepare carries the fence itself, so a lost
    /// announce costs nothing, and no separate fence message goes first.
    func testASongsPrepareCarriesTheFenceItselfAndNoAnnounceGoesFirst() {
        let wire = Wire(Clock())
        wire.script = { _ in self.answer(41, "settled", seq: 2, step: 0) }
        let out = follow(token, wire).prepare(dacUID: "ssl", persistentID: "9", catalogID: nil)
        XCTAssertEqual(wire.ops, [sourcePrepareRateOp])
        XCTAssertEqual(wire.requests[0].body["fence"] as? Int, 41)
        XCTAssertEqual(wire.requests[0].body["step"] as? Int, 0)
        XCTAssertEqual(out, .answered(SourceRateAnswer(fence: 41, step: 0, outcome: .settled, rateSeq: 2)))
    }

    // MARK: M2

    /// A queued prepare is polled with `rateSettle` step 0 every 250 ms until it
    /// settles.
    func testAQueuedPrepareIsPolledEvery250msUntilItSettles() {
        let wire = Wire(Clock())
        var polls = 0
        wire.script = { body in
            switch body["op"] as? String {
            case sourcePrepareRateOp: return self.answer(41, "queued", seq: 1)
            default:
                polls += 1
                return self.answer(41, polls < 3 ? "in_flight" : "settled", seq: 1 + polls)
            }
        }
        let f = follow(token, wire)
        let out = f.prepare(dacUID: nil, persistentID: "9", catalogID: nil)
        XCTAssertEqual(wire.ops, [sourcePrepareRateOp, sourceRateSettleOp, sourceRateSettleOp, sourceRateSettleOp])
        XCTAssertEqual(wire.requests[1].body["step"] as? Int, 0)
        XCTAssertEqual(wire.requests[1].body["fence"] as? Int, 41)
        XCTAssertEqual(wire.requests.map(\.at), [0, 0, 0.25, 0.5])
        guard case .answered(let final) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(final.outcome, .settled)
        XCTAssertEqual(f.baseline, 4, "the baseline is the LAST answer's rate_seq")
    }

    /// The write completes after the caller's 2.5 s: the prepare times out, the
    /// polls find `in_flight` and then `settled`.
    func testAPrepareThatTimesOutThenPollsToSettled() {
        let wire = Wire(Clock())
        var polls = 0
        wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp { throw SourceAppError.timedOut }
            polls += 1
            return self.answer(41, polls < 3 ? "in_flight" : "settled", seq: 5)
        }
        let out = follow(token, wire).prepare(dacUID: nil, persistentID: "9", catalogID: nil)
        guard case .answered(let final) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(final.outcome, .settled)
        XCTAssertEqual(wire.requests.first?.at, 0)
        XCTAssertEqual(wire.requests[1].at, 2.5, "the first poll follows the 2.5 s wait")
    }

    /// Never settled: the wait ends at the cap, never past it, never refuses, and
    /// the answer is "unsettled" carrying the last non-final answer.
    func testTheWaitEndsAtTheCapAndNeverRefuses() {
        let wire = Wire(Clock())
        wire.script = { body in
            if body["op"] as? String == sourcePrepareRateOp { throw SourceAppError.timedOut }
            return self.answer(41, "in_flight", seq: 6, prior: true)
        }
        let f = follow(token, wire)
        let out = f.prepare(dacUID: nil, persistentID: "9", catalogID: nil)
        XCTAssertEqual(out, .unsettled(last: SourceRateAnswer(fence: 41, outcome: .inFlight, priorUnresolved: true, rateSeq: 6)))
        XCTAssertLessThanOrEqual(wire.clock.t, SourceRateFollow.cap, "the wait ran past the cap")
        XCTAssertEqual(SourceRateStartLine.line(for: out), .unconfirmed)
        XCTAssertEqual(f.baseline, 6)
    }

    /// SpanDAC silent to the cap: no answer at all, no baseline, and the warning
    /// stands for the whole song whatever the status later says.
    func testNoAnswerMeansNoBaselineAndTheWarningStandsForTheSong() {
        let wire = Wire(Clock())
        let f = follow(token, wire)                       // every request times out at 2.5 s
        let out = f.prepare(dacUID: nil, persistentID: "9", catalogID: nil)
        XCTAssertEqual(out, .unsettled(last: nil))
        XCTAssertNil(f.baseline)
        let calm = SourceRateFollowStatus(fence: 41, dacRateHz: 96000, write: .idle, startedFence: 41, rateSeq: 0, moved: nil)
        XCTAssertTrue(SourceRateFollow.warnsOfRateChange(baseline: nil, status: calm))
        XCTAssertEqual(SourceRateStartLine.line(for: out), .unconfirmed)
    }

    /// A station (a sound start with no rate work) whose fence message was lost:
    /// its first `rateSettle` poll carries the fence. The older write never
    /// proves itself, so SpanDAC answers `in_flight` and then `unresolved` at the
    /// cap, and the station plays "unconfirmed" with no settled claim.
    func testAStationAfterALostFenceMessagePollsWithItsFenceAndPlaysUnconfirmed() {
        let wire = Wire(Clock())
        wire.script = { _ in
            self.answer(41, wire.clock.t >= 4.0 ? "unresolved" : "in_flight", seq: 3, prior: true)
        }
        let out = follow(token, wire).awaitQuiet()
        XCTAssertEqual(Set(wire.ops), [sourceRateSettleOp], "no announce, and no prepare")
        XCTAssertTrue(wire.requests.allSatisfy { $0.body["fence"] as? Int == 41 && $0.body["step"] == nil })
        guard case .answered(let final) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(final.outcome, .unresolved)
        XCTAssertLessThanOrEqual(wire.clock.t, SourceRateFollow.cap)
        XCTAssertEqual(SourceRateStartLine.line(for: out), .unconfirmed)
    }

    func testAStationStopsAtQuiet() {
        let wire = Wire(Clock())
        var polls = 0
        wire.script = { _ in polls += 1; return self.answer(41, polls < 2 ? "in_flight" : "quiet", seq: 1) }
        let out = follow(token, wire).awaitQuiet()
        XCTAssertEqual(wire.requests.count, 2)
        XCTAssertEqual(SourceRateStartLine.line(for: out), .quiet)
    }

    /// A SpanDAC that is not running ends the wait at once: the request is still
    /// current, so the song plays and the line says why. No polling a dead socket.
    func testASpanDACThatCannotBeAskedEndsTheWaitAtOnce() {
        let wire = Wire(Clock())
        wire.script = { _ in throw SourceAppError.notRunning }
        let out = follow(token, wire).prepare(dacUID: nil, persistentID: "9", catalogID: nil)
        XCTAssertEqual(out, .failed(.notRunning))
        XCTAssertEqual(wire.requests.count, 1)
        XCTAssertEqual(SourceRateStartLine.line(for: out), .unavailable(.notRunning))
    }

    /// A reply that breaks the contract is not an answer.
    func testAReplyForAnotherFenceIsNotAnAnswer() {
        let wire = Wire(Clock())
        wire.script = { _ in self.answer(40, "settled", seq: 1) }
        guard case .failed(.malformedReply) = follow(token, wire).prepare(dacUID: nil, persistentID: "9", catalogID: nil) else {
            return XCTFail("another fence's answer was taken")
        }
    }

    // MARK: M4

    func testTheStartLineTable() {
        func line(_ outcome: SourceRateAnswer.Outcome, prior: Bool = false) -> SourceRateStartLine {
            SourceRateStartLine.line(for: .answered(SourceRateAnswer(fence: 1, outcome: outcome, priorUnresolved: prior)))
        }
        XCTAssertEqual(line(.settled), .ownRate)
        XCTAssertEqual(line(.sameRate), .ownRate)
        XCTAssertEqual(line(.settled, prior: true), .ownRatePriorPending, "never 'settled' with an older write unresolved")
        XCTAssertEqual(line(.sameRate, prior: true), .ownRatePriorPending)
        XCTAssertEqual(line(.dacLimit), .dacLimit)
        XCTAssertEqual(line(.unknownRate), .unknownRate)
        XCTAssertEqual(line(.superseded), .regressed)
        XCTAssertEqual(line(.noDAC), .noDAC)
        XCTAssertEqual(line(.quiet), .quiet)
        XCTAssertEqual(line(.quiet, prior: true), .unconfirmed)
        for outcome in [SourceRateAnswer.Outcome.unresolved, .inFlight, .queued, .unknownFence, .deliveredUnknown,
                        .ownRate, .converted, .correct, .unrecognised("teleported")] {
            XCTAssertEqual(line(outcome), .unconfirmed, "\(outcome)")
        }
    }

    // MARK: M5

    func testConfirmLeavesTheBaselineAndACorrectionReplacesIt() {
        let wire = Wire(Clock())
        wire.script = { body in
            switch body["op"] as? String {
            case sourcePrepareRateOp where body["step"] as? Int == 2: return self.answer(41, "settled", seq: 9, step: 2)
            case sourcePrepareRateOp: return self.answer(41, "settled", seq: 3, step: 0)
            default: return self.answer(41, "correct", seq: 8, step: 1)
            }
        }
        let f = follow(token, wire)
        _ = f.prepare(dacUID: "ssl", persistentID: "9", catalogID: nil)
        XCTAssertEqual(f.baseline, 3)
        let confirmed = f.confirm(persistentID: "9", deliveredHz: 44100)
        guard case .answered(let c) = confirmed else { return XCTFail("\(confirmed)") }
        XCTAssertEqual(c.outcome, .correct)
        XCTAssertEqual(wire.requests.last?.body["step"] as? Int, 1)
        XCTAssertEqual(wire.requests.last?.body["delivered_hz"] as? Int, 44100)
        XCTAssertEqual(f.baseline, 3, "a confirm clears nothing and moves no baseline")

        _ = f.correct(toHz: 44100, dacUID: "ssl", persistentID: "9")
        let correction = wire.requests.last { $0.body["op"] as? String == sourcePrepareRateOp }!.body
        XCTAssertEqual(correction["step"] as? Int, 2)
        XCTAssertEqual(correction["rate_hz"] as? Int, 44100)
        XCTAssertEqual(correction["fence"] as? Int, 41, "a correction is the same fence, step 2")
        XCTAssertEqual(f.baseline, 9)
    }

    func testARateSeqAboveTheBaselineWarnsAtAnyPointOfTheSong() {
        func status(_ seq: Int) -> SourceRateFollowStatus {
            SourceRateFollowStatus(fence: 41, dacRateHz: 96000, write: .idle, startedFence: 41, rateSeq: seq, moved: nil)
        }
        XCTAssertFalse(SourceRateFollow.warnsOfRateChange(baseline: 5, status: status(5)))
        XCTAssertTrue(SourceRateFollow.warnsOfRateChange(baseline: 5, status: status(6)))
    }

    // MARK: An older SpanDAC

    /// Its status lists no `output.rate_follow`: every op is answered locally
    /// with `notOffered` and NOTHING goes down the socket; the line is the
    /// "Update SpanDAC" sentence.
    func testAnOlderSpanDACGetsTheUpdateLineAndNoMessages() throws {
        let statusJSON = #"{"playback":"paused","contract":3,"capabilities":["slice.status","output.use_dac","queue.jump"]}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(statusJSON.utf8)) as? [String: Any])
        let status = try XCTUnwrap(SourceAppControl.decodeStatus(object, readingWith: SourceAppControl(path: "/nonexistent")))
        let wire = Wire(Clock())
        let f = SourceRateFollow(token: token, control: make(wire), status: status,
                                 now: { wire.clock.t }, sleep: { wire.clock.t += $0 })
        XCTAssertFalse(f.offered)

        XCTAssertEqual(f.announce(), .notOffered)
        XCTAssertEqual(f.prepare(dacUID: "ssl", persistentID: "9", catalogID: nil), .notOffered)
        XCTAssertEqual(f.awaitQuiet(), .notOffered)
        XCTAssertEqual(f.correct(toHz: 44100, dacUID: "ssl", persistentID: "9"), .notOffered)
        XCTAssertEqual(f.confirm(persistentID: "9", deliveredHz: 44100), .notOffered)
        XCTAssertEqual(wire.requests.count, 0, "an older SpanDAC was sent a rate message")
        XCTAssertEqual(wire.clock.t, 0, "an older SpanDAC was waited on")

        let line = SourceRateStartLine.line(for: .notOffered)
        XCTAssertEqual(line, .notOffered)
        XCTAssertEqual(line.sentence, sourceRateFollowUpdateSentence)
        XCTAssertTrue(try XCTUnwrap(line.sentence).contains("Update SpanDAC"))
    }

    func testANewSpanDACsStatusIsOffered() throws {
        let statusJSON = #"{"playback":"paused","capabilities":["slice.status","output.rate_follow"]}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(statusJSON.utf8)) as? [String: Any])
        let status = try XCTUnwrap(SourceAppControl.decodeStatus(object, readingWith: SourceAppControl(path: "/nonexistent")))
        let wire = Wire(Clock())
        XCTAssertTrue(SourceRateFollow(token: token, control: make(wire), status: status).offered)
    }

    /// A SpanDAC whose status was not read answers `unknown_op` to the first rate
    /// message: that is the same "older", and nothing more is sent after it.
    func testAnUnknownOpIsTheSameAsOlderAndStopsTheFollow() {
        let wire = Wire(Clock())
        wire.script = { body in
            #"{"ok":false,"op":"\#(body["op"] as? String ?? "")","error":{"kind":"unknown_op","detail":"unknown op"}}"#
        }
        let f = follow(token, wire)
        XCTAssertEqual(f.prepare(dacUID: nil, persistentID: "9", catalogID: nil), .notOffered)
        XCTAssertFalse(f.offered)
        XCTAssertEqual(f.announce(), .notOffered)
        XCTAssertEqual(f.confirm(persistentID: "9", deliveredHz: 44100), .notOffered)
        XCTAssertEqual(wire.requests.count, 1, "messages kept going to a SpanDAC that does not know the op")
    }

    /// The fence file still moves on an older SpanDAC (M1 is MusicTUI's own
    /// order, with or without a follower), and the song plays.
    func testTheFenceStillMovesAndTheSongStillPlaysOnAnOlderSpanDAC() throws {
        let dir = OutputLockTestSupport.tempDir()
        let f = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let wire = Wire(Clock())
        var played: [String] = []
        try f.run(.play, owner: "tui") { token in
            let rate = follow(token, wire, offered: false)
            let outcome = rate.prepare(dacUID: nil, persistentID: "9", catalogID: nil)
            XCTAssertEqual(try f.playIfCurrent(token) { played.append("Aja"); return 1 }, .played(1))
            XCTAssertEqual(SourceRateStartLine.line(for: outcome), .notOffered)
        }
        XCTAssertEqual(played, ["Aja"])
        XCTAssertEqual(try f.current(), 1)
        XCTAssertEqual(wire.requests.count, 0)
    }

    // MARK: With the fence file (the appendix's client interleavings)

    /// The fence file was lost: SpanDAC's highest is above ours, so it answers
    /// `superseded` while our file still holds our fence. The client is current,
    /// so the song PLAYS, and the line says regressed.
    func testARegressedFencePlaysAtTheCurrentRate() throws {
        let dir = OutputLockTestSupport.tempDir()
        let f = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let wire = Wire(Clock())
        wire.script = { body in self.answer(body["fence"] as? Int ?? 0, "superseded", seq: 1) }
        var played: [String] = []
        var line: SourceRateStartLine?
        try f.run(.play, owner: "tui") { token in
            let outcome = follow(token, wire).prepare(dacUID: nil, persistentID: "9", catalogID: nil)
            if case .played = try f.playIfCurrent(token, play: { played.append("Aja"); return 1 }) {
                line = SourceRateStartLine.line(for: outcome)
            }
        }
        XCTAssertEqual(played, ["Aja"])
        XCTAssertEqual(line, .regressed)
    }

    /// A newer command moved the fence while SpanDAC was settling this one: it
    /// answers `settled`, and the song still plays NOTHING, because M3's
    /// revalidation fails on the file, whatever the rate answer was.
    func testASettledAnswerForAnInvalidatedTokenPlaysNothing() throws {
        let dir = OutputLockTestSupport.tempDir()
        let older = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let newer = RateFence(lock: OutputLock(path: dir + "/output.lock", pollInterval: 0.001))
        let wire = Wire(Clock())
        wire.script = { body in
            _ = try? newer.begin(.next, owner: "tui")           // a newer command lands during the exchange
            return self.answer(body["fence"] as? Int ?? 0, "settled", seq: 1)
        }
        var played = 0
        try older.run(.play, owner: "runner") { token in
            let outcome = follow(token, wire).prepare(dacUID: nil, persistentID: "9", catalogID: nil)
            guard case .answered(let a) = outcome, a.outcome == .settled else { return XCTFail("\(outcome)") }
            XCTAssertEqual(try older.playIfCurrent(token) { played += 1; return 1 }, .invalidated)
        }
        XCTAssertEqual(played, 0)
        XCTAssertEqual(try older.current(), 2)
    }
}
