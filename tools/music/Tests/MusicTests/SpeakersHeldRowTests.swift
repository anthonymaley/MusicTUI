import XCTest
@testable import music

/// When a list update takes away the row under the highlight (a speaker that
/// dropped out of the AirPlay list, or the "use MusicTUI" stand-in the first
/// list replaces), the highlight must not land on a row the person did not
/// pick: Enter and the arrows act on nothing until they move (Codex round 3,
/// 5c2219a8; shaped 2026-11-01, Anthony "y" 14:16).
final class SpeakersHeldRowTests: XCTestCase {
    var dir: String!
    override func setUp() {
        dir = NSTemporaryDirectory() + "speakers-held-row-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    /// The speaker read answers from `list`; a read starts again when `now`
    /// moves past the 5 s kickoff threshold. `holdFirst` keeps the first read
    /// waiting until `release` is signalled.
    private final class Harness {
        let lock = NSLock()
        private var _list: [[String: Any]]
        private var _fail = false
        private var _now = Date(timeIntervalSince1970: 1000)
        private var calls = 0
        private var finished = 0
        let holdFirst: Bool
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var scene: SpeakersScene!

        init(_ names: [String], holdFirst: Bool = false) {
            _list = Harness.speakers(names)
            self.holdFirst = holdFirst
        }

        static func speakers(_ names: [String]) -> [[String: Any]] {
            names.map { ["name": $0, "selected": false, "volume": 20, "kind": "speaker"] }
        }

        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
        var finishedReads: Int { lock.lock(); defer { lock.unlock() }; return finished }
        func noteFinished() { lock.lock(); finished += 1; lock.unlock() }

        func read() throws -> [[String: Any]] {
            lock.lock(); calls += 1; let call = calls; let fail = _fail; let list = _list; lock.unlock()
            if call == 1, holdFirst { started.signal(); _ = release.wait(timeout: .now() + 3) }
            enum ReadFailure: Error { case failed }
            if fail { throw ReadFailure.failed }
            return list
        }

        func next(_ names: [String]?, fail: Bool = false) {
            lock.lock()
            if let names { _list = Harness.speakers(names) }
            _fail = fail
            _now.addTimeInterval(6)
            lock.unlock()
        }
    }

    private func make(_ h: Harness, spandac: SpanDACOutputsDriving? = nil) -> SpeakersScene {
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: spandac,
                                   fetchSpeakers: { try h.read() }, fetchNow: { h.now })
        s.fetchFinishedForTest = { _ in h.noteFinished() }
        h.scene = s
        return s
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

    private func names(_ s: SpeakersScene) -> [String] { s.speakerRowsForTest.map(\.name) }

    /// The name of the speaker under the highlight, if it is on a live speaker.
    private func cursorSpeaker(_ s: SpeakersScene) -> String? {
        guard case .speaker(let i)? = s.cursorRowForTest, s.speakerRowsForTest.indices.contains(i) else { return nil }
        return s.speakerRowsForTest[i].name
    }

    private func moveToSpeaker(_ s: SpeakersScene, _ name: String) -> Bool {
        for _ in 0..<60 {
            if cursorSpeaker(s) == name { return true }
            _ = s.handle(.down)
        }
        return cursorSpeaker(s) == name
    }

    private func moveTo(_ s: SpeakersScene, _ row: OutputTabRow) -> Bool {
        for _ in 0..<60 {
            if s.cursorRowForTest == row { return true }
            _ = s.handle(.down)
        }
        return s.cursorRowForTest == row
    }

    /// Every speaker's on/off and volume, and the EQ switch: what Enter and
    /// the arrows would change, optimistically, before any write goes out.
    private func actionable(_ s: SpeakersScene) -> [String] {
        s.speakerRowsForTest.map { "\($0.name)|\($0.active)|\($0.volume)" } + ["eq|\(String(describing: s.eqStateForTest?.enabled))"]
    }

    private func assertKeysActOnNothing(_ s: SpeakersScene, file: StaticString = #filePath, line: UInt = #line) {
        let before = actionable(s)
        XCTAssertEqual(s.handle(.enter), .none, "Enter acted on a row the person did not pick", file: file, line: line)
        _ = s.handle(.left)
        _ = s.handle(.right)
        XCTAssertEqual(actionable(s), before, "a key changed a speaker or the EQ", file: file, line: line)
    }

    /// Re-reads a list whose names do not change, and waits for that read to
    /// finish and be drained, not for a fixed number of ticks.
    private func reread(_ s: SpeakersScene, _ h: Harness, _ names: [String],
                        file: StaticString = #filePath, line: UInt = #line) {
        let before = h.finishedReads
        h.next(names)
        XCTAssertTrue(tickUntil(s) { h.finishedReads > before }, "the re-read never finished", file: file, line: line)
        for _ in 0..<3 { _ = s.tick(snapshot: outputTabSnapshot()) }
    }

    private func settle(_ s: SpeakersScene, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tickUntil(s) { names(s) == expected }, "the list never became \(expected)", file: file, line: line)
        // Let the job's EQ/visualizer part land too, so the next read can start.
        for _ in 0..<20 { _ = s.tick(snapshot: outputTabSnapshot()); usleep(2_000) }
    }

