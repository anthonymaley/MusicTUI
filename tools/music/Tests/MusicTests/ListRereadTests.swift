import XCTest
@testable import music

/// `LibraryCoverFetcher.ListReread` on its own, read off a plain `Date`: no scene, no threads.
final class ListRereadTests: XCTestCase {
    private typealias Reread = LibraryCoverFetcher.ListReread
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let applied = LibraryCoverFetcher.StaleList(generation: 1, libraryInstance: "A")

    private func due(_ r: Reread, _ t: TimeInterval) -> Reread.Due {
        r.due(applied: applied, staleRefusal: nil, readyInstance: "B", now: t0.addingTimeInterval(t))
    }

    func testASuccessfulReadIsNotAskedAgainWhateverItCameBackWith() {
        let r = Reread()
        let d = due(r, 0)
        XCTAssertTrue(d.any)
        r.finished(r.began(d, now: t0), succeeded: true)
        XCTAssertFalse(due(r, 1).any)
        XCTAssertFalse(due(r, 100_000).any)
    }

    func testAnAttemptInFlightIsNotAskedAgainAndAReleasedOneIs() {
        let r = Reread()
        let ticket = r.began(due(r, 0), now: t0)
        XCTAssertFalse(due(r, 1).any, "in flight")
        r.release(ticket)
        XCTAssertTrue(due(r, 1).any, "nothing was attempted")
    }

    func testAFailureWaitsOutEachDelayAndIsThenSpent() {
        let r = Reread()
        var t: TimeInterval = 0
        for (i, delay) in Reread.retryDelays.enumerated() {
            r.finished(r.began(due(r, t), now: t0.addingTimeInterval(t)), succeeded: false)
            XCTAssertFalse(due(r, t).any, "stamped at \(t), attempt \(i + 1)")
            XCTAssertFalse(due(r, t + delay - 0.01).any)
            t += delay
            XCTAssertTrue(due(r, t).any, "the retry after \(delay) s")
        }
        r.finished(r.began(due(r, t), now: t0.addingTimeInterval(t)), succeeded: false)
        XCTAssertFalse(due(r, t + 1_000_000).any, "1 + \(Reread.retryDelays.count) attempts, then spent")
    }

    func testAnAttemptWhoseOutcomeNeverArrivesCountsAsAFailureAfterTheBound() {
        let r = Reread()
        _ = r.began(due(r, 0), now: t0)
        XCTAssertFalse(due(r, Reread.inFlightBound - 1).any)
        XCTAssertFalse(due(r, Reread.inFlightBound).any, "stamped as a failure: waits its first delay")
        XCTAssertTrue(due(r, Reread.inFlightBound + Reread.retryDelays[0]).any)
    }

    func testAnOutcomeFromBeforeAResetChangesNothing() {
        let r = Reread()
        let old = r.began(due(r, 0), now: t0)
        r.reset()
        r.finished(old, succeeded: true)
        XCTAssertTrue(due(r, 0).any, "the old success must not mark the new list done")
        let fresh = r.began(due(r, 0), now: t0)
        r.reset()
        r.finished(fresh, succeeded: false)
        XCTAssertTrue(due(r, 0).any, "the old failure must not delay the new list")
    }

    func testAStaleAndARestartAnswerShareOneRead() {
        let r = Reread()
        let d = r.due(applied: applied, staleRefusal: applied, readyInstance: "B", now: t0)
        XCTAssertEqual(d.reasons.count, 2)
        r.finished(r.began(d, now: t0), succeeded: true)
        XCTAssertFalse(r.due(applied: applied, staleRefusal: applied, readyInstance: "B", now: t0).any)
    }
}
