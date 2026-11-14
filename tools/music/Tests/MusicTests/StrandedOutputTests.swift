// tools/music/Tests/MusicTests/StrandedOutputTests.swift
//
// An iPhone or iPad SpanDAC that cannot be reached must not strand the Output
// tab. Enter on another output refuses and the tab ASKS "Can't reach <device>.
// It may still be playing. Leave it and use <target>?"; y leaves, n or Esc
// stays. Only for a SpanDAC on the network; the Mac's own SpanDAC keeps the
// strict rule. Injected fakes only: no socket, no keychain, no ~/.config/music.
import XCTest
@testable import music

final class StrandedOutputTests: XCTestCase {

    private let ipad = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"
    private let other = "6B1F3C2E-8D4A-4F0B-9C7E-2A5D1E0F3B91"
    private let third = "A1B2C3D4-0000-4000-8000-000000000003"
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "stranded-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        chmod(dir, 0o755)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private enum Device { case noAnswer(SpanDACLinkFailure), playing, paused }

    /// What the outgoing device does, changeable between presses.
    private final class Wire {
        private let lock = NSLock()
        private var _device: Device = .noAnswer(.noAnswer)
        private var _stop: Device?
        private var _hold = false
        private var _macDown = false
        private var _macReply: String?
        var device: Device { get { lock.lock(); defer { lock.unlock() }; return _device }
                             set { lock.lock(); _device = newValue; lock.unlock() } }
        /// When set, `slice.stop` answers this (a refusal, unless silent) instead of `device`.
        var stopAnswer: Device? { get { lock.lock(); defer { lock.unlock() }; return _stop }
                                  set { lock.lock(); _stop = newValue; lock.unlock() } }
        /// While true every request to the iPhone waits: a response in flight.
        var hold: Bool { get { lock.lock(); defer { lock.unlock() }; return _hold }
                         set { lock.lock(); _hold = newValue; lock.unlock() } }
        var macDown: Bool { get { lock.lock(); defer { lock.unlock() }; return _macDown }
                            set { lock.lock(); _macDown = newValue; lock.unlock() } }
        var macReply: String? { get { lock.lock(); defer { lock.unlock() }; return _macReply }
                                set { lock.lock(); _macReply = newValue; lock.unlock() } }
    }

    private final class Finished {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func bump() { lock.lock(); _count += 1; lock.unlock() }
    }

    private func reply(_ playback: String) -> String {
        #"{"ok":true,"status":{"playback":"\#(playback)","authorization":"authorized","contract":3,"capabilities":[]}}"#
    }

    private func respond(_ d: Device) throws -> String {
        switch d {
        case .noAnswer(let why): throw SourceAppError.link(why)
        case .playing: return reply("playing")
        case .paused: return reply("paused")
        }
    }

    private var fake: FakeSpanDACOutputs!

    private func rig(mode: PlaybackMode, wire: Wire, phone: String = "iPhone",
                     speakers: Int = 0) -> (SpeakersScene, StatusStore, Finished) {
        let status = StatusStore()
        fake = FakeSpanDACOutputs([spandacRow(ipad, phone, .ready), spandacRow(other, "Kitchen iPad", .ready),
                                   spandacRow(third, "New iPad", .notPaired(pairable: true), paired: false)])
        let s = makeOutputTabScene(
            dir: dir, mode: mode, spandac: fake,
            speakers: (0..<speakers).map { ["name": "Speaker \($0)", "selected": false, "volume": 50] },
            status: status,
            macReply: { [self] in
                if wire.macDown { throw SourceAppError.notRunning }
                return wire.macReply ?? reply("idle")
            },
            network: { [self] id in
                SourceAppClient(path: "/fake", transport: { [self] _, line in
                    if id != ipad { return reply("paused") }
                    while wire.hold { usleep(1_000) }
                    if line.contains("slice.stop"), let stop = wire.stopAnswer {
                        if case .noAnswer = stop { return try respond(stop) }
                        return #"{"ok":false,"error":"nope","detail":"stop refused"}"#
                    }
                    return try respond(wire.device)
                })
            },
            outputLock: OutputLock(path: dir + "/mode.json.lock"))
        settleOutputTab(s, speakers: speakers)
        let finished = Finished()
        s.selectModeFinishedForTest = { finished.bump() }
        return (s, status, finished)
    }

