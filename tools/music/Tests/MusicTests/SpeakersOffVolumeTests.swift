// tools/music/Tests/MusicTests/SpeakersOffVolumeTests.swift
//
// A speaker that is off has no volume of its own on the Output tab. Measured on
// the Studio (2026-11-01, docs/plans/2026-11-01-speaker-volume): Music ignores
// `set sound volume` on an AirPlay device that is not selected, and reports the
// Mac's own volume for every unselected device. So an off row shows no bar, its
// arrows write nothing and say to turn it on, and the write for an on row checks
// the speaker is still selected in the same AppleScript, because the selection
// can change while the write waits on the action queue.
//
// The guard is Music's `selected`, never the device kind: the Mac's own output
// ("computer"), when selected, stays adjustable.
//
// The AppleScript backend is a recording stand-in for osascript. Nothing here
// reaches the real osascript, Music, a player, a socket, the keychain or
// ~/.config/music.
import XCTest
@testable import music

final class SpeakersOffVolumeTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "speakers-off-volume-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    // MARK: Rigs

    /// Appends each script (`$2`, after `-e`) to a file, prints `reply`, and
    /// exits with `exit`. Stands in for Music's answer to the write.
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

    private func hold(_ actions: ActionRunner) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        actions.enqueueQuiet { gate.wait() }
        return { gate.signal() }
    }

    private func screenLines(_ s: SpeakersScene, width: Int = 100) -> [String] {
        screenText(s.render(frame: shellLayout(width: width, height: 30), snapshot: outputTabSnapshot()),
                   width: width, height: 30)
    }

    private let turnOn = "Turn 'Kitchen' on to set its volume."

    // MARK: - An off speaker: no write, a notice, no bar

    func testArrowsOnAnOffSpeakerWriteNothingMoveNothingAndSayTurnItOn() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [speaker("Kitchen", on: false, volume: 33)], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: "Kitchen")
        for key in [KeyPress.right, .left] {
            _ = s.handle(key)
            actions.waitUntilIdle()
            XCTAssertEqual(scripts(), [], "an off speaker's volume write is ignored by Music; none is sent (\(key))")
            XCTAssertEqual(volume(s, "Kitchen"), 33, "no optimistic bar change (\(key))")
            XCTAssertEqual(status.current()?.text, turnOn, "\(key)")
        }
    }

    func testAnOffSpeakerOffersNoVolumeKeysAndAnOnOneDoes() throws {
        let status = StatusStore()
        let s = scene(speakers: [speaker("Kitchen", on: false, volume: 33), speaker("Deck", on: true, volume: 50)],
                      backend: AppleScriptBackend(executable: "/usr/bin/true"),
                      status: status, actions: ActionRunner(status: status))
        moveTo(s, speaker: "Kitchen")
        XCTAssertTrue(s.footerHint.contains("Enter Toggle"), s.footerHint)
        XCTAssertFalse(s.footerHint.contains("Volume"), s.footerHint)
        moveTo(s, speaker: "Deck")
        XCTAssertTrue(s.footerHint.contains("\u{2190}\u{2192} Volume"), s.footerHint)
    }

    func testAnOffSpeakerDrawsNoVolumeAndAnOnOneDoes() throws {
        let status = StatusStore()
        let s = scene(speakers: [speaker("Kitchen", on: false, volume: 33), speaker("Deck", on: true, volume: 57)],
                      backend: AppleScriptBackend(executable: "/usr/bin/true"),
                      status: status, actions: ActionRunner(status: status))
        _ = s.handle(.home)     // the highlight on neither speaker
        for width in [100, 60] {
            let lines = screenLines(s, width: width)
            // The speaker rows, not the "Playing through" line that names them.
            let rows = lines.filter { $0.contains("\u{25CF}") || $0.contains("\u{25CB}") }
            guard let off = rows.first(where: { $0.contains("Kitchen") }),
                  let on = rows.first(where: { $0.contains("Deck") }) else {
                return XCTFail("speaker rows not drawn at \(width):\n\(lines.joined(separator: "\n"))")
            }
            XCTAssertTrue(on.contains("57"), "the on speaker shows its volume at \(width): \(on)")
            XCTAssertTrue(on.contains("\u{2588}") || on.contains("\u{2591}"), "the on speaker has a bar at \(width): \(on)")
            XCTAssertFalse(off.contains("33"), "the off speaker shows a volume Music does not have at \(width): \(off)")
            XCTAssertFalse(off.contains("\u{2588}") || off.contains("\u{2591}"), "the off speaker has a bar at \(width): \(off)")
        }
    }

    // MARK: - An on speaker: written as before, with the selection rechecked

    func testRightOnAnOnSpeakerWritesWithTheSelectionRecheckedInTheSameScript() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [speaker("Kitchen", on: true, volume: 50)], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: "Kitchen")
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(volume(s, "Kitchen"), 55)
        let sent = scripts()
        XCTAssertEqual(sent.count, 1, "\(sent)")
        let script = sent.first ?? ""
        XCTAssertTrue(script.contains(#"set sound volume of AirPlay device "Kitchen" to 55"#), script)
        XCTAssertTrue(script.contains(#"if selected of AirPlay device "Kitchen""#),
                      "the write checks the speaker is still on, in the same script: \(script)")
        XCTAssertNil(status.current(), "a normal change posts nothing")
    }

    func testTheSelectedLocalMacStaysAdjustable() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [speaker("Anthony's MacBook Pro", on: true, volume: 30, kind: "computer")],
                      backend: backend, status: status, actions: actions)
        moveTo(s, speaker: "Anthony's MacBook Pro")
        XCTAssertTrue(s.footerHint.contains("Volume"), s.footerHint)
        _ = s.handle(.left)
        actions.waitUntilIdle()
        XCTAssertEqual(volume(s, "Anthony's MacBook Pro"), 25)
        XCTAssertEqual(scripts().count, 1)
        // The Mac's own row sets the macOS output volume (2026-11-01 17:43;
        // SpeakersMacOutputVolumeTests), not Music's volume for the device.
        XCTAssertTrue(scripts().first?.contains("set volume output volume 25") == true, "\(scripts())")
        XCTAssertNil(status.current())
    }

    func testAnUnselectedLocalMacIsGuardedLikeAnyOffSpeaker() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [speaker("Anthony's MacBook Pro", on: false, volume: 30, kind: "computer")],
                      backend: backend, status: status, actions: actions)
        moveTo(s, speaker: "Anthony's MacBook Pro")
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(scripts(), [])
        XCTAssertEqual(volume(s, "Anthony's MacBook Pro"), 30)
        XCTAssertEqual(status.current()?.text, "Turn 'Anthony's MacBook Pro' on to set its volume.")
    }

    // MARK: - Turned off while the write waited

    /// Music answers that the speaker is no longer selected when the queued
    /// write runs (it was turned off elsewhere, after the keypress): the
    /// person is told, never left with a silent success.
    func testASpeakerTurnedOffWhileTheWriteWaitedIsReportedNotClaimed() throws {
        let (backend, scripts) = try recordingBackend(reply: "off")
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [speaker("Kitchen", on: true, volume: 50)], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: "Kitchen")
        let release = hold(actions)
        _ = s.handle(.right)
        release()
        actions.waitUntilIdle()
        XCTAssertEqual(scripts().count, 1, "the write went out with its recheck: \(scripts())")
        let toast = status.current()
        XCTAssertEqual(toast?.text, turnOn)
        XCTAssertEqual(toast?.isError, true)
    }

    /// Only Music's own "set" counts as done (Codex r3): any other answer,
    /// blank included, is reported as a failed write, never a silent success.
    func testAnUnexpectedAnswerToTheWriteIsAnErrorNotASuccess() throws {
        for reply in ["", "maybe"] {
            let (backend, _) = try recordingBackend(reply: reply)
            let status = StatusStore(), actions = ActionRunner(status: status)
            let s = scene(speakers: [speaker("Kitchen", on: true, volume: 50)], backend: backend,
                          status: status, actions: actions)
            moveTo(s, speaker: "Kitchen")
            _ = s.handle(.right)
            actions.waitUntilIdle()
            XCTAssertEqual(status.current()?.text, "Couldn't set 'Kitchen' volume.", "reply \(reply.debugDescription)")
            XCTAssertEqual(status.current()?.isError, true, "reply \(reply.debugDescription)")
        }
    }

    func testAFailedWriteIsAnErrorNotASuccess() throws {
        let (backend, _) = try recordingBackend(exit: 1)
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(speakers: [speaker("Kitchen", on: true, volume: 50)], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: "Kitchen")
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(status.current()?.text, "Couldn't set 'Kitchen' volume.")
        XCTAssertEqual(status.current()?.isError, true)
    }

    /// Turned on with Enter, then raised before the selection has gone out:
    /// the write queues behind the select, so it is allowed at the keypress.
    func testASpeakerJustTurnedOnCanBeRaisedAtOnce() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        // The Mac's own output: a select with no route check, so the only
        // scripts are the select and the volume write.
        let s = scene(speakers: [speaker("Kitchen", on: false, volume: 33, kind: "computer")], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: "Kitchen")
        let release = hold(actions)
        _ = s.handle(.enter)
        _ = s.handle(.right)
        release()
        actions.waitUntilIdle()
        let sent = scripts()
        XCTAssertEqual(sent.count, 2, "\(sent)")
        XCTAssertTrue(sent.first?.contains("set selected of AirPlay device \"Kitchen\" to true") == true, "\(sent)")
        // A "computer" row: its write is the macOS output volume.
        XCTAssertTrue(sent.last?.contains("set volume output volume 38") == true, "\(sent)")
    }

    // MARK: - Unchanged: SpanDAC refusal, held rows

    /// While SpanDAC is the output the routing refusal speaks first, for an off
    /// speaker too: turning it on would not make volume work.
    func testSpanDACRefusalStillWinsOnAnOffSpeaker() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let s = scene(mode: .source, speakers: [speaker("Kitchen", on: false, volume: 33)], backend: backend,
                      status: status, actions: actions)
        moveTo(s, speaker: "Kitchen")
        XCTAssertFalse(s.footerHint.contains("Volume"), s.footerHint)
        _ = s.handle(.right)
        actions.waitUntilIdle()
        XCTAssertEqual(scripts(), [])
        XCTAssertEqual(volume(s, "Kitchen"), 33)
        XCTAssertEqual(status.current()?.text, "Volume is MusicTUI only; SpanDAC plays at the Mac's output level.")
    }

    func testArrowsOnAHeldRowStillActOnNothingAndSayNothing() throws {
        let (backend, scripts) = try recordingBackend()
        let status = StatusStore(), actions = ActionRunner(status: status)
        let list = LockedBox<[[String: Any]]>([speaker("Kitchen", on: true, volume: 50), speaker("Deck", on: true, volume: 40)])
        let now = LockedBox(Date())
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: FakeSpanDACOutputs(),
                                   status: status, backend: backend, actions: actions,
                                   fetchSpeakers: { list.get() }, fetchNow: { now.get() })
        settleOutputTab(s, speakers: 2)
        moveTo(s, speaker: "Deck")
        list.set([speaker("Kitchen", on: true, volume: 50)])
        now.set(now.get().addingTimeInterval(6))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !(s.cursorRowForTest?.isHeld ?? false) {
            _ = s.tick(snapshot: outputTabSnapshot())
            usleep(5_000)
        }
        XCTAssertTrue(s.cursorRowForTest?.isHeld == true, "the highlight is held on the gone speaker")
        for key in [KeyPress.right, .left] {
            _ = s.handle(key)
            actions.waitUntilIdle()
        }
        XCTAssertEqual(scripts(), [])
        XCTAssertEqual(volume(s, "Kitchen"), 50)
        XCTAssertNil(status.current(), "a held row says nothing on the arrows")
    }
}