    // MARK: - Enter and the arrows act on nothing

    func testEnterAndArrowsActOnNothingWhenTheHighlightedSpeakerVanishes() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        XCTAssertNil(cursorSpeaker(s), "the highlight landed on \(cursorSpeaker(s) ?? "-")")
        assertKeysActOnNothing(s)
    }

    func testEnterDoesNotTurnTheEQOffWhenTheLastSpeakerVanishes() {
        let h = Harness(["Basement", "Sonos Arc"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        h.next(["Basement"])
        settle(s, ["Basement"])
        XCTAssertNotEqual(s.cursorRowForTest, .eqPower)
        assertKeysActOnNothing(s)
    }

    func testEnterActsOnNothingWhenTheFirstListReplacesTheHighlightedStandIn() {
        let h = Harness(["Basement", "Sonos Arc"], holdFirst: true)
        let s = make(h)
        defer { h.release.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(h.started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(moveTo(s, .musicApp), "the stand-in row was not reachable while the list loaded")
        h.release.signal()
        settle(s, ["Basement", "Sonos Arc"])
        XCTAssertNil(cursorSpeaker(s), "the highlight landed on \(cursorSpeaker(s) ?? "-")")
        assertKeysActOnNothing(s)
    }

    // MARK: - Moving off, returning, failing

    func testMovingDownOffTheHeldRowLandsOnTheSpeakerThatFollowedIt() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        XCTAssertEqual(s.handle(.down), .redraw)
        XCTAssertEqual(cursorSpeaker(s), "Studio", "moving off the held row skipped a row or stayed")
    }

    func testMovingUpOffTheHeldRowLandsOnTheSpeakerBeforeIt() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        XCTAssertEqual(s.handle(.up), .redraw)
        XCTAssertEqual(cursorSpeaker(s), "Basement")
    }

    func testAUniquelyNamedReturnBringsTheHighlightBackToThatSpeaker() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        h.next(["Sonos Arc", "Basement", "Studio"])     // back, in a different place
        settle(s, ["Sonos Arc", "Basement", "Studio"])
        XCTAssertEqual(cursorSpeaker(s), "Sonos Arc")
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertEqual(s.speakerRowsForTest.first(where: { $0.name == "Sonos Arc" })?.active, true,
                       "Enter on the returned speaker did not act on it")
    }

    func testTwoSpeakersReturningUnderTheHeldNameKeepItHeld() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        h.next(["Basement", "Sonos Arc", "Sonos Arc", "Studio"])
        settle(s, ["Basement", "Sonos Arc", "Sonos Arc", "Studio"])
        XCTAssertNil(cursorSpeaker(s), "a name shared by two speakers re-enabled one of them")
        assertKeysActOnNothing(s)
    }

    func testAFailedReadNeitherCreatesNorClearsTheHold() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        // A failed read keeps the last list, and the highlight stays live on Sonos Arc.
        h.next(nil, fail: true)
        XCTAssertTrue(tickUntil(s) { self.screen(s).contains("speaker list unavailable") })
        XCTAssertEqual(cursorSpeaker(s), "Sonos Arc")
        // It vanishes, then a read fails: still held.
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        h.next(nil, fail: true)
        XCTAssertTrue(tickUntil(s) { self.screen(s).contains("speaker list unavailable") })
        XCTAssertNil(cursorSpeaker(s))
        assertKeysActOnNothing(s)
    }

    /// With no SpanDAC on this Mac the stand-in is row 1, where the highlight
    /// starts. It is still a visible highlight, and Enter there inside the load
    /// window used to toggle the first speaker (Codex round 2, 503eddd2): it is
    /// held like any other, and the first Down lands on the first speaker.
    func testFirstOpenWithTheHighlightWhereTheTabStartsHoldsTheStandIn() {
        let h = Harness(["Basement", "Sonos Arc"], holdFirst: true)
        let s = makeOutputTabScene(dir: dir, mode: .musicApp, spandac: nil,
                                   macReply: { throw SourceAppError.notRunning }, data: .none,
                                   starter: FakeMacStarter(installed: false),
                                   fetchSpeakers: { try h.read() }, fetchNow: { h.now })
        defer { h.release.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(h.started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(tickUntil(s) { s.cursorRowForTest == .musicApp }, "\(s.displayRowsForTest)")
        h.release.signal()
        settle(s, ["Basement", "Sonos Arc"])
        XCTAssertEqual(s.cursorRowForTest, .held(musicTUIOutputName), "\(s.displayRowsForTest)")
        assertKeysActOnNothing(s)
        XCTAssertTrue(screen(s).contains("speakers listed"), screen(s))
        XCTAssertEqual(s.handle(.down), .redraw)
        XCTAssertEqual(cursorSpeaker(s), "Basement")
    }

    func testAStandInThatReturnsTakesTheHighlightBack() {
        let h = Harness(["Basement"], holdFirst: true)
        let s = make(h)
        defer { h.release.signal() }
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(h.started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(moveTo(s, .musicApp))
        h.release.signal()
        settle(s, ["Basement"])
        h.next([])
        settle(s, [])
        XCTAssertEqual(s.cursorRowForTest, .musicApp)
    }

    // MARK: - Names more than one speaker shares (Codex round 2, 503eddd2)

    private func moveUpToSpeaker(_ s: SpeakersScene, _ name: String) -> Bool {
        for _ in 0..<60 {
            if cursorSpeaker(s) == name { return true }
            _ = s.handle(.up)
        }
        return cursorSpeaker(s) == name
    }

    func testANameThatBecomesSharedHoldsTheHighlight() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        h.next(["Sonos Arc", "Basement", "Sonos Arc", "Studio"])   // which one is it now?
        settle(s, ["Sonos Arc", "Basement", "Sonos Arc", "Studio"])
        XCTAssertNil(cursorSpeaker(s), "the highlight picked one of two speakers by name")
        assertKeysActOnNothing(s)
    }

    func testASharedNameThatBecomesOneHoldsTheHighlightAndStaysHeld() {
        let h = Harness(["Sonos Arc", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Sonos Arc", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        _ = s.handle(.down)                                        // the second Sonos Arc
        XCTAssertEqual(s.cursorRowForTest, .speaker(1))
        h.next(["Sonos Arc", "Studio"])                            // one left: not provably ours
        settle(s, ["Sonos Arc", "Studio"])
        XCTAssertNil(cursorSpeaker(s), "the highlight moved onto a speaker that may be the other one")
        assertKeysActOnNothing(s)
        reread(s, h, ["Sonos Arc", "Studio"])                     // still one, still not provably ours
        XCTAssertNil(cursorSpeaker(s), "a once-shared name re-armed the highlight by name alone")
        assertKeysActOnNothing(s)
    }

    /// Codex round 3 (902eb0d7): held while absent, then two by that name,
    /// then one: the one left may be the other device, so it stays held.
    func testANameThatBecomesSharedWhileHeldStaysHeldWhenOneRemains() {
        let h = Harness(["Basement", "Kitchen", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Kitchen", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Kitchen"))
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        XCTAssertEqual(s.cursorRowForTest, .held("Kitchen"))
        h.next(["Basement", "Kitchen", "Kitchen", "Studio"])
        settle(s, ["Basement", "Kitchen", "Kitchen", "Studio"])
        XCTAssertEqual(s.cursorRowForTest, .held("Kitchen"))
        assertKeysActOnNothing(s)
        h.next(["Basement", "Kitchen", "Studio"])
        settle(s, ["Basement", "Kitchen", "Studio"])
        XCTAssertEqual(s.cursorRowForTest, .held("Kitchen"), "one of two Kitchens re-armed the highlight by name")
        assertKeysActOnNothing(s)
    }

    /// Proves the ROW is kept across an unchanged list, not the device: Music
    /// addresses speakers by name, so two sharing a name cannot be told apart
    /// by MusicTUI at all (a residual put to Anthony, Codex round 3 902eb0d7).
    func testAnUnchangedListKeepsTheHighlightOnTheSameOfTwoSpeakersSharingAName() {
        let h = Harness(["HomePod", "HomePod", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["HomePod", "HomePod", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "HomePod"))
        _ = s.handle(.down)
        XCTAssertEqual(s.cursorRowForTest, .speaker(1))
        reread(s, h, ["HomePod", "HomePod", "Studio"])            // an ordinary refresh, nothing moved
        XCTAssertEqual(s.cursorRowForTest, .speaker(1), "a refresh moved or held the highlight")
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertEqual(s.speakerRowsForTest.map(\.active), [false, true, false], "Enter acted on the other HomePod")
    }

    // MARK: - The EQ picker

    func testClosingTheEQPickerWithEscapeKeepsTheHeldRow() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveTo(s, .eq))
        _ = s.handle(.enter)                                       // open the picker
        XCTAssertTrue(s.displayRowsForTest.contains { if case .preset = $0 { return true }; return false })
        XCTAssertTrue(moveUpToSpeaker(s, "Sonos Arc"))
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        XCTAssertNil(cursorSpeaker(s))
        XCTAssertEqual(s.handle(.escape), .redraw)                 // closes the picker, stays on the tab
        XCTAssertEqual(s.cursorRowForTest, .held("Sonos Arc"))
        assertKeysActOnNothing(s)
    }

    // MARK: - What the person sees

    private func screen(_ s: SpeakersScene, width: Int = 100, height: Int = 30) -> String {
        let frame = shellLayout(width: width, height: height)
        return screenText(s.render(frame: frame, snapshot: outputTabSnapshot()), width: width, height: height)
            .joined(separator: "\n")
    }

    func testTheHeldRowNamesTheGoneSpeakerAndTheFooterOffersNoEnterOrVolume() {
        let h = Harness(["Basement", "Sonos Arc", "Studio"])
        let s = make(h)
        _ = s.tick(snapshot: outputTabSnapshot())
        settle(s, ["Basement", "Sonos Arc", "Studio"])
        XCTAssertTrue(moveToSpeaker(s, "Sonos Arc"))
        h.next(["Basement", "Studio"])
        settle(s, ["Basement", "Studio"])
        let text = screen(s)
        XCTAssertTrue(text.contains("Sonos Arc"), "the gone speaker vanished from under the highlight:\n\(text)")
        XCTAssertTrue(text.contains("gone"), "the held row does not say the speaker went away:\n\(text)")
        XCTAssertFalse(s.footerHint.contains("Enter"), s.footerHint)
        XCTAssertFalse(s.footerHint.contains("Volume"), s.footerHint)
    }
}
