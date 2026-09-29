// tools/music/Tests/MusicTests/StickyWontPlayMessageTests.swift
import XCTest
@testable import music

/// A footer message that means something will not play stays until the next
/// state change; a transient status still expires. Every clock here is
/// injected: nothing sleeps, nothing plays, nothing reads the network.
final class StickyWontPlayMessageTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testASkipNoticeStaysUntilTheNextTrackChange() {
        let status = StatusStore()
        status.observe(track: "old song", now: t0)
        status.post("Playing 'Album' on SpanDAC \u{2014} 11 tracks. 1 song isn't available to SpanDAC.",
                    untilStateChange: true, now: t0)
        // The play's own first song arrives a moment after the notice.
        status.observe(track: "first song", now: at(2))
        XCTAssertNotNil(status.current(now: at(2)), "the play's own start is not the next track change")
        // Long after any transient would have expired, on the same song.
        status.observe(track: "first song", now: at(200))
        XCTAssertEqual(status.current(now: at(200))?.text,
                       "Playing 'Album' on SpanDAC \u{2014} 11 tracks. 1 song isn't available to SpanDAC.")
        // A poll that reports nothing is not a track change.
        status.observe(track: nil, now: at(201))
        XCTAssertNotNil(status.current(now: at(201)))
        // The next song: gone.
        status.observe(track: "second song", now: at(240))
        XCTAssertNil(status.current(now: at(240)))
    }

    func testARefusalStaysUntilTheNextPlayAction() {
        let status = StatusStore()
        let runner = ActionRunner(status: status)
        runner.run("Play") { throw ActionError(message: "'Song' isn't available to SpanDAC.") }
        runner.waitUntilIdle()
        let refusal = status.current(now: Date().addingTimeInterval(3600))
        XCTAssertEqual(refusal?.text, "'Song' isn't available to SpanDAC.")
        XCTAssertEqual(refusal?.isError, true)
        // An action that starts nothing leaves it.
        runner.run("Volume") {}
        runner.waitUntilIdle()
        XCTAssertNotNil(status.current(now: Date().addingTimeInterval(3600)))
        // The next play clears it at the keypress, before it runs.
        let gate = DispatchSemaphore(value: 0)
        runner.run("Play") { gate.wait() }
        XCTAssertNil(status.current(now: Date().addingTimeInterval(3600)))
        gate.signal()
        runner.waitUntilIdle()
    }

    func testATransientStatusStillExpires() {
        let status = StatusStore()
        status.post("Paired with Kitchen.", now: t0)
        XCTAssertEqual(status.current(now: at(2.9))?.text, "Paired with Kitchen.")
        XCTAssertNil(status.current(now: at(3)))
        // And a transient failure of an action that starts nothing expires too.
        let runner = ActionRunner(status: status)
        runner.run("Volume") { throw ActionError(message: "Volume isn't available on SpanDAC.") }
        runner.waitUntilIdle()
        XCTAssertEqual(status.current()?.text, "Volume isn't available on SpanDAC.")
        XCTAssertNil(status.current(now: Date().addingTimeInterval(3600)))
    }

    func testANewMessageReplacesAStickyOne() {
        let status = StatusStore()
        status.post("None of those songs are available to SpanDAC.", error: true, untilStateChange: true, now: t0)
        status.post("Recorded 2 plays.", ttl: 4, now: at(10))
        XCTAssertEqual(status.current(now: at(11))?.text, "Recorded 2 plays.")
        XCTAssertNil(status.current(now: at(14)), "the replacement keeps its own short life")
    }

    func testAnOutputSwitchClearsAStickyMessage() {
        let lock = NSLock()
        var stamp = StatusSwitchStamp(epoch: 0, dataEpoch: 0)
        let status = StatusStore(switchStamp: { lock.lock(); defer { lock.unlock() }; return stamp })
        status.post("Pick a SpanDAC on the Output tab.", error: true, untilStateChange: true, now: t0)
        XCTAssertNotNil(status.current(now: at(600)))
        lock.lock(); stamp = StatusSwitchStamp(epoch: 1, dataEpoch: 0); lock.unlock()
        XCTAssertNil(status.current(now: at(601)))
    }

    func testADataSourceSwitchClearsAStickyMessage() {
        let lock = NSLock()
        var stamp = StatusSwitchStamp(epoch: 3, dataEpoch: 0)
        let status = StatusStore(switchStamp: { lock.lock(); defer { lock.unlock() }; return stamp })
        status.post("'Song' isn't available to SpanDAC.", error: true, untilStateChange: true, now: t0)
        lock.lock(); stamp = StatusSwitchStamp(epoch: 3, dataEpoch: 1); lock.unlock()
        XCTAssertNil(status.current(now: at(1)))
    }

    func testAMessagePostedAfterASwitchSurvivesThatSwitch() {
        // A refusal that lands after the switch it reports is news, not stale.
        let lock = NSLock()
        var stamp = StatusSwitchStamp(epoch: 0, dataEpoch: 0)
        let status = StatusStore(switchStamp: { lock.lock(); defer { lock.unlock() }; return stamp })
        lock.lock(); stamp = StatusSwitchStamp(epoch: 0, dataEpoch: 1); lock.unlock()
        status.post("SpanDAC could not be left.", error: true, untilStateChange: true, now: t0)
        XCTAssertNotNil(status.current(now: at(600)))
    }

    func testAStateChangeClearsOnlyAStickyMessage() {
        let status = StatusStore()
        status.post("'Song' isn't available to SpanDAC.", error: true, untilStateChange: true, now: t0)
        status.stateChanged()
        XCTAssertNil(status.current(now: at(1)))
        status.post("Paired with Kitchen.", now: t0)
        status.stateChanged()
        XCTAssertEqual(status.current(now: at(1))?.text, "Paired with Kitchen.")
    }

    func testARefusedSwitchStaysButAFailedFavoriteDoesNot() {
        let status = StatusStore()
        let runner = ActionRunner(status: status)
        runner.run("Output") { throw ActionError(message: "SpanDAC isn't ready yet.") }
        runner.waitUntilIdle()
        XCTAssertEqual(status.current(now: Date().addingTimeInterval(3600))?.text, "SpanDAC isn't ready yet.")
        runner.run("Favorite") { throw ActionError(message: "Couldn't favorite that.") }
        runner.waitUntilIdle()
        XCTAssertNil(status.current(now: Date().addingTimeInterval(3600)))
    }

    func testATrackKeyIgnoresAnEmptyPoll() {
        XCTAssertNil(statusTrackKey(NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])))
        var np = NowPlayingState(); np.track = "Song"; np.artist = "Artist"
        XCTAssertNotNil(statusTrackKey(NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: [])))
        var bridged = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])
        bridged.bridge = .empty
        XCTAssertNil(statusTrackKey(bridged))
        bridged.bridge?.title = "Song"
        XCTAssertNotNil(statusTrackKey(bridged))
    }
}
