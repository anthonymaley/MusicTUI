import XCTest
@testable import music

/// The speaker list lands as soon as its own read does; EQ and visualizer
/// state land separately from the same job (measured 2026-10-31: the list
/// alone ~0.9 s, the whole job ~2.5 s on first open).
final class SpeakersListFirstTests: XCTestCase {
    var dir: String!
    override func setUp() {
        dir = NSTemporaryDirectory() + "speakers-list-first-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func kitchen(_ name: String = "Kitchen") -> [[String: Any]] {
        [["name": name, "selected": false, "volume": 20, "kind": "speaker"]]
    }

    private func screen(_ s: SpeakersScene, width: Int = 100, height: Int = 30) -> String {
        let frame = shellLayout(width: width, height: height)
        return screenText(s.render(frame: frame, snapshot: outputTabSnapshot()), width: width, height: height)
            .joined(separator: "\n")
    }

    /// Ticks until `done` holds or the deadline passes.
    private func tickUntil(_ s: SpeakersScene, timeout: TimeInterval = 2, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = s.tick(snapshot: outputTabSnapshot())
            if done() { return true }
            usleep(5_000)
        }
        return false
    }

    func testTheListLandsWhileTheEQReadIsStillHeld() {
        let eqStarted = DispatchSemaphore(value: 0), releaseEQ = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, fetchSpeakers: { self.kitchen() },
                                   fetchEQ: { _ in
                                       eqStarted.signal(); _ = releaseEQ.wait(timeout: .now() + 3)
                                       return EQSnapshot(enabled: true, current: "Rock", presets: ["Rock"])
                                   },
                                   fetchVisualizer: { _ in true })
        s.fetchFinishedForTest = { _ in finished.signal() }
        defer { releaseEQ.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(eqStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.speakerRowsForTest.map(\.name) == ["Kitchen"] },
                      "the list waited for the EQ read")
        XCTAssertFalse(screen(s).contains("loading speakers"))
        XCTAssertNil(s.eqStateForTest, "EQ landed before its read finished")
        releaseEQ.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.eqStateForTest?.current == "Rock" })
        XCTAssertEqual(s.visualizerOnForTest, true)
    }

    func testNoSecondReadStartsWhileTheFirstJobsEQIsHeld() {
        let eqStarted = DispatchSemaphore(value: 0), releaseEQ = DispatchSemaphore(value: 0)
        let lock = NSLock(); var calls = 0
        var now = Date(timeIntervalSince1970: 1000)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, fetchSpeakers: {
            lock.lock(); calls += 1; lock.unlock(); return self.kitchen()
        }, fetchNow: { now }, fetchEQ: { _ in
            eqStarted.signal(); _ = releaseEQ.wait(timeout: .now() + 3)
            return EQSnapshot(enabled: false, current: nil, presets: [])
        })
        defer { releaseEQ.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(eqStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.speakerRowsForTest.count == 1 })
        // A refresh interval and a re-entry gap pass while EQ is still held.
        now.addTimeInterval(6)
        _ = s.tick(snapshot: outputTabSnapshot())
        now.addTimeInterval(1)
        _ = s.tick(snapshot: outputTabSnapshot())
        usleep(50_000)
        lock.lock(); let n = calls; lock.unlock()
        XCTAssertEqual(n, 1, "a second job started while the first still owned the read")
    }

    func testAFailedSpeakerReadIsSaidWhileTheEQReadIsHeld() {
        enum ReadFailure: Error { case failed }
        let lock = NSLock(); var calls = 0
        let finished = DispatchSemaphore(value: 0)
        let eqStarted = DispatchSemaphore(value: 0), releaseEQ = DispatchSemaphore(value: 0)
        var holdEQ = false
        var now = Date(timeIntervalSince1970: 1000)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, fetchSpeakers: {
            lock.lock(); calls += 1; let call = calls; lock.unlock()
            if call == 2 { throw ReadFailure.failed }
            return self.kitchen()
        }, fetchNow: { now }, fetchEQ: { _ in
            lock.lock(); let hold = holdEQ; lock.unlock()
            if hold { eqStarted.signal(); _ = releaseEQ.wait(timeout: .now() + 3) }
            return EQSnapshot(enabled: false, current: nil, presets: [])
        })
        s.fetchFinishedForTest = { _ in finished.signal() }
        defer { releaseEQ.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.speakerRowsForTest.count == 1 })
        lock.lock(); holdEQ = true; lock.unlock()
        now.addTimeInterval(6)
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(eqStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { self.screen(s).contains("speaker list unavailable") },
                      "the failure waited for the EQ read")
        XCTAssertEqual(s.speakerRowsForTest.map(\.name), ["Kitchen"], "the last list was dropped")
    }

    func testAToggleAfterKickoffFencesTheEQStateFromThatJob() {
        let eqStarted = DispatchSemaphore(value: 0), releaseEQ = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var now = Date(timeIntervalSince1970: 1000)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, fetchSpeakers: { self.kitchen() },
                                   fetchNow: { now }, fetchEQ: { _ in
                                       eqStarted.signal(); _ = releaseEQ.wait(timeout: .now() + 3)
                                       return EQSnapshot(enabled: true, current: "Stale", presets: ["Stale"])
                                   })
        s.fetchFinishedForTest = { _ in finished.signal() }
        defer { releaseEQ.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(eqStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.speakerRowsForTest.count == 1 })
        guard let row = s.displayRowsForTest.firstIndex(of: .speaker(0)) else { XCTFail("no speaker row"); return }
        for _ in 0..<row { _ = s.handle(.down) }
        now.addTimeInterval(1)
        _ = s.handle(.enter)
        releaseEQ.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        for _ in 0..<5 { _ = s.tick(snapshot: outputTabSnapshot()) }
        XCTAssertNil(s.eqStateForTest, "a result read before the toggle overwrote state after it")
    }

    func testAnOlderJobsEQCannotReplaceANewerJobsEQ() {
        let oldEQStarted = DispatchSemaphore(value: 0), releaseOldEQ = DispatchSemaphore(value: 0)
        let oldFinished = DispatchSemaphore(value: 0), newFinished = DispatchSemaphore(value: 0)
        let lock = NSLock(); var eqCalls = 0
        var now = Date(timeIntervalSince1970: 1000)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, fetchSpeakers: { self.kitchen() },
                                   fetchNow: { now }, fetchEQ: { _ in
                                       lock.lock(); eqCalls += 1; let call = eqCalls; lock.unlock()
                                       if call == 1 {
                                           oldEQStarted.signal(); _ = releaseOldEQ.wait(timeout: .now() + 3)
                                           return EQSnapshot(enabled: true, current: "Old", presets: ["Old"])
                                       }
                                       return EQSnapshot(enabled: true, current: "New", presets: ["New"])
                                   })
        s.fetchFinishedForTest = { serial in (serial == 1 ? oldFinished : newFinished).signal() }
        defer { releaseOldEQ.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(oldEQStarted.wait(timeout: .now() + 2), .success)
        now.addTimeInterval(31)                     // the first job is declared dead
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(newFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.eqStateForTest?.current == "New" })
        releaseOldEQ.signal()
        XCTAssertEqual(oldFinished.wait(timeout: .now() + 2), .success)
        for _ in 0..<5 { _ = s.tick(snapshot: outputTabSnapshot()) }
        XCTAssertEqual(s.eqStateForTest?.current, "New")
    }

    // Codex round 2 (77f2e2b8): with the list landing early, the person can
    // move around before EQ lands; rows inserted or removed by that late
    // answer must not move the highlight onto a different action.

    private func moveCursor(_ s: SpeakersScene, to row: OutputTabRow) -> Bool {
        for _ in 0..<60 {
            if s.cursorRowForTest == row { return true }
            _ = s.handle(.down)
        }
        return s.cursorRowForTest == row
    }

    func testALateEQAnswerInsertingPresetsKeepsTheCursorOnVisualizer() {
        let eqStarted = DispatchSemaphore(value: 0), releaseEQ = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, fetchSpeakers: { self.kitchen() },
                                   fetchEQ: { _ in
                                       eqStarted.signal(); _ = releaseEQ.wait(timeout: .now() + 3)
                                       return EQSnapshot(enabled: true, current: "My Custom",
                                                         presets: ["My Custom", "Another Custom"])
                                   })
        s.fetchFinishedForTest = { _ in finished.signal() }
        defer { releaseEQ.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(eqStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.speakerRowsForTest.count == 1 })
        XCTAssertTrue(moveCursor(s, to: .eq))
        _ = s.handle(.enter)                         // expand the picker
        XCTAssertTrue(moveCursor(s, to: .visualizer))
        releaseEQ.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.eqStateForTest != nil })
        XCTAssertTrue(s.displayRowsForTest.contains(.preset("My Custom")), "the custom presets were not inserted")
        XCTAssertEqual(s.cursorRowForTest, .visualizer)
    }

    func testAPresetThatDisappearsMovesTheCursorToTheEQRow() {
        let lock = NSLock(); var eqCalls = 0
        let finished = DispatchSemaphore(value: 0)
        let eqStarted = DispatchSemaphore(value: 0), releaseEQ = DispatchSemaphore(value: 0)
        var now = Date(timeIntervalSince1970: 1000)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, fetchSpeakers: { self.kitchen() },
                                   fetchNow: { now }, fetchEQ: { _ in
                                       lock.lock(); eqCalls += 1; let call = eqCalls; lock.unlock()
                                       if call == 1 { return EQSnapshot(enabled: true, current: nil, presets: ["Gone", "Stays"]) }
                                       eqStarted.signal(); _ = releaseEQ.wait(timeout: .now() + 3)
                                       return EQSnapshot(enabled: true, current: nil, presets: ["Stays"])
                                   })
        s.fetchFinishedForTest = { _ in finished.signal() }
        defer { releaseEQ.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.eqStateForTest != nil })
        XCTAssertTrue(moveCursor(s, to: .eq))
        _ = s.handle(.enter)
        XCTAssertTrue(moveCursor(s, to: .preset("Gone")))
        now.addTimeInterval(6)
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(eqStarted.wait(timeout: .now() + 2), .success)
        releaseEQ.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { !s.displayRowsForTest.contains(.preset("Gone")) })
        XCTAssertEqual(s.cursorRowForTest, .eq)
    }

    func testTheListLandingKeepsTheCursorOnARowBelowIt() {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil, fetchSpeakers: {
            started.signal(); _ = release.wait(timeout: .now() + 3)
            return (0..<3).map { ["name": "Room \($0)", "selected": false, "volume": 20, "kind": "speaker"] }
        })
        defer { release.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(moveCursor(s, to: .visualizer))
        release.signal()
        XCTAssertTrue(tickUntil(s) { s.speakerRowsForTest.count == 3 })
        XCTAssertEqual(s.cursorRowForTest, .visualizer)
    }
}
