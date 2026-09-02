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

    /// TRUE SPARING: every `"spared"` return is guarded by `protectedMatch`.
    ///
    /// §20.9 changed the shape deliberately. `"spared"` used to be reachable
    /// only from the empty-snapshot guard, and this test pinned that. But a
    /// race to zero WITH a protected container then reported "none", printing
    /// "No temp playlists to clean up." while an `__album__` container was
    /// audibly playing. So spared is now reachable after the delete pass too —
    /// and the invariant that actually matters is not WHERE it is returned but
    /// that it is never returned without evidence: `protectedMatch` is set only
    /// by the container that is genuinely current.
    ///
    /// This is a structural guard. The guarantee is
    /// `SweepScriptExecutionTests`, which runs the script and asserts spared
    /// appears only when a protected container really was present.
    func testEverySparedReturnIsGuardedByTheProtectedMatch() {
        let s = script
        let occurrences = s.components(separatedBy: "return \"spared\"").count - 1
        XCTAssertEqual(occurrences, 1,
                       "§20.10: ONE classification site — the empty-snapshot early return was "
                       + "the same rule written twice, and two copies is how guards drift apart")
        var searchStart = s.startIndex
        var checked = 0
        while let r = s.range(of: "return \"spared\"", range: searchStart..<s.endIndex) {
            let lookbackStart = s.index(r.lowerBound, offsetBy: -60, limitedBy: s.startIndex) ?? s.startIndex
            let lookback = String(s[lookbackStart..<r.lowerBound])
            XCTAssertTrue(lookback.contains("if protectedMatch then"),
                          "a spared return with no protectedMatch guard above it: ...\(lookback)")
            checked += 1
            searchStart = r.upperBound
        }
        XCTAssertEqual(checked, 1, "the single occurrence was inspected")
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

    /// RACE TO ZERO, when NOTHING was protected: a non-empty snapshot whose
    /// objects vanished before the delete removes nothing, and must report
    /// "none".
    ///
    /// §20.9 narrowed this deliberately, and the old name and doc here said
    /// the opposite of the shipped rule: "never spared" is true only when no
    /// container was protected. With `protectedMatch` set, that same path
    /// returns "spared", because a container genuinely was current and
    /// genuinely was kept — reporting "none" there printed "No temp playlists
    /// to clean up." while an `__album__` container was audibly playing.
    ///
    /// The executed proof of both halves is in `SweepScriptExecutionTests`.
    func testRaceToZeroReportsNoneWhenNothingWasProtected() {
        let s = script
        let delete = index("delete (every user playlist whose name is nm)", s)
        let zeroPath = index("if removedCount is 0 then", s)
        XCTAssertLessThan(delete, zeroPath, "the zero-removal path is post-delete")
        // The none arm is the ELSE of the protected test, so it cannot fire
        // while a container was spared.
        let guardIdx = index("if protectedMatch then", s)
        let noneIdx = index("return \"none\"", s)
        XCTAssertLessThan(zeroPath, guardIdx, "the protected test gates the zero path")
        XCTAssertLessThan(guardIdx, noneIdx, "none is the else branch of the protected test")
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
                      "beforeCount", "afterCount", "removedCount", "partial:",
                      "countFailed", "\"unknown\""] {
            XCTAssertFalse(s.contains(token), "uncounted variant must not emit \(token)")
        }
    }

    // MARK: - §20.8: malformed or incomplete payloads are UNKNOWN, never nothing

    /// The failure direction is the whole point. `.nothingExisted` and
    /// `.sparedCandidates` are positive claims — "there was nothing to clean",
    /// "a container existed and was deliberately kept" — and a payload the
    /// parser could not read is evidence for neither. Collapsing an unreadable
    /// result into either is the §16.5/§17.4/§20.3 misreport with a new cause.
    func testMalformedOrIncompletePayloadsAreNeverNothingOrSpared() {
        let malformed = [
            "", " ", "\n",
            "0", "-1", "3.5", "1e3", "+3", "one",
            "partial", "partial:", "partial:3", "partial:3:",
            "partial::2", "partial:::", "partial:x:1", "partial:1:y",
            "partial:-1:2", "partial:2:0", "partial:2:-1", "partial:1:2:3",
            "None", "NONE", "Spared", "SPARED", "Deferred",
            "cleaned up 4", "deleted 4", "{}", "missing value",
        ]
        for raw in malformed {
            let r = parsePlaylistCleanupResult(raw)
            XCTAssertNotEqual(r, .nothingExisted,
                              "an unreadable payload must never claim nothing existed: \(raw.debugDescription)")
            XCTAssertNotEqual(r, .sparedCandidates,
                              "an unreadable payload must never claim sparing: \(raw.debugDescription)")
            switch r {
            case .unreadable, .deferred: break
            default:
                XCTFail("\(raw.debugDescription) parsed as \(r); expected unknown")
            }
        }
    }

    /// The well-formed set still parses, so the guard above is not simply
    /// rejecting everything.
    func testWellFormedPayloadsStillParse() {
        XCTAssertEqual(parsePlaylistCleanupResult("none"), .nothingExisted)
        XCTAssertEqual(parsePlaylistCleanupResult("spared"), .sparedCandidates)
        XCTAssertEqual(parsePlaylistCleanupResult("deferred"), .deferred)
        XCTAssertEqual(parsePlaylistCleanupResult("4"), .removed(4))
        XCTAssertEqual(parsePlaylistCleanupResult(" 4 \n"), .removed(4))
        XCTAssertEqual(parsePlaylistCleanupResult("partial:3:2"),
                       .partiallyRemoved(removed: 3, remaining: 2))
        XCTAssertEqual(parsePlaylistCleanupResult("partial:0:4"),
                       .partiallyRemoved(removed: 0, remaining: 4))
    }

    // MARK: - §20.8: the partial message states BOTH counts

    func testPartialMessageStatesRemovedAndRemaining() {
        let msg = playlistCleanupMessage(.partiallyRemoved(removed: 3, remaining: 2))
        // LABELLED, not merely present. Containment alone passed against a
        // message with the two counts TRANSPOSED — which reads as a
        // near-complete cleanup when almost nothing was removed, destroying
        // the exact distinction the two counts exist to give.
        XCTAssertTrue(msg.contains("removed 3 temp playlist(s)"), "removed count must be labelled: \(msg)")
        XCTAssertTrue(msg.contains("2 still present"), "remaining count must be labelled: \(msg)")
        XCTAssertFalse(msg.lowercased().contains("playing"),
                       "a partial failure carries no evidence about playback")
        XCTAssertFalse(msg.contains("Cleaned up 0"))
    }

    /// Transposing the counts must fail, not merely change the string.
    func testPartialMessageCannotTransposeTheCounts() {
        let msg = playlistCleanupMessage(.partiallyRemoved(removed: 1, remaining: 8))
        XCTAssertTrue(msg.contains("removed 1 temp playlist(s)"),
                      "1 was removed, so 1 must be the removed count: \(msg)")
        XCTAssertTrue(msg.contains("8 still present"),
                      "8 remain, so 8 must be the remaining count: \(msg)")
        XCTAssertFalse(msg.contains("removed 8"), "8 is not the removed count")
        XCTAssertFalse(msg.contains("1 still present"), "1 is not the remaining count")
    }

    /// No outcome may print a bare "Cleaned up 0".
    func testNoOutcomeEverPrintsCleanedUpZero() {
        // Includes .removed(0) deliberately. The parser cannot construct it
        // (strictCountField requires count > 0), but the enum can, and the
        // protection belongs where this test says it does rather than only
        // upstream in the parser.
        let all: [PlaylistCleanupResult] = [
            .nothingExisted, .sparedCandidates, .deferred, .unreadable,
            .removed(1), .removed(0), .partiallyRemoved(removed: 0, remaining: 3),
        ]
        for r in all {
            XCTAssertFalse(playlistCleanupMessage(r).contains("Cleaned up 0"), "\(r)")
        }
    }

    /// A zero removal is a contradiction, so it reports UNKNOWN — never
    /// "nothing to clean", which would be a positive claim it cannot support.
    func testZeroRemovalReportsUnknownNotNothing() {
        let msg = playlistCleanupMessage(.removed(0))
        XCTAssertEqual(msg, playlistCleanupMessage(.unreadable))
        XCTAssertFalse(msg.contains("No temp playlists to clean up."))
    }

    /// Leading zeros are not a shape the generator emits.
    func testPaddedCountsAreUnreadable() {
        XCTAssertEqual(parsePlaylistCleanupResult("007"), .unreadable)
        XCTAssertEqual(parsePlaylistCleanupResult("partial:007:1"), .unreadable)
        XCTAssertEqual(parsePlaylistCleanupResult("partial:0:1"),
                       .partiallyRemoved(removed: 0, remaining: 1), "a bare 0 field is still valid")
    }
}
