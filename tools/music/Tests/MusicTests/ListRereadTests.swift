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

    // MARK: - an expired attempt cannot touch its replacement

    /// Attempt A begins at 0 and expires at the bound; the replacement B begins once the
    /// first retry delay has passed. Returns both tickets, B's reason in flight.
    private func expiredThenReplaced(_ r: Reread) -> (a: Reread.Ticket, b: Reread.Ticket, at: TimeInterval) {
        let a = r.began(due(r, 0), now: t0)
        XCTAssertFalse(due(r, Reread.inFlightBound).any, "expiry stamps A's failure and its delay")
        let replacedAt = Reread.inFlightBound + Reread.retryDelays[0]
        let d = due(r, replacedAt)
        XCTAssertTrue(d.any, "the delay never ended")
        return (a, r.began(d, now: t0.addingTimeInterval(replacedAt)), replacedAt)
    }

    func testALateFailureFromAnExpiredAttemptDoesNotClearOrCountAgainstItsReplacement() {
        let r = Reread()
        let (a, b, at) = expiredThenReplaced(r)
        r.finished(a, succeeded: false)
        XCTAssertFalse(due(r, at + 1).any, "A's late failure cleared B's in-flight state")
        XCTAssertFalse(due(r, at + Reread.retryDelays[1] + 1).any, "A's late failure made another attempt eligible beside B")
        // B's own failure is the SECOND failure, not the third: A's was counted once, at expiry.
        r.finished(b, succeeded: false)
        let second = Reread.retryDelays[1]
        XCTAssertFalse(due(r, at + 1).any, "stamped at \(at + 1)")
        XCTAssertFalse(due(r, at + 1 + second - 0.01).any)
        XCTAssertTrue(due(r, at + 1 + second).any, "the retry after the second failure waits \(second) s")
    }

    func testALateSuccessFromAnExpiredAttemptDoesNotMarkItsReplacementDone() {
        let r = Reread()
        let (a, b, at) = expiredThenReplaced(r)
        r.finished(a, succeeded: true)
        XCTAssertFalse(due(r, at + 1).any, "B is still in flight")
        r.finished(b, succeeded: false)
        XCTAssertFalse(due(r, at + 1).any, "stamped at \(at + 1)")
        XCTAssertTrue(due(r, at + 1 + Reread.retryDelays[1]).any, "A's late success marked the reason done")
    }

    func testALateReleaseFromAnExpiredAttemptDoesNotFreeItsReplacement() {
        let r = Reread()
        let (a, b, at) = expiredThenReplaced(r)
        r.release(a)
        XCTAssertFalse(due(r, at + 1).any, "A's late release freed B's claim")
        r.finished(b, succeeded: true)
        XCTAssertFalse(due(r, at + 1_000_000).any)
    }

    func testAnExpiredAttemptIsNotActiveAndItsReplacementIs() {
        let r = Reread()
        let (a, b, _) = expiredThenReplaced(r)
        XCTAssertFalse(r.isActive(a), "an expired attempt may not post rows")
        XCTAssertTrue(r.isActive(b))
        r.finished(b, succeeded: true)
        XCTAssertFalse(r.isActive(b), "a finished attempt is over")
        let c = r.began(Reread.Due(reasons: []), now: t0)
        XCTAssertFalse(r.isActive(c), "a claim on nothing is nothing")
    }

    func testATicketFromBeforeAResetIsNotActive() {
        let r = Reread()
        let old = r.began(due(r, 0), now: t0)
        XCTAssertTrue(r.isActive(old))
        r.reset()
        XCTAssertFalse(r.isActive(old))
    }
}
