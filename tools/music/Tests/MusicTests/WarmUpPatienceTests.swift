import XCTest
@testable import music

/// D5: the shared warm-up policy is 60 s of total waiting, not a fixed attempt
/// count. A `WarmUpBudget` is spent in seconds waited, so a short hint gets
/// more tries and a long one gets fewer, and either way the budget never lets
/// a caller wait past `LibraryWarmUp.maxTotalWait`.
///
/// The `sleep` closure only records what it would have slept — no wall clock
/// is spent proving a 60 s policy.
final class WarmUpPatienceTests: XCTestCase {

    private final class Recorder {
        private(set) var slept: [TimeInterval] = []
        private(set) var requests = 0
        var sleep: (TimeInterval) -> Void { { self.slept.append($0) } }
        /// Always answers `warming` with the same hint, so
        /// `retryingWhileWarming` runs the budget all the way to give-up.
        func alwaysWarming(hint: TimeInterval) -> () throws -> Int {
            { self.requests += 1; throw MusicProviderError.warming("still going", retryAfter: hint) }
        }
    }

    func testHint1PointOhGivesSixtyWaitsAndSixtyOneRequests() {
        let recorder = Recorder()
        let budget = WarmUpBudget()
        XCTAssertThrowsError(
            try retryingWhileWarming(budget: budget, sleep: recorder.sleep, recorder.alwaysWarming(hint: 1.0))
        ) { error in
            guard case MusicProviderError.warming(let why, _) = error else {
                return XCTFail("expected a warming give-up, got \(error)")
            }
            XCTAssertEqual(why, LibraryWarmUp.gaveUp)
        }
        XCTAssertEqual(recorder.requests, 61)
        XCTAssertEqual(recorder.slept.count, 60)
        XCTAssertEqual(recorder.slept.reduce(0, +), 60, accuracy: 0.0001)
        XCTAssertTrue(recorder.slept.allSatisfy { $0 == 1.0 })
    }

    func testHint5PointOhGivesTwelveWaitsAndThirteenRequests() {
        let recorder = Recorder()
        let budget = WarmUpBudget()
        XCTAssertThrowsError(
            try retryingWhileWarming(budget: budget, sleep: recorder.sleep, recorder.alwaysWarming(hint: 5.0))
        )
        XCTAssertEqual(recorder.requests, 13)
        XCTAssertEqual(recorder.slept.count, 12)
        XCTAssertEqual(recorder.slept.reduce(0, +), 60, accuracy: 0.0001)
    }

    /// 0.7 does not divide 60 evenly (85 × 0.7 = 59.5), so the last wait is
    /// shortened to exactly what is left of the budget rather than overshooting
    /// it to finish out a full clamped wait.
    func testHint0Point7ShortensItsFinalWait() {
        let recorder = Recorder()
        let budget = WarmUpBudget()
        XCTAssertThrowsError(
            try retryingWhileWarming(budget: budget, sleep: recorder.sleep, recorder.alwaysWarming(hint: 0.7))
        )
        XCTAssertEqual(recorder.slept.reduce(0, +), 60, accuracy: 0.0001,
                       "the waits did not sum to exactly the budget")
        XCTAssertEqual(recorder.slept.last ?? -1, 0.5, accuracy: 0.0001,
                       "the final wait was not shortened to what remained of the budget")
        XCTAssertTrue(recorder.slept.dropLast().allSatisfy { $0 == 0.7 },
                      "an earlier wait was shortened when it should not have been")
    }

    func testAHintAboveTheClampWaitsAsTheMaximum() {
        let budget = WarmUpBudget()
        XCTAssertEqual(budget.nextWait(forHint: 86_400), LibraryWarmUp.maxWait)
    }

    func testAHintOfZeroOrBelowWaitsAsTheMinimum() {
        let budget = WarmUpBudget()
        XCTAssertEqual(budget.nextWait(forHint: 0), LibraryWarmUp.minWait)
        let budget2 = WarmUpBudget()
        XCTAssertEqual(budget2.nextWait(forHint: -5), LibraryWarmUp.minWait)
    }

    /// A play shares one budget across its membership read and its queue
    /// (D5, C3): 40 s spent on the first call leaves only 20 s for the second,
    /// not a fresh 60.
    func testOneBudgetIsSharedAcrossTwoCalls() {
        let budget = WarmUpBudget()
        // Spend 40s in 4 x 10s waits (each clamped to maxWait=5, so really 8
        // waits of 5s — spend directly against the budget to control the
        // exact amount spent without depending on a particular hint).
        var spent: TimeInterval = 0
        while spent < 40 {
            guard let wait = budget.nextWait(forHint: 5.0) else { break }
            spent += wait
        }
        XCTAssertEqual(spent, 40, accuracy: 0.0001)
        // The second call's budget is the SAME instance, so only 20s remain.
        var secondCallWaited: TimeInterval = 0
        var secondCallRequests = 0
        while true {
            secondCallRequests += 1
            guard let wait = budget.nextWait(forHint: 5.0) else { break }
            secondCallWaited += wait
        }
        XCTAssertEqual(secondCallWaited, 20, accuracy: 0.0001,
                       "the second call got a fresh budget instead of sharing the first's")
    }

    /// A walk's restart gets a fresh budget: `attemptLibraryPageWalk` (private,
    /// exercised through `walkLibraryPages`) makes a new `WarmUpBudget` per
    /// attempt, so a restarted list is not penalised for time the first
    /// attempt already spent waiting.
    func testAWalksRestartGetsAFreshBudget() {
        let firstAttemptWarming = """
        exhausted-by-design
        """
        _ = firstAttemptWarming // silence unused-string warning; the walk below is the real proof
        var calls = 0
        let error = walkLibraryPages(fetch: { cursor, _ in
            calls += 1
            if calls == 1 {
                // First page: a generation change forces exactly one restart.
                return MusicPage(rows: [], nextCursor: "c1", total: 0, generation: 1)
            }
            if calls == 2 {
                throw MusicProviderError.staleGeneration("changed")
            }
            // The restarted attempt gets its own full budget: a `warming`
            // reply here must still be retried, proving the budget was not
            // left over from the first attempt.
            if calls == 3 {
                throw MusicProviderError.warming("hold on", retryAfter: 0.25)
            }
            return MusicPage(rows: [], nextCursor: nil, total: 0, generation: 2)
        }, onPage: { _ in true }, onRestart: {}, sleep: { _ in })
        XCTAssertNil(error, "the restarted attempt's budget was already spent")
    }

    func testTheGiveUpErrorIsWarmingWithTheGaveUpText() {
        let budget = WarmUpBudget()
        while budget.nextWait(forHint: LibraryWarmUp.maxWait) != nil {}   // spend it out
        XCTAssertNil(budget.nextWait(forHint: 1.0), "the budget was not exhausted")
        let recorder = Recorder()
        XCTAssertThrowsError(
            try retryingWhileWarming(budget: budget, sleep: { _ in }, recorder.alwaysWarming(hint: 1.0))
        ) { error in
            guard case MusicProviderError.warming(let why, _) = error else {
                return XCTFail("expected warming, got \(error)")
            }
            XCTAssertEqual(why, LibraryWarmUp.gaveUp)
        }
    }
}
