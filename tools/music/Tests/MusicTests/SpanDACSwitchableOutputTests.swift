// tools/music/Tests/MusicTests/SpanDACSwitchableOutputTests.swift
//
// A chosen DAC that is plugged in but is not the Mac's sound output is
// reported as `"dac":"not_connected"` plus `"switchable":true` (with `name`
// and `max_rate_hz`). Picking SpanDAC then makes it the Mac's output in the
// same keypress: Enter commits the selection (after the outgoing player is
// paused), then sends `slice.useDAC`, and that row is selectable. No `switchable` (or false, or
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

    // MARK: slice.useDAC on the wire

    func testUseDACSendsOnlyTheOpAndDecodesTheFreshStatus() throws {
        var sent: [[String: Any]] = []
        let fresh = status(#"{"dac":"connected","name":"SSL 2+","max_rate_hz":192000}"#)
            .replacingOccurrences(of: #"{"ok":true,"status""#, with: #"{"ok":true,"op":"slice.useDAC","status""#)
        let c = SourceAppControl(path: "/nonexistent", transport: { _, line in
            sent.append(try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
            return fresh
        })
        let after = try XCTUnwrap(try c.useDAC())
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["op"] as? String, "slice.useDAC")
        XCTAssertEqual(Set(sent.first?.keys.map { $0 } ?? []), ["op"], "no uid, no other field")
        XCTAssertEqual(after.output, SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192_000))
        XCTAssertEqual(after.readiness, .ready)
    }

    func testUseDACRefusalsCarryTheirOwnDetail() {
        for kind in ["output_unconfirmed", "bad_request"] {
            let reply = #"{"ok":false,"op":"slice.useDAC","error":{"kind":"\#(kind)","detail":"SpanDAC couldn't confirm the Mac switched to SSL 2+."}}"#
            let c = SourceAppControl(path: "/nonexistent", transport: { _, _ in reply })
            XCTAssertThrowsError(try c.useDAC(), kind) {
                XCTAssertEqual($0 as? SourceAppError, .refused("SpanDAC couldn't confirm the Mac switched to SSL 2+."), kind)
            }
        }
    }

    func testTheCapabilityIsTheAdvertisedWord() throws {
        let with = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"capabilities":["output.use_dac"]}}"#
        XCTAssertTrue(try SourceAppControl(path: "/x", transport: { _, _ in with }).status().offersUseDAC)
        XCTAssertFalse(try control(switchableOutput).status().offersUseDAC)
    }

    // MARK: the Output tab, Enter

    private let ipad = "A1B2C3D4-0000-4000-8000-00000000A002"
    private let connectedOutput = #"{"dac":"connected","name":"SSL 2+","max_rate_hz":192000}"#

    /// A Mac SpanDAC and an iPad SpanDAC behind fake transports, one shared
    /// log of every op that reaches either, in order.
    private final class Wire {
        private let lock = NSLock()
        private var _log: [String] = []
        var macStatus: String
        var useDAC: String
        init(macStatus: String, useDAC: String) { self.macStatus = macStatus; self.useDAC = useDAC }
        var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
        func count(_ entry: String) -> Int { log.filter { $0 == entry }.count }
        private func op(_ line: String) -> String {
            ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["op"] as? String ?? "?"
        }
        func mac(_ line: String) -> String {
            let op = op(line)
            lock.lock(); _log.append("mac:" + op)
            let status = macStatus, useDAC = useDAC
            lock.unlock()
            switch op {
            case "slice.status": return status
            case "slice.useDAC": return useDAC
            default: return #"{"ok":true}"#
            }
        }
        func ipad(_ line: String) -> String {
            let op = op(line)
            lock.lock(); _log.append("ipad:" + op); lock.unlock()
            return op == "slice.status"
                ? #"{"ok":true,"status":{"playback":"paused","authorization":"authorized","contract":\#(sourceContractVersion),"capabilities":[]}}"#
                : #"{"ok":true}"#
        }
    }

    private func macStatus(_ output: String, capabilities: [String] = ["output.use_dac"]) -> String {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"capabilities":[\#(caps)],"output":\#(output)}}"#
    }
    private func useDACRefusal(_ kind: String, detail: String?) -> String {
        let d = detail.map { #","detail":"\#($0)""# } ?? ""
        return #"{"ok":false,"op":"slice.useDAC","error":{"kind":"\#(kind)"\#(d)}}"#
    }

    private struct Rig {
        let dir: String
        let wire: Wire
        let scene: SpeakersScene
    }

    private func rig(mode: PlaybackMode, wire: Wire) throws -> Rig {
        let dir = NSTemporaryDirectory() + "switchable-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The outgoing side is always a fake: a start from MusicTUI's own
        // output would pause whatever really plays on this Mac.
        let ipadID = ipad
        let s = makeOutputTabScene(dir: dir, mode: mode, spandac: FakeSpanDACOutputs(),
                                   macLine: { wire.mac($0) },
                                   network: { id in
                                       XCTAssertEqual(id, ipadID)
                                       return SourceAppClient(path: "/fake-ipad", transport: { _, line in wire.ipad(line) })
                                   })
        settleOutputTab(s, speakers: 0)
        return Rig(dir: dir, wire: wire, scene: s)
    }

    private func modeOnDisk(_ r: Rig) -> PlaybackMode { PlaybackModeStore(path: r.dir + "/mode.json").mode() }

    private func row1(_ s: SpeakersScene) -> String {
        let text = screenText(s.render(frame: shellLayout(width: 110, height: 30), snapshot: outputTabSnapshot()),
                              width: 110, height: 30)
        return text.first { $0.contains("1  ") && $0.contains("Studio Mac") } ?? "<no row>\n" + text.joined(separator: "\n")
    }

    /// Ticks until the Mac row's text satisfies `condition`.
    private func untilRow(_ s: SpeakersScene, _ condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            _ = s.tick(snapshot: outputTabSnapshot())
            if condition(row1(s)) { return true }
            usleep(10_000)
        }
        return condition(row1(s))
    }

    @discardableResult
    private func pressEnterOnMacRow(_ s: SpeakersScene) -> Bool {
        let done = DispatchSemaphore(value: 0)
        s.selectModeFinishedForTest = { done.signal() }
        _ = s.handle(.home)
        guard let i = s.displayRowsForTest.firstIndex(of: .spandacMac) else { XCTFail("no Mac row"); return false }
        for _ in 0..<i { _ = s.handle(.down) }
        _ = s.handle(.enter)
        return done.wait(timeout: .now() + 2) == .success
    }

    func testTheSwitchableRowSaysWhatEnterWillDo() throws {
        let r = try rig(mode: .networkSource(ipad), wire: Wire(macStatus: macStatus(switchableOutput), useDAC: "{}"))
        defer { try? FileManager.default.removeItem(atPath: r.dir) }
        XCTAssertTrue(row1(r.scene).contains("SSL 2+ \u{00B7} 192 kHz  select to make it the Mac's output"), row1(r.scene))
        XCTAssertFalse(row1(r.scene).contains("plug in your DAC"), row1(r.scene))
        XCTAssertEqual(r.wire.count("mac:slice.useDAC"), 0, "looking at the row sends nothing")
    }

    /// Enter commits the selection, THEN asks SpanDAC to switch the Mac:
    /// the outgoing iPad is paused and cleared first, so playing audio is
    /// never redirected to the DAC.
    func testEnterSendsUseDACOnlyAfterTheOutgoingPlayerIsPausedAndCleared() throws {
        let wire = Wire(macStatus: macStatus(switchableOutput), useDAC: "{}")
        let r = try rig(mode: .networkSource(ipad), wire: wire)
        defer { try? FileManager.default.removeItem(atPath: r.dir) }
        let before = wire.log.count
        wire.useDAC = macStatus(connectedOutput).replacingOccurrences(of: #"{"ok":true,"status""#,
                                                                       with: #"{"ok":true,"op":"slice.useDAC","status""#)
        XCTAssertTrue(pressEnterOnMacRow(r.scene))
        let log = Array(wire.log.dropFirst(before))
        let use = try XCTUnwrap(log.firstIndex(of: "mac:slice.useDAC"), "\(log)")
        XCTAssertEqual(log.filter { $0 == "mac:slice.useDAC" }.count, 1, "\(log)")
        XCTAssertEqual(log.firstIndex(of: "ipad:slice.pause").map { $0 < use }, true, "paused first: \(log)")
        XCTAssertEqual(log.firstIndex(of: "ipad:slice.stop").map { $0 < use }, true, "cleared first: \(log)")
        XCTAssertEqual(modeOnDisk(r), .source, "the selection is committed")
        // Success: the row refreshes and reads connected.
        XCTAssertTrue(untilRow(r.scene) { $0.contains("ready  SSL 2+ \u{00B7} 192 kHz") }, row1(r.scene))
    }

    func testARefusedSwitchKeepsSpanDACSelectedAndTheRowSaysWhy() throws {
        let detail = "SpanDAC couldn't confirm the Mac switched to SSL 2+."
        let wire = Wire(macStatus: macStatus(switchableOutput),
                        useDAC: useDACRefusal("output_unconfirmed", detail: detail))
        let r = try rig(mode: .networkSource(ipad), wire: wire)
        defer { try? FileManager.default.removeItem(atPath: r.dir) }
        XCTAssertTrue(pressEnterOnMacRow(r.scene))
        XCTAssertEqual(wire.count("mac:slice.useDAC"), 1)
        XCTAssertEqual(modeOnDisk(r), .source, "SpanDAC stays selected")
        XCTAssertTrue(untilRow(r.scene) { $0.contains(detail) }, row1(r.scene))
        XCTAssertFalse(row1(r.scene).contains("select to make it"), row1(r.scene))
    }

    func testARefusalWithoutADetailSaysItIsNotTheMacsSoundOutput() throws {
        let wire = Wire(macStatus: macStatus(switchableOutput), useDAC: useDACRefusal("bad_request", detail: nil))
        let r = try rig(mode: .networkSource(ipad), wire: wire)
        defer { try? FileManager.default.removeItem(atPath: r.dir) }
        XCTAssertTrue(pressEnterOnMacRow(r.scene))
        XCTAssertEqual(modeOnDisk(r), .source)
        XCTAssertTrue(untilRow(r.scene) { $0.contains("not the Mac's sound output") }, row1(r.scene))
    }

    /// Enter on the SpanDAC row that is already the output tries again.
    func testEnterOnTheAlreadySelectedRowSendsUseDACToo() throws {
        let wire = Wire(macStatus: macStatus(switchableOutput), useDAC: useDACRefusal("output_unconfirmed", detail: "no"))
        let r = try rig(mode: .source, wire: wire)
        defer { try? FileManager.default.removeItem(atPath: r.dir) }
        let before = wire.log.count
        XCTAssertTrue(pressEnterOnMacRow(r.scene))
        let log = Array(wire.log.dropFirst(before))
        XCTAssertEqual(log.filter { $0 == "mac:slice.useDAC" }.count, 1, "\(log)")
        XCTAssertEqual(log.filter { $0.hasPrefix("ipad:") }, [], "nothing is paused or cleared when nothing changes")
        XCTAssertEqual(modeOnDisk(r), .source)
    }

    /// An older SpanDAC does not list the capability: today's behaviour, the
    /// switch happens at the first play.
    func testAnOlderSpanDACWithoutTheCapabilityIsNeverSentUseDAC() throws {
        let wire = Wire(macStatus: macStatus(switchableOutput, capabilities: []), useDAC: "{}")
        let r = try rig(mode: .networkSource(ipad), wire: wire)
        defer { try? FileManager.default.removeItem(atPath: r.dir) }
        XCTAssertTrue(pressEnterOnMacRow(r.scene))
        XCTAssertEqual(wire.count("mac:slice.useDAC"), 0)
        XCTAssertEqual(modeOnDisk(r), .source, "still selectable, switched at the first play")
        XCTAssertTrue(row1(r.scene).contains("select to make it the Mac's output"), row1(r.scene))
        // Selected again: still nothing.
        XCTAssertTrue(pressEnterOnMacRow(r.scene))
        XCTAssertEqual(wire.count("mac:slice.useDAC"), 0)
    }

    /// Only a switchable DAC is asked: a DAC that already is the output needs
    /// no switch, and no DAC cannot be selected at all.
    func testUseDACIsNotSentForAConnectedDACOrForNoDAC() throws {
        let connected = Wire(macStatus: macStatus(connectedOutput), useDAC: "{}")
        let a = try rig(mode: .networkSource(ipad), wire: connected)
        defer { try? FileManager.default.removeItem(atPath: a.dir) }
        XCTAssertTrue(pressEnterOnMacRow(a.scene))
        XCTAssertEqual(modeOnDisk(a), .source)
        XCTAssertEqual(connected.count("mac:slice.useDAC"), 0)

        let none = Wire(macStatus: macStatus(#"{"dac":"not_connected"}"#), useDAC: "{}")
        let b = try rig(mode: .networkSource(ipad), wire: none)
        defer { try? FileManager.default.removeItem(atPath: b.dir) }
        XCTAssertTrue(row1(b.scene).contains("plug in your DAC  no DAC on this Mac"), row1(b.scene))
        XCTAssertFalse(pressEnterOnMacRow(b.scene), "no selection started")
        XCTAssertEqual(modeOnDisk(b), .networkSource(ipad))
        XCTAssertEqual(none.count("mac:slice.useDAC"), 0)
        XCTAssertEqual(none.log.filter { $0.hasPrefix("ipad:") }, [], "the outgoing player was left alone")
    }

    // MARK: the routing switch alone does not send it

    /// `switchMode` is the commit: readiness read, nothing else. `slice.useDAC`
    /// belongs to the Output action after it.
    func testTheRoutingSwitchItselfSendsOnlyAStatusRead() throws {
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
}
