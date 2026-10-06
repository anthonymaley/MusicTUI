// tools/music/Tests/MusicTests/SpanDACSwitchableOutputTests.swift
//
// A chosen DAC that is plugged in but is not the Mac's sound output is
// reported as `"dac":"not_connected"` plus `"switchable":true` (with `name`
// and `max_rate_hz`). Picking SpanDAC then makes it the Mac's output in the
// same keypress, so that row is selectable. No `switchable` (or false, or
// anything else) is genuinely no DAC: unchanged, not ready, "plug in your
// DAC". Music data never depended on the DAC either way.
//
// No socket, no playback, no keychain: fake transports and temp state only.
import XCTest
@testable import music

final class SpanDACSwitchableOutputTests: XCTestCase {

    private func status(_ output: String) -> String {
        #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"capabilities":[],"output":\#(output)}}"#
    }
    private let switchableOutput = #"{"dac":"not_connected","switchable":true,"name":"SSL 2+","max_rate_hz":192000}"#
    private func control(_ output: String) -> SourceAppControl {
        let reply = status(output)
        return SourceAppControl(path: "/nonexistent", transport: { _, _ in reply })
    }
    private func dict(_ output: String) -> [String: Any] {
        let reply = try! JSONSerialization.jsonObject(with: Data(status(output).utf8)) as! [String: Any]
        return reply["status"] as! [String: Any]
    }
    private let noDACReason = SourceReadiness.unavailable("plug in your DAC")

    // MARK: decode

    func testSwitchableIsDecodedWithNameAndRate() throws {
        let s = try control(switchableOutput).status()
        XCTAssertEqual(s.output, SourceOutputInfo(dac: .notConnected, name: "SSL 2+", maxRateHz: 192_000,
                                                  switchable: true))
        XCTAssertEqual(s.output?.switchable, true)
    }

