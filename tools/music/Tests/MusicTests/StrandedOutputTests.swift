// tools/music/Tests/MusicTests/StrandedOutputTests.swift
//
// An iPhone or iPad SpanDAC that cannot be reached must not strand the Output
// tab: the first Enter says so and refuses, a second Enter on the same target
// leaves it. Only for a SpanDAC on the network; the Mac's own SpanDAC keeps the
// strict rule. Injected fakes only: no socket, no keychain, no ~/.config/music.
import XCTest
@testable import music

final class StrandedOutputTests: XCTestCase {

    private let ipad = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"
    private let other = "6B1F3C2E-8D4A-4F0B-9C7E-2A5D1E0F3B91"
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "stranded-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private enum Device { case noAnswer(SpanDACLinkFailure), playing, paused }

    /// What the outgoing device (and the Mac) does, changeable between Enters.
    private final class Wire {
        private let lock = NSLock()
        private var _device: Device = .noAnswer(.noAnswer)
        private var _other: Device = .paused
        private var _stop: Device?
        private var _macDown = false
        /// The second iPad's answer (paused unless a test says otherwise).
        var otherDevice: Device { get { lock.lock(); defer { lock.unlock() }; return _other }
                                  set { lock.lock(); _other = newValue; lock.unlock() } }
        /// When set, `slice.stop` answers this instead of `device`.
        var stopAnswer: Device? { get { lock.lock(); defer { lock.unlock() }; return _stop }
                                  set { lock.lock(); _stop = newValue; lock.unlock() } }
        var device: Device { get { lock.lock(); defer { lock.unlock() }; return _device }
                             set { lock.lock(); _device = newValue; lock.unlock() } }
        var macDown: Bool { get { lock.lock(); defer { lock.unlock() }; return _macDown }
                            set { lock.lock(); _macDown = newValue; lock.unlock() } }
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

    /// A clock a test moves by hand: the wall clock plus an offset.
    private final class Offset {
        private let lock = NSLock()
        private var _seconds: TimeInterval = 0
        func advance(_ s: TimeInterval) { lock.lock(); _seconds += s; lock.unlock() }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(_seconds) }
    }

    private let third = "A1B2C3D4-0000-4000-8000-000000000003"
    private var fake: FakeSpanDACOutputs!
    private let offset = Offset()

    private func respond(_ d: Device) throws -> String {
        switch d {
        case .noAnswer(let why): throw SourceAppError.link(why)
        case .playing: return reply("playing")
        case .paused: return reply("paused")
        }
    }

    private func rig(mode: PlaybackMode, wire: Wire) -> (SpeakersScene, StatusStore, Finished) {
        let status = StatusStore()
        fake = FakeSpanDACOutputs([spandacRow(ipad, "iPhone", .ready), spandacRow(other, "Kitchen iPad", .ready),
                                   spandacRow(third, "New iPad", .notPaired(pairable: true), paired: false)])
        let offset = self.offset
        let s = makeOutputTabScene(
            dir: dir, mode: mode, spandac: fake, status: status,
            macReply: { if wire.macDown { throw SourceAppError.notRunning }; return self.reply("idle") },
            network: { [self] id in
                SourceAppClient(path: "/fake", transport: { [self] _, line in
                    if id != ipad { return try respond(wire.otherDevice) }
                    if line.contains("slice.stop"), let stop = wire.stopAnswer {
                        if case .noAnswer = stop { return try respond(stop) }
                        return #"{"ok":false,"error":"nope","detail":"stop refused"}"#
                    }
                    return try respond(wire.device)
                })
            },
            clock: { offset.now() },
            outputLock: OutputLock(path: dir + "/mode.json.lock"))
        settleOutputTab(s, speakers: 0)
        let finished = Finished()
        s.selectModeFinishedForTest = { finished.bump() }
        return (s, status, finished)
    }

    /// Enter on a row, waiting on the finished hook rather than a sleep.
    private func enter(_ s: SpeakersScene, on row: OutputTabRow, _ finished: Finished) {
        let before = finished.count
        _ = s.handle(.home)
        guard let i = s.displayRowsForTest.firstIndex(of: row) else { return XCTFail("no row \(row)") }
        for _ in 0..<i { _ = s.handle(.down) }
        _ = s.handle(.enter)
        let deadline = Date().addingTimeInterval(10)
        while finished.count == before && Date() < deadline { usleep(5_000) }
        XCTAssertGreaterThan(finished.count, before, "the switch never finished")
    }

