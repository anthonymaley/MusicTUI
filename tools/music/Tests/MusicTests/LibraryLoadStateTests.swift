// tools/music/Tests/MusicTests/LibraryLoadStateTests.swift
//
// The bulk Library read has two failure-shaped outcomes that `[]` cannot tell
// apart: "the library really is empty" and "the read failed". Encoding both as
// an empty array let `LibraryIndexCache` cache a failure as a success, so a
// failed read rendered "(no albums)" forever and was never retried.
//
// Same shape as the two conflations already fixed this week: `currentIndex` vs
// `currentSourcePosition` (two Ints), `playlistName` vs `displayName` (two
// Strings). Here it is two STATES sharing one value. The fix is again a type.
import XCTest
@testable import music

final class LibraryLoadStateTests: XCTestCase {

    private let row = LibraryTrackRow(
        persistentID: "AAA", name: "Sexy Boy", artist: "Air",
        album: "Moon Safari", albumArtist: "Air", cloudStatus: "subscription")

    // MARK: - A failure is never cached; a warm cache never re-reads

    func testCacheDoesNotStoreAFailure() {
        let cache = LibraryIndexCache()
        XCTAssertNil(cache.rows { .failure }, "a failed read must not produce rows")
        // Second call must actually retry rather than serve a cached failure.
        var called = 0
        _ = cache.rows { called += 1; return .success([row]) }
        XCTAssertEqual(called, 1, "the failed read must not have been cached")
    }

    func testSuccessfulEmptyReadIsCached() {
        // An empty library is a real answer and SHOULD be cached.
        let cache = LibraryIndexCache()
        XCTAssertEqual(cache.rows { .success([]) }?.count, 0)
        var called = 0
        _ = cache.rows { called += 1; return .success([row]) }
        XCTAssertEqual(called, 0, "a successful empty read is a real answer and must cache")
    }

    func testWarmCacheNeverConsultsTheLoaderAgain() {
        // The Library index is read once and never invalidated, so this is what
        // makes a second read impossible - not a guard against a failing one.
        let cache = LibraryIndexCache()
        XCTAssertEqual(cache.rows { .success([row]) }?.count, 1)
        var called = 0
        XCTAssertEqual(cache.rows { called += 1; return .failure }?.count, 1)
        XCTAssertEqual(called, 0, "a warm cache must not call the loader at all")
    }

    // MARK: - Status: "empty" is reachable only from a successful read

    func testNoDataAndNoFailureIsLoading() {
        XCTAssertEqual(libraryStatus(hasData: false, lastReadFailed: false, retriesExhausted: false), .loading)
    }

    func testDataWithHealthyReadIsReady() {
        XCTAssertEqual(libraryStatus(hasData: true, lastReadFailed: false, retriesExhausted: false), .ready)
    }

    func testNoDataAndFailedReadIsUnreadableNotEmpty() {
        // The defect: this used to render as "(no albums)".
        XCTAssertEqual(libraryStatus(hasData: false, lastReadFailed: true, retriesExhausted: false),
                       .unreadableRetrying)
    }

    func testNoDataAndExhaustedRetriesOffersManualRetry() {
        XCTAssertEqual(libraryStatus(hasData: false, lastReadFailed: true, retriesExhausted: true),
                       .unreadableExhausted)
    }

    // MARK: - Retry budget: three attempts, then stop

    func testBudgetExhaustsAfterThreeAttempts() {
        var b = LibraryRetryBudget()
        XCTAssertFalse(b.exhausted)
        b.recordFailure(); XCTAssertFalse(b.exhausted)
        b.recordFailure(); XCTAssertFalse(b.exhausted)
        b.recordFailure(); XCTAssertTrue(b.exhausted, "three attempts total, then stop")
    }

    func testManualRetryResetsTheBudget() {
        var b = LibraryRetryBudget()
        b.recordFailure(); b.recordFailure(); b.recordFailure()
        XCTAssertTrue(b.exhausted)
        b.reset()
        XCTAssertFalse(b.exhausted, "a manual retry resets the attempt budget")
    }

    func testBackoffIsBoundedAndIncreasing() {
        let d1 = LibraryRetryBudget.delay(forAttempt: 1)
        let d2 = LibraryRetryBudget.delay(forAttempt: 2)
        let d3 = LibraryRetryBudget.delay(forAttempt: 3)
        XCTAssertLessThan(d1, d2)
        XCTAssertLessThan(d2, d3)
        XCTAssertLessThanOrEqual(d3, 4.0, "backoff must stay short: this is a TUI, not a daemon")
    }
}
