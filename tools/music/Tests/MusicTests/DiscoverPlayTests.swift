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

    // MARK: - Position mapping

    /// "Play from here" resolves on CATALOG ID against what actually
    /// materialized. Not on title: repeated titles are common — DJ mixes with
    /// several `ID` entries, albums with a reprise, movements sharing a name —
    /// and a title match plays whichever came first, which is not the row the
    /// user selected.
    func testPositionMapsByCatalogIDAgainstMaterializedOrder() {
        let materialized = ["c.10", "c.20", "c.30", "c.40"]   // catalog ids, in order
        XCTAssertEqual(discoverPlayPosition(catalogID: "c.30", in: materialized), 3)
        XCTAssertEqual(discoverPlayPosition(catalogID: "c.10", in: materialized), 1)
    }

    /// The case a title match gets wrong. Two tracks share a title but not an id;
    /// the second must resolve to position 2.
    func testRepeatedTitlesStillResolveToTheSelectedRow() {
        let materialized = ["c.reprise-a", "c.reprise-b"]
        XCTAssertEqual(discoverPlayPosition(catalogID: "c.reprise-b", in: materialized), 2)
    }

    /// A selected track that did not materialize has no honest position. The
    /// caller must REPORT, never fall back to 1 — playing a different song than
    /// the one chosen is wrong, and a warning does not make it right.
    func testPositionIsNilWhenTheSelectedTrackDidNotMaterialize() {
        XCTAssertNil(discoverPlayPosition(catalogID: "c.missing", in: ["c.10", "c.20"]))
        XCTAssertNil(discoverPlayPosition(catalogID: "c.10", in: []))
    }
}
