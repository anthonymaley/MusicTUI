import XCTest
@testable import music

final class DiscoverPlayTests: XCTestCase {
    // MARK: - Readiness

    /// The add returns 202 and materializes asynchronously, so playback must wait
    /// for the expected track count rather than assume it. Playing a partially
    /// materialized playlist would start a short album that grows underneath.
    func testReadinessWaitsUntilTheFullCountLands() {
        XCTAssertEqual(discoverReadiness(observed: 0, expected: 5, elapsed: 0.2, timeout: 10), .wait)
        XCTAssertEqual(discoverReadiness(observed: 3, expected: 5, elapsed: 1.0, timeout: 10), .wait)
        XCTAssertEqual(discoverReadiness(observed: 5, expected: 5, elapsed: 2.1, timeout: 10), .ready)
    }

    /// More than expected is still ready — never block on an off-by-one from
    /// Apple's side.
    func testReadinessAcceptsMoreThanExpected() {
        XCTAssertEqual(discoverReadiness(observed: 6, expected: 5, elapsed: 1.0, timeout: 10), .ready)
    }

    /// On timeout the transaction is abandoned rather than played. The playlist
    /// survives for the sweep; a half-materialized play is worse than none.
    func testReadinessTimesOutRatherThanPlayingPartial() {
        XCTAssertEqual(discoverReadiness(observed: 2, expected: 5, elapsed: 10.0, timeout: 10), .timedOut)
    }
}
