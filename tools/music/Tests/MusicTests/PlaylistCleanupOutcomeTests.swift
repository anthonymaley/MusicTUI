import XCTest
@testable import music

/// §20.6: cleanup outcomes are MEASURED from post-delete state, never
/// predicted from a pre-delete count and never inferred from "something
/// matched a prefix".
///
/// The review that produced this file found the previous shape returned
/// `"spared"` whenever `deleted == 0`, including when a NON-EMPTY snapshot
/// removed nothing — so the CLI told the user a container was playing when
/// nothing was. These tests pin the corrected classification positionally,
/// so they fail against that shape rather than merely observing that the
/// right words appear somewhere.
final class PlaylistCleanupOutcomeTests: XCTestCase {

    private let script = playlistCleanupScript()

    private func index(_ needle: String, _ s: String) -> String.Index {
        guard let r = s.range(of: needle) else {
            XCTFail("script does not contain \(needle)"); return s.startIndex
        }
        return r.lowerBound
    }

    // MARK: - parser

    func testParsesPartialWithMeasuredCounts() {
        XCTAssertEqual(parsePlaylistCleanupResult("partial:3:2"),
                       .partiallyRemoved(removed: 3, remaining: 2))
    }

    /// TOTAL DELETE FAILURE: every delete threw, nothing removed, all still there.
    func testTotalDeleteFailureParsesAsPartialWithZeroRemoved() {
        XCTAssertEqual(parsePlaylistCleanupResult("partial:0:4"),
                       .partiallyRemoved(removed: 0, remaining: 4))
    }

    /// PARTIAL DELETION: some removed, some remain.
    func testPartialDeletionCarriesBothMeasuredCounts() {
        guard case .partiallyRemoved(let removed, let remaining) =
                parsePlaylistCleanupResult("partial:2:2") else {
            return XCTFail("expected .partiallyRemoved")
        }
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(remaining, 2)
    }

    /// A partial with nothing remaining is a contradiction the script cannot
    /// emit; refuse it rather than reporting a success it never claimed.
    func testMalformedPartialIsUnreadableNeverASuccess() {
        for raw in ["partial:2:0", "partial:2", "partial:x:1", "partial::1", "partial:-1:2"] {
            XCTAssertEqual(parsePlaylistCleanupResult(raw), .unreadable, "raw=\(raw)")
        }
    }

    // MARK: - generated script: classification is measured

    /// TRUE SPARING: `"spared"` is reachable ONLY from the empty-snapshot
    /// guard, and is unreachable once the delete pass has run.
    func testSparedIsGuardedByAnEmptySnapshotAndUnreachableAfterDeleting() {
        let s = script
        XCTAssertEqual(s.components(separatedBy: "return \"spared\"").count - 1, 1,
                       "exactly one spared return")
        let guardIdx = index("if (count of eligibleNames) is 0 then", s)
        let spared = index("return \"spared\"", s)
        let delete = index("delete (every user playlist whose name is nm)", s)
        XCTAssertLessThan(guardIdx, spared, "spared must sit inside the empty-snapshot guard")
        XCTAssertLessThan(spared, delete, "spared must be unreachable after the delete pass")
    }

    /// True sparing additionally requires the PROTECTED match, not merely that
    /// some playlist matched a prefix. A captured name also matched one.
    func testSparedRequiresTheProtectedMatchNotAnyPrefixMatch() {
        let s = script
        XCTAssertTrue(s.contains("if protectedMatch then"))
        XCTAssertFalse(s.contains("matchedAny"),
                       "matchedAny conflated 'a prefix matched' with 'it was spared'")
        let protectedSet = index("set protectedMatch to true", s)
        let keepTest = index("if (nm is keepName) then", s)
        XCTAssertLessThan(keepTest, protectedSet,
                          "protectedMatch may only be set on the keepName branch")
    }

    /// RACE TO ZERO: a non-empty snapshot whose objects vanished before the
    /// delete (a watcher won the race) removes nothing, but must report
    /// "none" — never "spared", which would claim playback that isn't there.
    func testRaceToZeroReportsNothingNeverSpared() {
        let s = script
        let delete = index("delete (every user playlist whose name is nm)", s)
        let zeroPath = index("if removedCount is 0 then", s)
        let none = s.range(of: "return \"none\"", range: zeroPath..<s.endIndex)
        XCTAssertLessThan(delete, zeroPath, "the zero-removal path is post-delete")
        XCTAssertNotNil(none, "a post-delete zero removal returns none")
    }

    /// The after-count is READ after the delete pass, not inferred from the
    /// before-count. This is the finding that produced §20.6.
    func testAfterCountIsMeasuredAfterTheDeletePass() {
        let s = script
        let before = index("set beforeCount to beforeCount +", s)
        let delete = index("delete (every user playlist whose name is nm)", s)
        let after = index("set afterCount to afterCount +", s)
        XCTAssertLessThan(before, delete, "before-count precedes the delete")
        XCTAssertLessThan(delete, after, "after-count FOLLOWS the delete")
        XCTAssertTrue(s.contains("set removedCount to beforeCount - afterCount"))
        XCTAssertTrue(s.contains("if removedCount < 0 then set removedCount to 0"),
                      "removed is clamped defensively at zero")
    }

    /// Counting ranges only over the names THIS invocation captured, so an
    /// unrelated concurrent playlist creation cannot distort the result.
    func testCountsAreScopedToTheCapturedNamesOnly() {
        let s = script
        XCTAssertEqual(
            s.components(separatedBy: "count of (every user playlist whose name is nm)").count - 1,
            2, "both counts are per captured name")
        XCTAssertFalse(s.contains("count of (every user playlist)"),
                       "never counts the whole playlist collection")
        for loop in ["repeat with nm in eligibleNames"] {
            XCTAssertEqual(s.components(separatedBy: loop).count - 1, 3,
                           "before-count, delete and after-count each iterate the snapshot")
        }
    }

    /// The partial return carries both measured counts, in order.
    func testPartialReturnCarriesRemovedThenRemaining() {
        XCTAssertTrue(script.contains("return \"partial:\" & removedCount & \":\" & afterCount"))
        let afterGuard = index("if afterCount > 0 then", script)
        let partial = index("return \"partial:\"", script)
        XCTAssertLessThan(afterGuard, partial, "partial is gated on objects actually remaining")
    }

    /// The uncounted variant carries no outcome bookkeeping at all.
    func testUncountedVariantEmitsNoOutcomeBookkeeping() {
        let s = albumStaleSweepScript()
        for token in ["protectedMatch", "matchedAny", "\"spared\"", "\"none\"",
                      "beforeCount", "afterCount", "removedCount", "partial:"] {
            XCTAssertFalse(s.contains(token), "uncounted variant must not emit \(token)")
        }
    }
}
