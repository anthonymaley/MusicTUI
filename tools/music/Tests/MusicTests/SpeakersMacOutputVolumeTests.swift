// tools/music/Tests/MusicTests/SpeakersMacOutputVolumeTests.swift
//
// The Output tab's row for the Mac's own output (AirPlay device kind
// "computer") controls the macOS output volume, not Music's volume for that
// device. Reported 2026-11-01 on the laptop (macOS 27, Music playing to the
// built-in speakers): Music's own `sound volume` moved 52 -> 81 -> 50 and read
// back, and nothing audible changed; only the macOS output volume (the volume
// keys) changes what he hears. Decision (Anthony, 2026-11-01 17:43): that row
// sets and shows the macOS output volume. AirPlay speakers are unchanged.
//
// What stays as 3.24.4 left it: the selection is rechecked in the same script
// as the write, only the exact reply "set" is a done write, "off" means turn
// it on, an off row has no bar and no write, and the SpanDAC refusal speaks
// first.
//
// When the Mac's output has no software volume (`output volume` is missing
// value: some DACs, HDMI), the row shows Music's number and its arrows say so
// instead of writing.
//
// The AppleScript backend is a recording stand-in for osascript. Nothing here
// reaches the real osascript, Music, the system volume, a player, a socket,
// the keychain or ~/.config/music.
import XCTest
@testable import music

final class SpeakersMacOutputVolumeTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "speakers-mac-output-volume-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    // MARK: Rigs

    /// Appends each script (`$2`, after `-e`) to a file, prints `reply`, and
    /// exits with `exit`. Stands in for osascript's answer.
    private func recordingBackend(reply: String = "set", exit: Int = 0) throws -> (AppleScriptBackend, scripts: () -> [String]) {
        let fake = dir + "/osascript"
        let record = dir + "/scripts.txt"
        let say = reply.isEmpty ? "" : "printf '%s\\n' '\(reply)'\n"
        try "#!/bin/sh\nprintf '%s\\n--END--\\n' \"$2\" >> '\(record)'\n\(say)exit \(exit)\n"
            .write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        return (AppleScriptBackend(executable: fake), {
            ((try? String(contentsOfFile: record, encoding: .utf8)) ?? "")
                .components(separatedBy: "\n--END--\n").filter { !$0.isEmpty }
        })
    }

    private let mac = "Anthony's MacBook Pro"
    private let noVolume = "This Mac's output has no volume control; use the device's own."

    /// The Mac's own output as the list read reports it: Music's volume for
    /// the device, and the macOS output volume beside it (`outputVolume`, an
    /// Int, or "missing" when the output has no software volume).
    private func macRow(on: Bool = true, music: Int = 52, output: Any? = 40) -> [String: Any] {
        var d: [String: Any] = ["name": mac, "selected": on, "volume": music, "kind": "computer"]
        if let output { d["outputVolume"] = output }
        return d
    }

    private func speaker(_ name: String, on: Bool, volume: Int, kind: String = "AirPlay device") -> [String: Any] {
        ["name": name, "selected": on, "volume": volume, "kind": kind]
    }

    private func scene(mode: PlaybackMode = .musicApp, speakers: [[String: Any]], backend: AppleScriptBackend,
                       status: StatusStore, actions: ActionRunner) -> SpeakersScene {
        let s = makeOutputTabScene(dir: dir, mode: mode, spandac: FakeSpanDACOutputs(), speakers: speakers,
                                   status: status, backend: backend, actions: actions)
        settleOutputTab(s, speakers: speakers.count)
        XCTAssertEqual(s.speakerRowsForTest.count, speakers.count, "the speaker rows never loaded")
        return s
    }

    @discardableResult
    private func moveTo(_ s: SpeakersScene, speaker name: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        _ = s.handle(.home)
        for _ in 0..<40 {
            if case .speaker(let i)? = s.cursorRowForTest, s.speakerRowsForTest[i].name == name { return true }
            _ = s.handle(.down)
        }
        XCTFail("never reached the '\(name)' row", file: file, line: line)
        return false
    }

    private func volume(_ s: SpeakersScene, _ name: String) -> Int? {
        s.speakerRowsForTest.first { $0.name == name }?.volume
    }

    private func screenRow(_ s: SpeakersScene, _ name: String, width: Int = 100) -> String? {
        let lines = screenText(s.render(frame: shellLayout(width: width, height: 30), snapshot: outputTabSnapshot()),
                               width: width, height: 30)
        return lines.first { ($0.contains("\u{25CF}") || $0.contains("\u{25CB}")) && $0.contains(name) }
    }

    /// The macOS volume command is a Standard Additions command: it must not
    /// sit inside a multi-line `tell application "Music"` block, which would
    /// send it to Music instead of running it here.
    private func assertSystemVolumeScript(_ script: String, to v: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(script.contains("set volume output volume \(v)"), script, file: file, line: line)
        XCTAssertFalse(script.contains("set sound volume"), "never Music's device volume for the Mac row: \(script)",
                       file: file, line: line)
        guard let check = script.range(of: "selected of AirPlay device \"\(mac)\""),
              let write = script.range(of: "set volume output volume") else {
            return XCTFail("the write rechecks the selection in the same script: \(script)", file: file, line: line)
        }
        XCTAssertTrue(check.lowerBound < write.lowerBound, "the recheck comes before the write: \(script)",
                      file: file, line: line)
        let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(lines.contains("tell application \"Music\""),
                       "the system volume command is not wrapped in a Music tell block: \(script)",
                       file: file, line: line)
    }

    // MARK: - Write: the Mac row sets the macOS output volume

    func testRightAndLeftOnTheMacRowSetTheMacOutputVolumeWithTheSelectionRechecked() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [macRow(output: 40)], backend: backend, status: status, actions: actions)
        moveTo(s, speaker: mac)
        XCTAssertTrue(s.footerHint.contains("\u{2190}\u{2192} Volume"), s.footerHint)
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(volume(s, mac), 45, "the bar moves from the macOS volume, not Music's 52")
        XCTAssertEqual(scripts().count, 1, "\(scripts())")
        assertSystemVolumeScript(scripts().last ?? "", to: 45)
        _ = s.handle(.left)
        actions.waitUntilIdle()
        XCTAssertEqual(volume(s, mac), 40)
        XCTAssertEqual(scripts().count, 2, "\(scripts())")
        assertSystemVolumeScript(scripts().last ?? "", to: 40)
        XCTAssertNil(status.current(), "a normal change posts nothing")
    }

    func testAnAirPlayRowBesideTheMacRowStillSetsItsOwnSoundVolume() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [macRow(output: 40), speaker("Kitchen", on: true, volume: 50)], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: "Kitchen")
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(volume(s, "Kitchen"), 55)
        XCTAssertEqual(volume(s, mac), 40, "the Mac row is untouched")
        let sent = scripts()
        XCTAssertEqual(sent.count, 1, "\(sent)")
        let script = sent.first ?? ""
        XCTAssertTrue(script.contains(#"set sound volume of AirPlay device "Kitchen" to 55"#), script)
        XCTAssertTrue(script.contains(#"if selected of AirPlay device "Kitchen""#), script)
        XCTAssertFalse(script.contains("output volume"), "an AirPlay speaker never touches the macOS volume: \(script)")
    }

    // MARK: - Read: the Mac row shows the macOS output volume

    func testTheMacRowShowsTheMacOutputVolumeNotMusics() throws {
        let status = StatusStore()
        let s = scene(speakers: [macRow(music: 52, output: 20), speaker("Kitchen", on: true, volume: 57)],
                      backend: AppleScriptBackend(executable: "/usr/bin/true"),
                      status: status, actions: ActionRunner(status: status))
        _ = s.handle(.home)
        XCTAssertEqual(volume(s, mac), 20)
        XCTAssertEqual(volume(s, "Kitchen"), 57, "an AirPlay speaker shows its own volume")
        guard let row = screenRow(s, "MacBook") else { return XCTFail("the Mac row is not drawn") }
        XCTAssertTrue(row.contains(" 20"), row)
        XCTAssertFalse(row.contains("52"), "Music's number for the Mac is not what you hear: \(row)")
    }

    // MARK: - No software volume on the Mac's output

    func testAMacOutputWithNoVolumeShowsMusicsNumberAndItsArrowsSaySoAndWriteNothing() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [macRow(music: 52, output: "missing")], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: mac)
        XCTAssertEqual(volume(s, mac), 52, "falls back to Music's number for display")
        XCTAssertFalse(s.footerHint.contains("Volume"), "no volume keys offered where none work: \(s.footerHint)")
        for key in [KeyPress.right, .left] {
            _ = s.handle(key)
            actions.waitUntilIdle()
            XCTAssertEqual(scripts(), [], "\(key)")
            XCTAssertEqual(volume(s, mac), 52, "no optimistic bar change (\(key))")
            XCTAssertEqual(status.current()?.text, noVolume, "\(key)")
        }
    }

    // MARK: - Replies, unchanged from 3.24.4

    func testTheMacRowTurnedOffWhileTheWriteWaitedSaysTurnItOn() throws {
        let (backend, scripts) = try recordingBackend(reply: "off")
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [macRow(output: 40)], backend: backend, status: status, actions: actions)
        moveTo(s, speaker: mac)
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(scripts().count, 1, "\(scripts())")
        XCTAssertEqual(status.current()?.text, "Turn '\(mac)' on to set its volume.")
        XCTAssertEqual(status.current()?.isError, true)
    }

    func testOnlyASetReplyIsADoneWriteForTheMacRow() throws {
        for (reply, exit) in [("", 0), ("maybe", 0), ("set", 1)] {
            let (backend, _) = try recordingBackend(reply: reply, exit: exit)
            let status = StatusStore(), actions = ActionRunner(status: status)
            let s = scene(speakers: [macRow(output: 40)], backend: backend, status: status, actions: actions)
            moveTo(s, speaker: mac)
            _ = s.handle(.right)
            actions.waitUntilIdle()
            XCTAssertEqual(status.current()?.text, "Couldn't set '\(mac)' volume.", "reply \(reply.debugDescription) exit \(exit)")
            XCTAssertEqual(status.current()?.isError, true)
        }
    }

    func testSpanDACRefusalStillWinsOnTheMacRow() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(mode: .source, speakers: [macRow(output: 40)], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: mac)
        XCTAssertFalse(s.footerHint.contains("Volume"), s.footerHint)
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(scripts(), [])
        XCTAssertEqual(volume(s, mac), 40)
        XCTAssertEqual(status.current()?.text, "Volume is MusicTUI only; SpanDAC plays at the Mac's output level.")
    }

    func testAnOffMacRowStillHasNoBarAndWritesNothing() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [macRow(on: false, music: 33, output: 61)], backend: backend,
                      status: status, actions: actions)
        _ = s.handle(.home)
        guard let row = screenRow(s, "MacBook") else { return XCTFail("the Mac row is not drawn") }
        XCTAssertFalse(row.contains("61") || row.contains("33"), "an off row shows no number: \(row)")
        XCTAssertFalse(row.contains("\u{2588}") || row.contains("\u{2591}"), "an off row has no bar: \(row)")
        moveTo(s, speaker: mac)
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(scripts(), [])
        XCTAssertEqual(status.current()?.text, "Turn '\(mac)' on to set its volume.")
    }

    // MARK: - The list read: one osascript, macOS volume alongside

    func testTheListReadParsesTheMacOutputVolumeOntoTheComputerRowOnly() {
        let raw = "Studio Mac\nKitchen\n=====\ntrue\nfalse\n=====\n52\n33\n=====\ncomputer\nHomePod\n=====\n20"
        guard let devices = parseOutputTabSpeakerBlocks(raw) else { return XCTFail("parsed nothing") }
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0]["outputVolume"] as? Int, 20)
        XCTAssertEqual(devices[0]["volume"] as? Int, 52, "Music's own number is kept")
        XCTAssertNil(devices[1]["outputVolume"], "an AirPlay speaker carries no macOS volume")
        let rows = speakerRows(from: devices)
        XCTAssertEqual(rows.map(\.volume), [20, 33])
    }

    func testTheListReadMarksAMissingMacOutputVolume() {
        let raw = "Studio Mac\n=====\ntrue\n=====\n52\n=====\ncomputer\n=====\nmissing value"
        guard let devices = parseOutputTabSpeakerBlocks(raw) else { return XCTFail("parsed nothing") }
        XCTAssertEqual(devices.first?["outputVolume"] as? String, "missing")
        XCTAssertEqual(speakerRows(from: devices).first?.volume, 52)
    }

    func testTheListReadIsStillOneScriptWithTheMacVolumeReadOutsideMusic() throws {
        let canned = "Studio Mac\nKitchen\n=====\ntrue\nfalse\n=====\n52\n33\n=====\ncomputer\nHomePod\n=====\n20"
        let (backend, scripts) = try recordingBackend(reply: canned)
        let devices = try fetchOutputTabSpeakerDevices(backend: backend, cache: ResultCache(directory: dir))
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first?["outputVolume"] as? Int, 20)
        let sent = scripts()
        XCTAssertEqual(sent.count, 1, "one osascript launch for the list and the macOS volume: \(sent)")
        let script = sent.first ?? ""
        XCTAssertTrue(script.contains("get volume settings"), script)
        XCTAssertFalse(script.contains("set "+"volume output"), "the list read sets nothing: \(script)")
        XCTAssertFalse(script.contains("set sound volume"), "the list read sets nothing: \(script)")
        guard let endTell = script.range(of: "end tell", options: .backwards),
              let settings = script.range(of: "get volume settings") else {
            return XCTFail("the Music block is closed before the macOS read: \(script)")
        }
        XCTAssertTrue(endTell.lowerBound < settings.lowerBound,
                      "the macOS volume is read outside the Music tell block: \(script)")
    }
}
