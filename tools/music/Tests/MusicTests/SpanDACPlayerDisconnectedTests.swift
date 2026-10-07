// tools/music/Tests/MusicTests/SpanDACPlayerDisconnectedTests.swift
//
// SpanDAC can lose its connection to Apple Music's player; only relaunching
// SpanDAC fixes it. It says so two ways (wire contract, fixed):
//   - a play/queue refusal `{"ok":false,"error":{"kind":"player_disconnected","detail":...}}`
//   - an optional `"player":"disconnected"` on `slice.status` (absent = fine).
//
// What is pinned here: the kind is decoded as its OWN case (on the kind, never
// the prose), the sentence reaches every place a SpanDAC play failure already
// appears, nothing is retried, nothing falls back to the MusicTUI path, and a
// SpanDAC that never sends either is read exactly as before. No socket, no
// SpanDAC, no playback: fake transports answer.
import XCTest
@testable import music

final class SpanDACPlayerDisconnectedTests: XCTestCase {

    private let sentence = "SpanDAC lost its connection to Apple Music's player. Relaunch SpanDAC to play again."

    private func disconnected(op: String, detail: String? = nil) -> String {
        let d = detail.map { #","detail":"\#($0)""# } ?? ""
        return #"{"ok":false,"op":"\#(op)","error":{"kind":"player_disconnected"\#(d)}}"#
    }

    /// A transport that answers one fixed reply and counts what was sent.
    private final class Wire {
        let reply: String
        private(set) var sent: [String] = []
        init(_ reply: String) { self.reply = reply }
        func transport(_: String, _ line: String) throws -> String { sent.append(line); return reply }
    }

    private func statusReply(player: String?) -> String {
        let tail = player.map { #","player":\#($0)"# } ?? ""
        return #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"capabilities":[]\#(tail)}}"#
    }

    private func status(player: String?) throws -> SourceStatus {
        try SourceAppControl(path: "/nonexistent", transport: { _, _ in self.statusReply(player: player) }).status()
    }

    // MARK: - The error kind

    func testPlayerDisconnectedIsItsOwnCaseCarryingTheDetail() {
        let wire = Wire(disconnected(op: "slice.queue", detail: sentence))
        let control = SourceAppControl(path: "/nonexistent", transport: wire.transport)
        XCTAssertThrowsError(try control.queue(catalogIDs: ["1"])) {
            XCTAssertEqual($0 as? SourceAppError, .playerDisconnected(self.sentence))
            XCTAssertEqual(($0 as? SourceAppError)?.message, self.sentence,
                           "the sentence, not \"SpanDAC refused: ...\"")
        }
    }

    func testEverySendingOpDecodesTheKindWithoutRetry() {
        let ops: [(String, (SourceAppControl) throws -> Void)] = [
            ("slice.queue", { _ = try $0.queue(catalogIDs: ["1"]) }),
            ("slice.queue", { _ = try $0.queue(libraryIDs: ["l1"], startRequired: true) }),
            ("slice.play", { try $0.resume() }),
        ]
        for (op, call) in ops {
            let wire = Wire(disconnected(op: op, detail: "x"))
            let control = SourceAppControl(path: "/nonexistent", transport: wire.transport)
            XCTAssertThrowsError(try call(control), op) {
                XCTAssertEqual($0 as? SourceAppError, .playerDisconnected("x"), op)
            }
            XCTAssertEqual(wire.sent.count, 1, "\(op): not retried")
        }
    }

    func testAMissingOrEmptyDetailFallsBackToTheSentence() {
        for raw in [disconnected(op: "slice.queue"), disconnected(op: "slice.queue", detail: "")] {
            let wire = Wire(raw)
            let control = SourceAppControl(path: "/nonexistent", transport: wire.transport)
            XCTAssertThrowsError(try control.queue(catalogIDs: ["1"]), raw) {
                XCTAssertEqual(($0 as? SourceAppError)?.message, self.sentence, raw)
            }
        }
    }

    func testSlicePlayClientDecodesTheKindToo() {
        let wire = Wire(disconnected(op: "slice.play", detail: sentence))
        let client = SourceAppPlayback(path: "/nonexistent", transport: wire.transport)
        XCTAssertThrowsError(try client.play(catalogID: "1")) {
            XCTAssertEqual(($0 as? SourceAppError)?.message, self.sentence)
            XCTAssertEqual($0 as? SourceAppError, .playerDisconnected(self.sentence))
        }
        XCTAssertEqual(wire.sent.count, 1)
    }

    func testTheSimpleFailureRuleKnowsTheKindAndKeepsTheOthers() {
        XCTAssertEqual(SourceAppError.fromSimpleFailureKind("player_disconnected", detail: nil),
                       .playerDisconnected(sentence))
        XCTAssertEqual(SourceAppError.fromSimpleFailureKind("busy", detail: nil), .busy)
        XCTAssertEqual(SourceAppError.fromSimpleFailureKind("unauthorized", detail: "d"), .notAuthorized)
        XCTAssertEqual(SourceAppError.fromSimpleFailureKind("nope", detail: "d"), .refused("d"))
        XCTAssertEqual(SourceAppError.fromSimpleFailureKind("nope", detail: nil), .refused("no detail"))
    }

    // MARK: - TUI: the provider seam

    func testTheProviderShowsTheSentenceAndSendsTheQueueOnce() {
        let wire = Wire(disconnected(op: "slice.queue", detail: sentence))
        let provider = BridgeMusicProvider(
            control: SourceAppControl(path: "/nonexistent", transport: wire.transport))
        XCTAssertThrowsError(try provider.play(ids: ["l1"])) {
            XCTAssertEqual($0 as? MusicProviderError, .unavailable(self.sentence))
            XCTAssertEqual(($0 as? MusicProviderError)?.errorDescription, self.sentence)
        }
        XCTAssertEqual(wire.sent.count, 1, "no retry, and nothing after the refusal (no status read, no fallback)")
        XCTAssertTrue(wire.sent[0].contains("slice.queue"))
    }

    // MARK: - CLI

    func testTheCLIPrintsTheSentenceSendsOnceAndNeverFallsBack() throws {
        for asJSON in [false, true] {
            let h = CLIBridgeCommandHarness(.source, [
                "slice.status": [CLIBridgeReplies.status()],
                "slice.librarySongs": [CLIBridgeLibraryReplies.songs([("s1", "Teardrop", "Massive Attack", "Mezzanine")])],
                "slice.queue": [disconnected(op: "slice.queue", detail: sentence)],
            ])
            var thrown: Error?
            let calls = try withTripwire {
                do {
                    try runPlay(args: [], playlist: nil, album: nil, song: "Teardrop", artist: nil, json: asJSON,
                                env: h.env,
                                musicAppDeps: PlayMusicAppDeps(
                                    readSongs: { XCTFail("fell back to the MusicTUI path"); return [] },
                                    resolveIndexed: { _, _ in XCTFail("fell back to the MusicTUI path") }))
                } catch { thrown = error }
            }.calls
            XCTAssertNotNil(thrown, "the play must fail (json: \(asJSON))")
            // A CLI failure prints on stdout through `cliFailureText`, the one
            // formatter every dispatched refusal uses; it is the only line.
            XCTAssertEqual(h.io.out, [cliFailureText(sentence, json: asJSON)], "json: \(asJSON)")
            XCTAssertEqual(h.io.err, [], "no progress or retry note")
            XCTAssertEqual(h.wire.sent("slice.queue").count, 1, "a mutation is never re-sent")
            XCTAssertEqual(h.io.sleeps, [], "no wait, no retry")
            XCTAssertEqual(calls, [], "no AppleScript or REST call: no fallback")
        }
    }

    // MARK: - slice.status "player"

    func testStatusPlayerDisconnectedIsDecodedAndNotReadyWithTheSentence() throws {
        let s = try status(player: #""disconnected""#)
        XCTAssertTrue(s.playerDisconnected)
        XCTAssertEqual(s.readiness, .unavailable(sentence))
    }

    func testAbsentOrUnknownPlayerIsFineAndReadsAsBefore() throws {
        for player in [nil, #""connected""#, #""ok""#, #""something_new""#, "null", "3", "true", "{}", #""""#] {
            let s = try status(player: player)
            XCTAssertFalse(s.playerDisconnected, "\(player ?? "absent")")
            XCTAssertEqual(s.readiness, .ready, "\(player ?? "absent")")
        }
    }

    /// Something more actionable still wins: no DAC, or no Apple Music access,
    /// is what the row says, and a mismatched contract never reads as the player.
    func testAnotherReasonOutranksThePlayerNotice() throws {
        let noDAC = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"output":{"dac":"not_connected"},"player":"disconnected"}}"#
        let s = try SourceAppControl(path: "/nonexistent", transport: { _, _ in noDAC }).status()
        XCTAssertTrue(s.playerDisconnected)
        XCTAssertEqual(s.readiness, .unavailable("plug in your DAC"))

        let denied = #"{"ok":true,"status":{"playback":"idle","authorization":"denied","contract":\#(sourceContractVersion),"player":"disconnected"}}"#
        let d = try SourceAppControl(path: "/nonexistent", transport: { _, _ in denied }).status()
        XCTAssertEqual(d.readiness, .unavailable("SpanDAC was denied Apple Music access"))
    }

    // MARK: - Output tab (the existing SpanDAC row)

    func testTheOutputRowShowsTheSameSentence() throws {
        let s = try status(player: #""disconnected""#)
        let state = macSpanDACRowState(readiness: s.readiness, output: s.output)
        XCTAssertEqual(state, .notReady(sentence))
        let detail = spandacRowDetail(state: state, output: s.output, device: "This Mac",
                                      isThisMac: true, now: Date())
        XCTAssertEqual(detail.text, sentence)
        XCTAssertEqual(detail.tone, .warning)
    }

    func testTheOutputRowIsUnchangedWhenThePlayerIsNotMentioned() throws {
        let s = try status(player: nil)
        XCTAssertEqual(macSpanDACRowState(readiness: s.readiness, output: s.output), .ready)
    }

    // MARK: - Data and sound stay independent (ruling 2026-09-28)
    //
    // A SpanDAC whose player is disconnected still serves music DATA. The Output
    // row says not ready (sound), and nothing about that may reach data.

    private func statusWith(player: String = #""disconnected""#, authorization: String = "authorized",
                            contract: Int = sourceContractVersion, output: String? = nil) throws -> SourceStatus {
        let out = output.map { #","output":\#($0)"# } ?? ""
        let reply = #"{"ok":true,"status":{"playback":"idle","authorization":"\#(authorization)","contract":\#(contract),"player":\#(player)\#(out)}}"#
        return try SourceAppControl(path: "/nonexistent", transport: { _, _ in reply }).status()
    }

    func testDataReadinessIgnoresADisconnectedPlayer() throws {
        let s = try statusWith()
        XCTAssertEqual(s.readiness, .unavailable(sentence), "the Output row still says not ready")
        XCTAssertEqual(s.dataReadiness, .ready, "data does not need the player")

        // With a DAC reading that data already exempts, too.
        for dac in [#"{"dac":"not_connected"}"#, #"{"dac":"unknown"}"#, #"{"dac":"connected","name":"X"}"#] {
            XCTAssertEqual(try statusWith(output: dac).dataReadiness, .ready, dac)
        }
    }

    func testDataReadinessStillFailsOnAccessAndContract() throws {
        for authorization in ["denied", "not_determined", "restricted", "bogus"] {
            let s = try statusWith(authorization: authorization)
            XCTAssertNotEqual(s.dataReadiness, .ready, authorization)
            XCTAssertEqual(s.dataReadiness, s.readiness, "\(authorization): its own reason, not the player's")
        }
        let mismatch = try statusWith(contract: sourceContractVersion + 1)
        XCTAssertNotEqual(mismatch.dataReadiness, .ready)
        if case .unavailable(let why) = mismatch.dataReadiness {
            XCTAssertTrue(isSourceContractMismatch(why), why)
        } else { XCTFail("a different contract is not ready for data") }
    }

    func testTheMacStartProbeReadsDataReadyWhileThePlayerIsDisconnected() {
        func client(authorization: String = "authorized", contract: Int = sourceContractVersion) -> SourceAppClient {
            let reply = #"{"ok":true,"status":{"playback":"idle","authorization":"\#(authorization)","contract":\#(contract),"player":"disconnected"}}"#
            return SourceAppClient(path: "/nonexistent/probe.sock", transport: { _, _ in reply })
        }
        XCTAssertEqual(liveMacSpanDACProbe(client: client()), .ready)
        XCTAssertEqual(liveMacSpanDACProbe(client: client(authorization: "denied")), .notAuthorized)
        XCTAssertEqual(liveMacSpanDACProbe(client: client(contract: sourceContractVersion + 1)),
                       .failed(macSpanDACNotCompatibleSentence))
    }

    func testTheCLIDataCheckAndTheMacRowAreReadyWhileThePlayerIsDisconnected() throws {
        let reply = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"player":"disconnected"}}"#
        let client = SourceAppClient(path: "/nonexistent/cli.sock", transport: { _, _ in reply })
        XCTAssertEqual(cliDataReadiness(client), .ready)
        XCTAssertEqual(client.readiness(), .unavailable(sentence), "playing is still refused")
        let s = try statusWith()
        XCTAssertEqual(macDataRowState(readiness: s.dataReadiness, installed: true, starting: false,
                                       startOutcome: nil), .ready)
    }
}
