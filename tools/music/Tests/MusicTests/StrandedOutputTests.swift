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
        private var _macDown = false
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

    private func rig(mode: PlaybackMode, wire: Wire) -> (SpeakersScene, StatusStore, Finished) {
        let status = StatusStore()
        let fake = FakeSpanDACOutputs([spandacRow(ipad, "iPhone", .ready), spandacRow(other, "Kitchen iPad", .ready)])
        let s = makeOutputTabScene(
            dir: dir, mode: mode, spandac: fake, status: status,
            macReply: { if wire.macDown { throw SourceAppError.notRunning }; return self.reply("idle") },
            network: { [self] id in
                guard id == ipad else { return SourceAppClient(path: "/fake", transport: { _, _ in reply("idle") }) }
                return SourceAppClient(path: "/fake", transport: { _, _ in
                    switch wire.device {
                    case .noAnswer(let why): throw SourceAppError.link(why)
                    case .playing: return reply("playing")
                    case .paused: return reply("paused")
                    }
                })
            })
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

    private func mode() -> PlaybackMode { PlaybackModeStore(path: dir + "/mode.json").mode() }
    private func said(_ status: StatusStore) -> String? { status.current()?.text }

    private let cantReach = "Can't reach SpanDAC on iPhone. Open it there, or press Enter again to leave it."
    private let today = "Couldn't confirm SpanDAC paused; still using it"

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
            enter(s, on: .spandac(other), finished)
            XCTAssertEqual(mode(), .networkSource(other), "\(why)")
            try? FileManager.default.removeItem(atPath: dir + "/mode.json")
        }
    }

    func testSecondEnterOnTheSameTargetLeaves() {
        let wire = Wire()
        let (s, _, finished) = rig(mode: .networkSource(ipad), wire: wire)
        let epoch = s.routingForTest.epoch
        enter(s, on: .spandac(other), finished)
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(other))
        XCTAssertEqual(s.routingForTest.epoch, epoch + 1)
    }

    func testSecondEnterOnADifferentTargetRefusesAgainAndRearmsThatTarget() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        enter(s, on: .spandacMac, finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), cantReach)
        // Armed for the Mac now, not for the first target.
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(ipad), "the first arm did not survive")
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(other))
    }

    func testADeviceThatAnswersPlayingOnTheSecondEnterIsStillRefused() {
        let wire = Wire()
        let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
        enter(s, on: .spandac(other), finished)
        wire.device = .playing
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), today)
        // The arm is spent: it does not come back when the device goes silent again.
        wire.device = .noAnswer(.noAnswer)
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .networkSource(ipad))
        XCTAssertEqual(said(status), cantReach)
    }

    func testADeviceThatAnswersARefusalNeverGetsTheLeave() {
        for why in [SpanDACLinkFailure.refused(-9858), .notPaired, .forgotten] {
            let wire = Wire(); wire.device = .noAnswer(why)
            let (s, status, finished) = rig(mode: .networkSource(ipad), wire: wire)
            enter(s, on: .spandac(other), finished)
            enter(s, on: .spandac(other), finished)
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
        XCTAssertEqual(said(status), "Couldn't confirm SpanDAC on this Mac paused; still using it")
        enter(s, on: .spandac(other), finished)
        XCTAssertEqual(mode(), .source, "never leaves on a second Enter")
        XCTAssertEqual(said(status), "Couldn't confirm SpanDAC on this Mac paused; still using it")
    }
}
