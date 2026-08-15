import XCTest
@testable import music

final class AdvanceRetryGateTests: XCTestCase {
    /// The bug: auto-advance discarded the play result after step(1) had
    /// committed, so one transient failure walked the whole remaining queue.
    /// The gate retries the same track (caller rolls the step back)…
    func testFirstFailuresRetry() {
        var gate = AdvanceRetryGate(maxRetries: 3)
        XCTAssertEqual(gate.playFailed(), .retry)
        XCTAssertEqual(gate.playFailed(), .retry)
    }

    /// …and gives up after maxRetries so a permanently erroring play can't
    /// spin forever: the committed step then skips past the track.
    func testExhaustedRetriesSkip() {
        var gate = AdvanceRetryGate(maxRetries: 3)
        _ = gate.playFailed()
        _ = gate.playFailed()
        XCTAssertEqual(gate.playFailed(), .skip)
    }

    func testSkipResetsTheCounterForTheNextTrack() {
        var gate = AdvanceRetryGate(maxRetries: 2)
        _ = gate.playFailed()
        XCTAssertEqual(gate.playFailed(), .skip)
        XCTAssertEqual(gate.playFailed(), .retry)
    }

    func testSuccessResetsTheCounter() {
        var gate = AdvanceRetryGate(maxRetries: 2)
        _ = gate.playFailed()
        gate.playSucceeded()
        XCTAssertEqual(gate.playFailed(), .retry)
    }
}

final class AppQueueStepRollbackTests: XCTestCase {
    private func makeQueue() -> AppQueue {
        AppQueue(playlistName: "P", tracks: [
            TrackListEntry(index: 10, name: "A", artist: "X", isCurrent: false),
            TrackListEntry(index: 11, name: "B", artist: "X", isCurrent: false),
            TrackListEntry(index: 12, name: "C", artist: "X", isCurrent: true),
        ], currentIndex: 1)
    }

    /// step(-1) after step(1) must restore the exact prior position — the
    /// rollback both play paths use when the play attempt errors.
    func testStepRollbackRestoresPosition() {
        let store = AppQueueStore()
        store.set(makeQueue())
        XCTAssertNotNil(store.step(1))
        XCTAssertEqual(store.read()?.currentIndex, 2)
        XCTAssertNotNil(store.step(-1))
        XCTAssertEqual(store.read()?.currentIndex, 1)
    }
}