    func testAbsentFalseOrGarbageSwitchableIsGenuinelyNoDAC() throws {
        for output in [#"{"dac":"not_connected"}"#,
                       #"{"dac":"not_connected","switchable":false,"name":"SSL 2+","max_rate_hz":192000}"#,
                       #"{"dac":"not_connected","switchable":"true","name":"SSL 2+"}"#,
                       #"{"dac":"not_connected","switchable":1,"name":"SSL 2+"}"#,
                       #"{"dac":"not_connected","switchable":null}"#,
                       #"{"dac":"not_connected","switchable":[true]}"#,
                       #"{"dac":"not_connected","switchable":{"x":1},"name":"SSL 2+"}"#] {
            let s = try control(output).status()
            XCTAssertEqual(s.output, SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil), output)
            XCTAssertEqual(s.output?.switchable, false, output)
            XCTAssertEqual(s.readiness, noDACReason, output)
        }
    }

    /// `switchable` beside a DAC state that is not `not_connected` changes nothing.
    func testSwitchableMeansNothingBesideOtherDACStates() throws {
        let connected = try control(#"{"dac":"connected","name":"SSL 2+","max_rate_hz":192000,"switchable":true}"#).status()
        XCTAssertEqual(connected.output, SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192_000))
        let unknown = try control(#"{"dac":"unknown","switchable":true}"#).status()
        XCTAssertEqual(unknown.output, SourceOutputInfo(dac: .unknown, name: nil, maxRateHz: nil))
        XCTAssertEqual(unknown.readiness, .unavailable("SpanDAC is still checking for a DAC"))
    }

    // MARK: readiness (shared by the Output tab, the routing switch and the CLI)

    func testASwitchableDACIsSelectableAndNoDACStillIsNot() throws {
        XCTAssertEqual(control(switchableOutput).readiness(from: dict(switchableOutput)), .ready)
        XCTAssertEqual(try control(switchableOutput).status().readiness, .ready)
        XCTAssertEqual(control(switchableOutput).readiness(from: dict(#"{"dac":"not_connected"}"#)), noDACReason)
        // The client's own readiness, the routing switch's and the CLI's gate.
        let reply = status(switchableOutput), none = status(#"{"dac":"not_connected"}"#)
        XCTAssertEqual(SourceAppClient(path: "/nonexistent", transport: { _, _ in reply }).readiness(), .ready)
        XCTAssertEqual(SourceAppClient(path: "/nonexistent", transport: { _, _ in none }).readiness(), noDACReason)
    }

    /// Everything that was refused before is still refused: access, contract
    /// and a disconnected player come before the DAC.
    func testSwitchableDoesNotOverrideAnyOtherRefusal() throws {
        let denied = #"{"ok":true,"status":{"playback":"idle","authorization":"denied","contract":\#(sourceContractVersion),"output":\#(switchableOutput)}}"#
        XCTAssertEqual(try SourceAppControl(path: "/x", transport: { _, _ in denied }).status().readiness,
                       .unavailable("SpanDAC was denied Apple Music access"))
        let old = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":2,"output":\#(switchableOutput)}}"#
        XCTAssertEqual(try SourceAppControl(path: "/x", transport: { _, _ in old }).status().readiness,
                       .unavailable(sourceContractMismatchReason(2)))
        let down = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"output":\#(switchableOutput),"player":"disconnected"}}"#
        let s = try SourceAppControl(path: "/x", transport: { _, _ in down }).status()
        XCTAssertEqual(s.readiness, .unavailable(SourceAppError.playerDisconnectedSentence))
        XCTAssertEqual(s.dataReadiness, .ready, "the player never gates data")
    }

    /// The DAC never gates data: ready for music data in every DAC state.
    func testMusicDataIsReadyWhateverTheDAC() throws {
        for output in [switchableOutput, #"{"dac":"not_connected"}"#, #"{"dac":"unknown"}"#,
                       #"{"dac":"connected","name":"X"}"#] {
            XCTAssertEqual(try control(output).status().dataReadiness, .ready, output)
        }
        let reply = status(switchableOutput)
        XCTAssertEqual(liveMacSpanDACProbe(client: SourceAppClient(path: "/nonexistent", transport: { _, _ in reply })),
                       .ready)
    }

    // MARK: row model and words

    private let switchable = SourceOutputInfo(dac: .notConnected, name: "SSL 2+", maxRateHz: 192_000, switchable: true)
    private let none = SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil)

    func testTheMacRowIsSelectableOnlyWhenTheDACIsSwitchable() {
        XCTAssertEqual(macSpanDACRowState(readiness: .ready, output: switchable), .ready)
        XCTAssertEqual(macSpanDACRowState(readiness: .ready, output: none), .notReady("plug in your DAC"))
        XCTAssertEqual(macSpanDACRowState(readiness: noDACReason, output: none), .notReady("plug in your DAC"))
        // Switchable never rescues a row that is not ready for another reason.
        XCTAssertEqual(macSpanDACRowState(readiness: .unavailable("SpanDAC was denied Apple Music access"), output: switchable),
                       .notReady("SpanDAC was denied Apple Music access"))
        XCTAssertEqual(macSpanDACRowState(readiness: .notRunning, output: switchable), .unreachable("SpanDAC is not running"))
    }

    func testTheRowSaysWhatSelectingWillDo() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        func text(_ state: SpanDACRowState, _ output: SourceOutputInfo?, mac: Bool = true) -> String {
            spandacRowDetail(state: state, output: output, device: "Studio Mac", isThisMac: mac, now: now).text
        }
        XCTAssertEqual(text(.ready, switchable), "SSL 2+ \u{00B7} 192 kHz  select to make it the Mac's output")
        XCTAssertEqual(text(.ready, SourceOutputInfo(dac: .notConnected, name: "SSL 2+", maxRateHz: nil, switchable: true)),
                       "SSL 2+  select to make it the Mac's output")
        XCTAssertEqual(text(.ready, SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil, switchable: true)),
                       "your DAC  select to make it the Mac's output")
        XCTAssertEqual(spandacRowDetail(state: .ready, output: switchable, device: "Studio Mac", isThisMac: true, now: now).tone,
                       .neutral)
        // The genuinely-no-DAC words are unchanged.
        XCTAssertEqual(text(.notReady("plug in your DAC"), none), "plug in your DAC  no DAC on this Mac")
        // A ready row whose DAC is the output is unchanged.
        XCTAssertEqual(text(.ready, SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192_000)),
                       "ready  SSL 2+ \u{00B7} 192 kHz")
    }

    // MARK: routing switch, and what is sent

    /// Choosing the output reads `slice.status` and nothing else from
    /// SpanDAC: no queue, no play, no output-choosing op. The Mac switch
    /// itself is SpanDAC's, at choose/play start.
    func testSelectingASwitchableMacOutputSwitchesAndSendsOnlyAStatusRead() throws {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        rig.replies["slice.status"] = status(switchableOutput)
        let routing = rig.coordinator()
        let incoming = rig.makeOutput(.source)
        let result = try routing.switchMode(to: .source, readiness: { incoming.readiness() },
                                            pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(result, .switched(to: .source))
        XCTAssertEqual(routing.mode, .source)
        XCTAssertEqual(rig.sent.map(\.op), ["slice.status"])
    }

    func testSelectingAMacOutputWithNoDACStillRefuses() throws {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        rig.replies["slice.status"] = status(#"{"dac":"not_connected"}"#)
        let routing = rig.coordinator()
        let incoming = rig.makeOutput(.source)
        XCTAssertThrowsError(try routing.switchMode(to: .source, readiness: { incoming.readiness() },
                                                    pauseOutgoing: { _ in true }, dropQueue: { _ in })) { error in
            XCTAssertTrue((error as? ActionError)?.message.contains("plug in your DAC") ?? false, "\(error)")
        }
        XCTAssertEqual(routing.mode, .musicApp)
        XCTAssertEqual(rig.sent.map(\.op), ["slice.status"], "nothing but the readiness read")
    }

    // MARK: the Output tab, Enter

    private func scene(dir: String, reply: String) -> SpeakersScene {
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: FakeSpanDACOutputs(), macReply: { reply })
        settleOutputTab(s, speakers: 0)
        return s
    }

    private func row1(_ s: SpeakersScene) -> String {
        let text = screenText(s.render(frame: shellLayout(width: 100, height: 30), snapshot: outputTabSnapshot()),
                              width: 100, height: 30)
        return text.first { $0.contains("1  ") && $0.contains("Studio Mac") } ?? "<no row>\n" + text.joined(separator: "\n")
    }

    private func pressEnterOnMacRow(_ s: SpeakersScene) -> Bool {
        let done = DispatchSemaphore(value: 0)
        s.selectModeFinishedForTest = { done.signal() }
        _ = s.handle(.home)
        guard let i = s.displayRowsForTest.firstIndex(of: .spandacMac) else { XCTFail("no Mac row"); return false }
        for _ in 0..<i { _ = s.handle(.down) }
        _ = s.handle(.enter)
        return done.wait(timeout: .now() + 1) == .success
    }

    func testEnterOnASwitchableMacRowSelectsSpanDACAsTheOutput() throws {
        let dir = NSTemporaryDirectory() + "switchable-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = scene(dir: dir, reply: status(switchableOutput))
        XCTAssertTrue(row1(s).contains("SSL 2+ \u{00B7} 192 kHz  select to make it the Mac's output"), row1(s))
        XCTAssertFalse(row1(s).contains("plug in your DAC"), row1(s))
        XCTAssertTrue(pressEnterOnMacRow(s), "Enter started a selection")
        XCTAssertEqual(PlaybackModeStore(path: dir + "/mode.json").mode(), .source)
    }

    func testEnterOnAMacRowWithNoDACDoesNothing() throws {
        let dir = NSTemporaryDirectory() + "nodac-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = scene(dir: dir, reply: status(#"{"dac":"not_connected"}"#))
        XCTAssertTrue(row1(s).contains("plug in your DAC  no DAC on this Mac"), row1(s))
        XCTAssertFalse(pressEnterOnMacRow(s), "no selection started")
        XCTAssertEqual(PlaybackModeStore(path: dir + "/mode.json").mode(), .musicApp)
    }
}