    /// A second Enter with the cursor where it was: no move, so nothing but
    /// the press itself reaches the scene.
    private func again(_ s: SpeakersScene, _ finished: Finished) {
        let before = finished.count
        _ = s.handle(.enter)
        let deadline = Date().addingTimeInterval(10)
        while finished.count == before && Date() < deadline { usleep(5_000) }
        XCTAssertGreaterThan(finished.count, before, "the switch never finished")
    }

    private func mode() -> PlaybackMode { PlaybackModeStore(path: dir + "/mode.json").mode() }
    private func said(_ status: StatusStore) -> String? { status.current()?.text }

    private let cantReach = "Can't reach iPhone; it may still play. Enter again to leave it."

    private let today = "Couldn't confirm SpanDAC paused; still using it"
    private let strictMac = "Couldn't confirm SpanDAC on this Mac paused; still using it"

    func testUnreachableNetworkOutputFirstEnterRefusesAndSaysSo() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        let epoch = s.routingForTest.epoch
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(s.routingForTest.epoch, epoch)
        XCTAssertEqual(said(status), cantReach)
    }

    func testEveryNoAnswerFailureOffersTheSameLeave() {
        for why in [SpanDACLinkFailure.noAnswer, .asleep, .notFound] {
            let wire = Wire(); wire.device = .noAnswer(why)
            let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
            enter(s, on: .spandac(other), finished)
            XCTAssertEqual(said(status), cantReach, "\(why)")
            again(s, finished)
            XCTAssertEqual(mode(), .networkSource(other), "\(why)")
            try? FileManager.default.removeItem(atPath: dir + "/mode.json")
        }
    }

    func testSecondEnterOnTheSameTargetLeaves() {
        let wire = Wire()
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        let epoch = s.routingForTest.epoch
        enter(s, on: .spandac(other), finished)
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(other))
        XCTAssertEqual(s.routingForTest.epoch, epoch + 1)
    }

    func testAnEnterOnADifferentTargetWarnsAgainAndArmsThatTarget() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        enter(s, on: .spandacMac, finished)     // moving the cursor drops the first arm
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), cantReach)
        again(s, finished)                      // armed for the Mac now
        XCTAssertEqual(mode(), .source)
    }

    func testMovingTheSelectionDropsTheArm() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        _ = s.handle(.down); _ = s.handle(.up)
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(ipad), "a moved selection is a fresh first Enter")
        XCTAssertEqual(said(status), cantReach)
    }

    func testADeviceThatAnswersPlayingOnTheSecondEnterIsStillRefused() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        wire.device = .playing
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), today)
        // The arm is spent: it does not come back when the device goes silent again.
        wire.device = .noAnswer(.noAnswer)
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), cantReach)
    }

    func testADeviceThatAnswersARefusalNeverGetsTheLeave() {
        for why in [SpanDACLinkFailure.refused(-9858), .notPaired, .forgotten] {
            let wire = Wire(); wire.device = .noAnswer(why)
            let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
            enter(s, on: .spandac(other), finished)
            again(s, finished)
            XCTAssertEqual(mode(), .networkSource(ipad), "\(why)")
            XCTAssertEqual(said(status), today, "\(why)")
        }
    }

    func testADevicePausedOnTheFirstEnterSwitchesAsToday() {
        let wire = Wire(); wire.device = .paused
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(other))
    }

    func testAnUnreachableMacSpanDACKeepsTheStrictRule() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .source, wire: wire)
        wire.macDown = true
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .source)
        XCTAssertEqual(said(status), strictMac)
        again(s, finished)
        XCTAssertEqual(mode(), .source, "never leaves on a second Enter")
        XCTAssertEqual(said(status), strictMac)
    }

    // MARK: - The arm expires with its warning

    func testAnExpiredArmWarnsAgainAndDoesNotSwitch() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        offset.advance(SpeakersScene.leaveAnywayWarningSeconds + 1)
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(ipad), "a late Enter is a fresh first Enter")
        XCTAssertEqual(said(status), cantReach)
        again(s, finished)                      // and that warning re-armed it
        XCTAssertEqual(mode(), .networkSource(other))
    }

    func testAStaleOnlyIfEpochReturnDropsTheArm() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        // A pairing started at epoch e0 ...
        _ = s.handle(.home)
        guard let third = s.displayRowsForTest.firstIndex(of: .spandac(self.third)) else { return XCTFail("no row") }
        for _ in 0..<third { _ = s.handle(.down) }
        _ = s.handle(.enter)
        XCTAssertEqual(fake.pairCalls, [self.third])
        // ... a switch moves the epoch (the iPhone is paused) ...
        wire.device = .paused
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(other))
        // ... the Kitchen iPad goes silent and a warning arms a leave ...
        wire.otherDevice = .noAnswer(.noAnswer)
        enter(s, on: .spandac(ipad), finished)
        XCTAssertEqual(said(status), "Can't reach Kitchen iPad; it may still play. Enter again to leave it.")
        // ... and the stale pairing result returns through the early-return path.
        let before = finished.count
        fake.onPairedAndReady?(self.third, "New iPad")
        let deadline = Date().addingTimeInterval(10)
        while finished.count == before && Date() < deadline { usleep(5_000) }
        XCTAssertTrue(said(status)?.hasPrefix("Paired with New iPad") == true, said(status) ?? "nil")
        wire.device = .paused
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(other), "the stale return dropped the arm")
    }

    func testAnEpochChangeBetweenTheEntersDropsTheArm() throws {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        // Away and back: the same mode, two epochs later.
        _ = try s.routingForTest.switchMode(to: .networkSource(other), readiness: { .ready },
                                            pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = try s.routingForTest.switchMode(to: .networkSource(ipad), readiness: { .ready },
                                            pauseOutgoing: { _ in true }, dropQueue: { _ in })
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), cantReach)
    }

    func testAModeChangedByAnotherProcessBetweenTheEntersRefusesAndDoesNotLeave() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        PlaybackModeStore(path: dir + "/mode.json").set(.musicApp)
        again(s, finished)
        XCTAssertEqual(said(status), "Output was changed by another MusicTUI process; nothing was switched.")
        XCTAssertEqual(mode(), .musicApp, "we did not write over the other process's choice")
    }

    // MARK: - An unconfirmed leave

    func testStopAnsweringARefusalAfterASilentPauseIsTodaysQueueRefusal() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        wire.stopAnswer = .paused      // any answer that is a refusal, not silence
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), "Couldn't clear SpanDAC's queue; still using it")
    }

    func testASilentStopAfterASilentPauseIsIgnored() {
        let wire = Wire(); wire.stopAnswer = .noAnswer(.asleep)
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        again(s, finished)
        XCTAssertEqual(mode(), .networkSource(other))
    }

    func testAnUnconfirmedLeaveKeepsTheReminderOnTheStatusLine() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        again(s, finished)
        XCTAssertEqual(said(status), "Now using SpanDAC on Kitchen iPad. SpanDAC on iPhone may still be playing.")
    }

    func testAConfirmedSwitchKeepsTheNormalLine() {
        let wire = Wire(); wire.device = .paused
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(said(status), "Output: SpanDAC \u{00B7} Kitchen iPad")
    }

    func testASaveFailureAfterAnUnconfirmedLeaveDoesNotClaimTheQueueWasCleared() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        // The directory goes read-only: the atomic write of mode.json fails.
        chmod(dir, 0o555)
        defer { chmod(dir, 0o755) }
        again(s, finished)
        XCTAssertEqual(said(status),
                       "Couldn't save the playback mode; still using SpanDAC on iPhone, which could not be reached.")
        XCTAssertEqual(mode(), .networkSource(ipad))
    }

    /// The footer cuts a status line at the terminal width less four and never
    /// wraps (Shell.swift), so the whole warning, its instruction included,
    /// must fit an 80-column terminal even with a long device name.
    func testTheWarningFitsAnEightyColumnFooter() {
        let longName = "Anthony's iPhone"
        let warning = cantReach.replacingOccurrences(of: "iPhone", with: longName)
        XCTAssertTrue(warning.hasSuffix("Enter again to leave it."))
        XCTAssertLessThanOrEqual(warning.count, 80 - 4)
    }
}