    private func wait(_ finished: Finished, count: Int) {
        let deadline = Date().addingTimeInterval(10)
        while finished.count < count && Date() < deadline { usleep(5_000) }
        XCTAssertGreaterThanOrEqual(finished.count, count, "the switch never finished")
    }

    private func move(_ s: SpeakersScene, to row: OutputTabRow) {
        _ = s.handle(.home)
        guard let i = s.displayRowsForTest.firstIndex(of: row) else { return XCTFail("no row \(row)") }
        for _ in 0..<i { _ = s.handle(.down) }
    }

    /// Enter on a row, and the wait for its switch attempt to finish.
    private func enter(_ s: SpeakersScene, on row: OutputTabRow, _ finished: Finished) {
        let before = finished.count
        move(s, to: row)
        _ = s.handle(.enter)
        wait(finished, count: before + 1)
    }

    /// Main-loop ticks until the condition holds (the inbox drains in `tick`).
    @discardableResult
    private func tick(_ s: SpeakersScene, until condition: () -> Bool = { true }) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            _ = s.tick(snapshot: outputTabSnapshot())
            if condition() { return true }
            usleep(5_000)
        } while Date() < deadline
        return false
    }

    /// Enter on a row; the attempt finishes; the question arrives.
    private func ask(_ s: SpeakersScene, on row: OutputTabRow, _ finished: Finished) {
        enter(s, on: row, finished)
        XCTAssertTrue(tick(s) { s.askingLeaveForTest }, "the question never arrived")
    }

    private func answer(_ s: SpeakersScene, _ key: KeyPress, _ finished: Finished) {
        let before = finished.count
        _ = s.handle(key)
        wait(finished, count: before + 1)
    }

    private func mode() -> PlaybackMode { PlaybackModeStore(path: dir + "/mode.json").mode() }
    private func said(_ status: StatusStore) -> String? { status.current()?.text }
    private func screen(_ s: SpeakersScene, width: Int = 100) -> [String] {
        screenText(s.render(frame: shellLayout(width: width, height: 30), snapshot: outputTabSnapshot()),
                   width: width, height: 30)
    }

    private let today = "Couldn't confirm SpanDAC paused; still using it"
    private let strictMac = "Couldn't confirm SpanDAC on this Mac paused; still using it"
    private let reminder = "Now using SpanDAC on Kitchen iPad. SpanDAC on iPhone may still be playing."
    private let keys = "y Yes  n No"

    // MARK: - The question

    func testASilentNetworkOutputAsksInsteadOfSwitchingOrToasting() {
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: Wire())
        let epoch = s.routingForTest.epoch
        ask(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(s.routingForTest.epoch, epoch)
        XCTAssertNil(status.current(), "a toast would claim something the question does not")
        XCTAssertEqual(s.footerHint, keys)
        let shown = screen(s).joined(separator: " ").split(separator: " ").joined(separator: " ")
        XCTAssertTrue(shown.contains("Can't reach iPhone. It may still be playing. Leave it and use Kitchen iPad? y Yes n No"), shown)
    }

    func testYLeavesAndTheStatusLineKeepsTheReminder() {
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: Wire())
        let epoch = s.routingForTest.epoch
        ask(s, on: .spandac(other), finished)
        answer(s, .char("y"), finished)
        XCTAssertEqual(mode(), .networkSource(other))
        XCTAssertEqual(s.routingForTest.epoch, epoch + 1)
        XCTAssertEqual(said(status), reminder)
        XCTAssertFalse(s.askingLeaveForTest)
    }

    func testNAndEscapeStayAndCloseTheQuestion() {
        for key in [KeyPress.char("n"), .char("N"), .escape] {
            let (s, _, finished) = rig(mode: .networkSource(ipad), wire: Wire())
            ask(s, on: .spandac(other), finished)
            let before = finished.count
            XCTAssertEqual(s.handle(key), .redraw)
            XCTAssertFalse(s.askingLeaveForTest)
            XCTAssertEqual(finished.count, before, "no switch attempt")
            XCTAssertEqual(mode(), .networkSource(ipad))
        }
    }

    func testEveryOtherKeyIsIgnoredWhileAsking() {
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: Wire())
        ask(s, on: .spandac(other), finished)
        let before = finished.count
        for key in [KeyPress.enter, .down, .up, .char("e"), .space] {
            XCTAssertEqual(s.handle(key), .none, "\(key)")
        }
        XCTAssertTrue(s.askingLeaveForTest)
        XCTAssertEqual(finished.count, before)
        XCTAssertEqual(mode(), .networkSource(ipad))
    }

    func testTwoQueuedEntersNeverSwitchWithoutAY() {
        let wire = Wire()
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        wire.hold = true
        move(s, to: .spandac(other))
        _ = s.handle(.enter)
        _ = s.handle(.enter)
        wire.hold = false
        wait(finished, count: 2)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertTrue(tick(s) { s.askingLeaveForTest })
    }

    func testAKeyPressedWhileTheFirstAttemptIsPendingDropsItsQuestion() {
        let wire = Wire()
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        wire.hold = true
        move(s, to: .spandac(other))
        _ = s.handle(.enter)
        _ = s.handle(.char("z"))
        wire.hold = false
        wait(finished, count: 1)
        tick(s)
        XCTAssertFalse(s.askingLeaveForTest, "the person did something since that Enter")
        XCTAssertEqual(mode(), .networkSource(ipad))
    }

    func testALeaveAndReEntryBeforeTheReplyDropsTheQuestion() {
        let wire = Wire()
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        wire.hold = true
        move(s, to: .spandac(other))
        _ = s.handle(.enter)
        s.resignedActive()
        s.becameActive()
        wire.hold = false
        wait(finished, count: 1)
        tick(s)
        XCTAssertFalse(s.askingLeaveForTest, "a different visit to the tab")
        XCTAssertEqual(mode(), .networkSource(ipad))
    }

    func testTheQuestionStaysInViewWithTheCursorOnTheBottomRow() {
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: Wire(), speakers: 8)
        ask(s, on: .speaker(7), finished)
        let frame = shellLayout(width: 100, height: 14)
        let lines = screenText(s.render(frame: frame, snapshot: outputTabSnapshot()), width: 100, height: 14)
        let shown = lines.joined(separator: " ").split(separator: " ").joined(separator: " ")
        XCTAssertTrue(shown.contains("may still be playing"), lines.joined(separator: "\n"))
        XCTAssertTrue(shown.contains("y Yes n No"), lines.joined(separator: "\n"))
    }

    func testAQuestionForATabThatIsNoLongerShowingIsDropped() {
        let wire = Wire()
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        wire.hold = true
        move(s, to: .spandac(other))
        _ = s.handle(.enter)
        s.resignedActive()
        wire.hold = false
        wait(finished, count: 1)
        tick(s)
        XCTAssertFalse(s.askingLeaveForTest)
    }

    // MARK: - The y attempt is strict about anything that changed

    func testAnEpochChangeBetweenTheQuestionAndYIsTheStrictResult() throws {
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: Wire())
        ask(s, on: .spandac(other), finished)
        // Away and back: the same mode, two epochs later.
        _ = try s.routingForTest.switchMode(to: .networkSource(other), readiness: { .ready },
                                            pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = try s.routingForTest.switchMode(to: .networkSource(ipad), readiness: { .ready },
                                            pauseOutgoing: { _ in true }, dropQueue: { _ in })
        answer(s, .char("y"), finished)
        XCTAssertEqual(mode(), .networkSource(ipad), "no unconfirmed leave")
        XCTAssertNotEqual(said(status), reminder)
    }

    func testAModeChangedByAnotherProcessBetweenTheQuestionAndYDoesNotLeave() {
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: Wire())
        ask(s, on: .spandac(other), finished)
        PlaybackModeStore(path: dir + "/mode.json").set(.musicApp)
        answer(s, .char("y"), finished)
        XCTAssertEqual(said(status), "Output was changed by another MusicTUI process; nothing was switched.")
        XCTAssertEqual(mode(), .musicApp, "we did not write over the other process's choice")
    }

    func testADeviceThatAnswersPlayingOnTheYAttemptIsRefusedAsToday() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        ask(s, on: .spandac(other), finished)
        wire.device = .playing
        answer(s, .char("y"), finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), today)
        XCTAssertFalse(s.askingLeaveForTest)
    }

    func testADeviceThatAnswersPausedOnTheYAttemptSwitchesNormally() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        ask(s, on: .spandac(other), finished)
        wire.device = .paused
        answer(s, .char("y"), finished)
        XCTAssertEqual(mode(), .networkSource(other))
        XCTAssertEqual(said(status), "Output: SpanDAC \u{00B7} Kitchen iPad")
    }

    // MARK: - What counts as no answer

    func testEveryNoAnswerKindAsksAndARefusalNeverDoes() {
        for why in [SpanDACLinkFailure.noAnswer, .asleep, .notFound] {
            let wire = Wire(); wire.device = .noAnswer(why)
            let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
            ask(s, on: .spandac(other), finished)
            XCTAssertEqual(mode(), .networkSource(ipad), "\(why)")
            try? FileManager.default.removeItem(atPath: dir + "/mode.json")
        }
        for why in [SpanDACLinkFailure.refused(-9858), .notPaired, .forgotten, .unsafeCipher] {
            let wire = Wire(); wire.device = .noAnswer(why)
            let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
            enter(s, on: .spandac(other), finished)
            tick(s)
            XCTAssertFalse(s.askingLeaveForTest, "\(why)")
            XCTAssertEqual(said(status), today, "\(why)")
            XCTAssertEqual(mode(), .networkSource(ipad), "\(why)")
        }
    }

    func testASilentMacSpanDACKeepsTheStrictRuleAndNeverAsks() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .source, wire: wire)
        wire.macDown = true
        enter(s, on: .spandac(other), finished)
        tick(s)
        XCTAssertFalse(s.askingLeaveForTest)
        XCTAssertEqual(mode(), .source)
        XCTAssertEqual(said(status), strictMac)
    }

    // MARK: - An unconfirmed leave

    func testASilentStopAfterASilentPauseIsIgnored() {
        let wire = Wire(); wire.stopAnswer = .noAnswer(.asleep)
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        ask(s, on: .spandac(other), finished)
        answer(s, .char("y"), finished)
        XCTAssertEqual(mode(), .networkSource(other))
    }

    func testAStopThatAnswersARefusalIsTodaysQueueRefusal() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        ask(s, on: .spandac(other), finished)
        wire.stopAnswer = .paused      // any answer that is a refusal, not silence
        answer(s, .char("y"), finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), "Couldn't clear SpanDAC's queue; still using it")
    }

    func testASaveFailureAfterAnUnconfirmedLeaveDoesNotClaimTheQueueWasCleared() {
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: Wire())
        ask(s, on: .spandac(other), finished)
        chmod(dir, 0o555)      // the atomic write of mode.json fails
        answer(s, .char("y"), finished)
        XCTAssertEqual(said(status),
                       "Couldn't save the playback mode; still using SpanDAC on iPhone, which could not be reached.")
        XCTAssertEqual(mode(), .networkSource(ipad))
    }

    func testLeavingForMusicTUIKeepsBothTheReminderAndTheMacSoundNotice() {
        let wire = Wire()
        wire.macReply = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[],"output":{"dac":"connected","name":"SSL 2+"}}}"#
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        ask(s, on: .musicApp, finished)
        answer(s, .char("y"), finished)
        XCTAssertEqual(mode(), .musicApp)
        XCTAssertEqual(said(status), "Now using \(musicTUIOutputName). SpanDAC on iPhone may still be playing. "
                       + "Mac sound still on DAC; check Sound settings (SSL 2+).")
    }

    // MARK: - Drawn at the narrowest width, wrapped, nothing cut

    func testTheQuestionWrapsAtANarrowWidthKeepingTheRiskAndTheKeys() {
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: Wire(),
                                   phone: "Anthony's long-named iPhone 17 Pro Max in the studio")
        ask(s, on: .spandac(other), finished)
        let lines = screen(s, width: 40)
        let shown = lines.joined(separator: " ").split(separator: " ").joined(separator: " ")
        XCTAssertTrue(shown.contains("may still be playing"), lines.joined(separator: "\n"))
        XCTAssertTrue(shown.contains("y Yes n No"), lines.joined(separator: "\n"))
        XCTAssertTrue(shown.contains("Kitchen iPad?"), lines.joined(separator: "\n"))
    }
}
