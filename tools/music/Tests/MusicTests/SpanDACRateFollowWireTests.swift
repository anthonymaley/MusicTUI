// tools/music/Tests/MusicTests/SpanDACRateFollowWireTests.swift
import XCTest
@testable import music

/// Rate follow on the wire, client side: the request bytes of the four ops, the
/// fail-closed `rate` answer decoder, the status's `rate` object, and an older
/// SpanDAC that has none of it. A fixture transport only: no socket, no player.
final class SpanDACRateFollowWireTests: XCTestCase {

    private final class Wire { var lines: [String] = [] }

    private func control(_ wire: Wire, reply: @escaping () -> String) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent",
                         transport: { _, line in wire.lines.append(line); return reply() },
                         libraryTransport: { _, line in wire.lines.append(line); return reply() })
    }

    private func sent(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testTheNamesAreTheFixedContract() {
        XCTAssertEqual(sourceRateFollowCapability, "output.rate_follow")
        XCTAssertEqual([sourceRateFenceOp, sourcePrepareRateOp, sourceRateSettleOp, sourceConfirmRateOp],
                       ["slice.rateFence", "slice.prepareRate", "slice.rateSettle", "slice.confirmRate"])
    }

    // MARK: Requests

    func testRequestBodiesCarryOnlyTheirFields() throws {
        XCTAssertEqual(Set(SourceAppControl.rateFenceBody(fence: 41).keys), ["op", "fence"])
        let prepare = SourceAppControl.prepareRateBody(fence: 41, dacUID: "ssl", persistentID: "-596357614188841472",
                                                       catalogID: nil)
        XCTAssertEqual(Set(prepare.keys), ["op", "fence", "step", "dac_uid", "persistent_id"])
        XCTAssertEqual(prepare["step"] as? Int, 0)
        let correct = SourceAppControl.prepareRateBody(fence: 41, step: SourceRateStep.correct, dacUID: "ssl",
                                                       persistentID: nil, catalogID: nil, rateHz: 96000)
        XCTAssertEqual(correct["step"] as? Int, 2)
        XCTAssertEqual(correct["rate_hz"] as? Int, 96000)
        XCTAssertEqual(Set(SourceAppControl.rateSettleBody(fence: 41, step: nil).keys), ["op", "fence"])
        let confirm = SourceAppControl.confirmRateBody(fence: 41, persistentID: "1", deliveredHz: 44100)
        XCTAssertEqual(confirm["step"] as? Int, 1)
        XCTAssertEqual(confirm["delivered_hz"] as? Int, 44100)
    }

    func testARateRequestSendsOneLineAndDecodesTheAnswer() throws {
        let wire = Wire()
        let answer = try control(wire, reply: {
            #"{"ok":true,"op":"slice.prepareRate","rate":{"fence":41,"step":0,"outcome":"settled","target_hz":96000,"dac_rate_hz":96000,"rate_seq":3}}"#
        }).rateRequest(SourceAppControl.prepareRateBody(fence: 41, dacUID: "ssl", persistentID: "1", catalogID: nil))
        XCTAssertEqual(wire.lines.count, 1)
        XCTAssertEqual(try sent(wire.lines[0])["op"] as? String, "slice.prepareRate")
        XCTAssertEqual(answer, SourceRateAnswer(fence: 41, step: 0, outcome: .settled, targetHz: 96000, dacRateHz: 96000,
                                                rateSeq: 3))
        XCTAssertFalse(answer.priorUnresolved)
    }

    // MARK: Answers, fail closed

    func testEveryOutcomeDecodes() throws {
        let words: [(String, SourceRateAnswer.Outcome)] = [
            ("quiet", .quiet), ("in_flight", .inFlight), ("unresolved", .unresolved), ("queued", .queued),
            ("settled", .settled), ("same_rate", .sameRate), ("dac_limit", .dacLimit),
            ("unknown_rate", .unknownRate), ("no_dac", .noDAC), ("own_rate", .ownRate), ("correct", .correct),
            ("converted", .converted), ("delivered_unknown", .deliveredUnknown), ("superseded", .superseded),
            ("unknown_fence", .unknownFence),
        ]
        for (word, outcome) in words {
            let reply = try object(#"{"ok":true,"rate":{"fence":7,"outcome":"\#(word)"}}"#)
            XCTAssertEqual(try SourceAppControl.rateAnswer(from: reply, op: "x", fence: 7).outcome, outcome, word)
        }
        XCTAssertFalse(SourceRateAnswer.Outcome.inFlight.isTerminal)
        XCTAssertFalse(SourceRateAnswer.Outcome.queued.isTerminal)
        XCTAssertTrue(SourceRateAnswer.Outcome.unresolved.isTerminal)
    }

    func testAnUnknownOutcomeIsKeptAsUnrecognisedNeverASuccess() throws {
        let reply = try object(#"{"ok":true,"rate":{"fence":7,"outcome":"teleported","prior_unresolved":true}}"#)
        let answer = try SourceAppControl.rateAnswer(from: reply, op: "x", fence: 7)
        XCTAssertEqual(answer.outcome, .unrecognised("teleported"))
        XCTAssertTrue(answer.priorUnresolved)
    }

    func testAMalformedOrForeignAnswerIsRefused() throws {
        for json in [#"{"ok":true}"#,
                     #"{"ok":true,"rate":{"outcome":"settled"}}"#,
                     #"{"ok":true,"rate":{"fence":"7","outcome":"settled"}}"#,
                     #"{"ok":true,"rate":{"fence":7}}"#,
                     #"{"ok":true,"rate":{"fence":7,"outcome":"settled","target_hz":"96000"}}"#] {
            XCTAssertThrowsError(try SourceAppControl.rateAnswer(from: try object(json), op: "x", fence: 7), json) {
                guard case SourceAppError.malformedReply = $0 else { return XCTFail("\(json): \($0)") }
            }
        }
        let other = try object(#"{"ok":true,"rate":{"fence":8,"outcome":"settled"}}"#)
        XCTAssertThrowsError(try SourceAppControl.rateAnswer(from: other, op: "x", fence: 7),
                             "an answer for another fence is never ours")
    }

    // MARK: Status

    func testTheStatusRateObjectDecodes() throws {
        let status = try object(#"{"playback":"playing","capabilities":["slice.status","output.rate_follow"],"rate":{"fence":41,"dac_rate_hz":96000,"write":"unresolved","started_fence":40,"rate_seq":7,"moved":{"fence":40,"to_hz":96000,"cause":"late_switch","seq":6}}}"#)
        let decoded = SourceAppControl.decodeStatus(status, readingWith: SourceAppControl(path: "/nonexistent"))
        XCTAssertEqual(decoded?.offersRateFollow, true)
        XCTAssertEqual(decoded?.rateFollow, SourceRateFollowStatus(
            fence: 41, dacRateHz: 96000, write: .unresolved, startedFence: 40, rateSeq: 7,
            moved: .init(fence: 40, toHz: 96000, cause: .lateSwitch, seq: 6)))
    }

    func testAnUnreadableStatusRateObjectIsAbsentNotGuessed() throws {
        let status = try object(#"{"playback":"playing","rate":{"fence":41,"write":"sideways"}}"#)
        XCTAssertNil(SourceAppControl.decodeStatus(status, readingWith: SourceAppControl(path: "/nonexistent"))?.rateFollow)
    }

    // MARK: An older SpanDAC

    /// No capability, no `rate` object, and `unknown_op` for every rate op:
    /// the client reads "not offered", sends nothing more, and has its sentence.
    func testAnOlderSpanDACHasNoRateFollow() throws {
        let status = try object(#"{"playback":"paused","contract":3,"capabilities":["slice.status","output.use_dac","queue.jump"]}"#)
        let decoded = try XCTUnwrap(SourceAppControl.decodeStatus(status, readingWith: SourceAppControl(path: "/nonexistent")))
        XCTAssertFalse(decoded.offersRateFollow)
        XCTAssertNil(decoded.rateFollow)

        let wire = Wire()
        let old = control(wire, reply: {
            #"{"ok":false,"op":"slice.rateFence","error":{"kind":"unknown_op","detail":"unknown op slice.rateFence"}}"#
        })
        XCTAssertThrowsError(try old.rateRequest(SourceAppControl.rateFenceBody(fence: 1))) {
            XCTAssertEqual($0 as? SourceAppError, .unsupported("slice.rateFence"))
        }
        XCTAssertTrue(sourceRateFollowUpdateSentence.contains("Update SpanDAC"))
    }
}
