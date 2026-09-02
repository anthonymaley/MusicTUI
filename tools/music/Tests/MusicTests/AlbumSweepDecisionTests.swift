import XCTest
@testable import music

/// §18.4: `albumStaleSweepScript` and `playlistCleanupScript` used to carry
/// the same twelve-line guard preamble near-verbatim, and §17.2's defect — a
/// guard nested inside a branch that never executed — existed in BOTH copies
/// and had to be fixed in both. The only tests either script had before this
/// were string-containment pins, which can see that a guard's literal text
/// exists somewhere in the script but cannot see whether it is reachable —
/// exactly what let §17.2's defect through.
///
/// These tests exercise `albumSweepDecision` as a full Swift truth table,
/// the same shape `AlbumWatcherDecisionTests` uses for `albumWatcherDecision`,
/// and then pin that both script generators are built from the one shared
/// preamble generator (`albumSweepGuardedScript`) rather than their own
/// hand-maintained copies.
final class AlbumSweepDecisionTests: XCTestCase {

    // MARK: - The decision truth table

    /// Every in-use state, with a readable context: safe to sweep.
    func testInUseStatesWithReadableContextSweep() {
        for state in albumInUsePlayerStates {
            XCTAssertEqual(albumSweepDecision(playerState: state, contextReadable: true),
                           .sweepSparingCurrent, "must sweep for in-use state \(state) with a readable context")
        }
    }

    /// Every in-use state, with an UNREADABLE context: defer — we cannot
    /// identify which container is current, so nothing may be deleted.
    func testInUseStatesWithUnreadableContextDefer() {
        for state in albumInUsePlayerStates {
            XCTAssertEqual(albumSweepDecision(playerState: state, contextReadable: false),
                           .deferSweep, "must defer for in-use state \(state) with an unreadable context")
        }
    }

    /// "stopped" never even reaches the context check — `contextReadable`
    /// stays irrelevant, and the sweep proceeds sparing nothing (there is
    /// nothing to spare when the player is stopped).
    func testStoppedSweepsRegardlessOfContextReadability() {
        XCTAssertEqual(albumSweepDecision(playerState: "stopped", contextReadable: true), .sweepSparingCurrent)
        XCTAssertEqual(albumSweepDecision(playerState: "stopped", contextReadable: false), .sweepSparingCurrent)
    }

    /// §17.2's actual defect, mirrored here in Swift: an unrecognised state
    /// (neither in-use nor "stopped") must defer, not fall through to a
    /// sweep — even when `contextReadable` is true (which, before §17.2,
    /// would have let an implicit-else shape delete everything).
    func testUnrecognisedStateDefersEvenWithAReadableContext() {
        XCTAssertEqual(albumSweepDecision(playerState: "buffering", contextReadable: true), .deferSweep)
        XCTAssertEqual(albumSweepDecision(playerState: "buffering", contextReadable: false), .deferSweep)
    }

    /// `nil` (the AppleScript `try` failed) resolves exactly as
    /// `unreadablePlayerStateFallback` would — the generated script
    /// substitutes that same fallback before ever reaching the recognised
    /// check, so the two must never disagree.
    func testUnreadablePlayerStateResolvesLikeItsOwnFallback() {
        XCTAssertEqual(albumSweepDecision(playerState: nil, contextReadable: true),
                       albumSweepDecision(playerState: unreadablePlayerStateFallback, contextReadable: true))
        XCTAssertEqual(albumSweepDecision(playerState: nil, contextReadable: false),
                       albumSweepDecision(playerState: unreadablePlayerStateFallback, contextReadable: false))
    }

    /// The fallback itself must be an in-use state, or an unreadable
    /// `player state` read would sweep unconditionally rather than defer to
    /// a context check.
    func testTheFallbackIsItselfAnInUseState() {
        XCTAssertTrue(albumInUsePlayerStates.contains(unreadablePlayerStateFallback))
    }

    // MARK: - Script / decision agreement

    /// Both generators must be built from the ONE shared preamble generator
    /// with their own prefixes/deferReturn/countDeleted — reconstructing
    /// each directly and checking for exact equality means the two can never
    /// silently diverge in the guard preamble again.
    func testBothSweepScriptsAreBuiltFromTheSharedGuardedGenerator() {
        XCTAssertEqual(playlistCleanupScript(),
                       albumSweepGuardedScript(prefixes: ["__temp__", albumPlaylistPrefix],
                                               deferReturn: "return \"deferred\"", countDeleted: true))
        XCTAssertEqual(albumStaleSweepScript(),
                       albumSweepGuardedScript(prefixes: [albumPlaylistPrefix],
                                               deferReturn: "return", countDeleted: false))
    }

    /// The generator keys the "recognised" guard on the exact same states
    /// `albumSweepDecision` treats as in-use — the live guard is the
    /// generated AppleScript, so the two must never drift.
    func testGeneratedScriptKeysOnTheSameInUseStatesAsTheDecision() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: false)
        for state in albumInUsePlayerStates {
            XCTAssertTrue(script.contains("\"\(state)\""), "script must test the in-use state \(state)")
        }
        XCTAssertTrue(script.contains("\"\(unreadablePlayerStateFallback)\""))
    }

    /// The generator's `prefixes` parameter must reach the emitted delete
    /// loop's `starts with` tests, one per prefix, joined by "or".
    func testGeneratedScriptTestsEveryGivenPrefix() {
        let script = albumSweepGuardedScript(prefixes: ["__a__", "__b__"], deferReturn: "return", countDeleted: false)
        XCTAssertTrue(script.contains("nm starts with \"__a__\""))
        XCTAssertTrue(script.contains("nm starts with \"__b__\""))
    }

    /// `countDeleted` selects between the counted, `return`-a-count delete
    /// loop and the uncounted one.
    func testCountDeletedSelectsTheCountingDeleteLoop() {
        let counted = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: true)
        let uncounted = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: false)
        XCTAssertTrue(counted.contains("set deleted to 0"))
        XCTAssertTrue(counted.contains("return deleted"))
        XCTAssertFalse(uncounted.contains("set deleted to 0"))
        XCTAssertFalse(uncounted.contains("return deleted"))
    }

    /// Containers only, whatever prefixes are supplied: the shared generator
    /// itself must never be able to reach a library row.
    func testGeneratedScriptCanNeverReachALibraryRow() {
        let script = albumSweepGuardedScript(prefixes: ["__temp__", albumPlaylistPrefix],
                                             deferReturn: "return \"deferred\"", countDeleted: true)
        XCTAssertFalse(script.contains("track"), "must never name a track")
        XCTAssertFalse(script.contains("song"), "must never name a song")
    }

    // MARK: - §20: snapshot, then delete

    /// The defect: both loops used to delete `pp` from inside the very loop
    /// enumerating `every user playlist`, which shifts the live collection's
    /// indices and skips the element right after the one just deleted —
    /// measured live 2026-09-02, one cleanup invocation collected 2 of 4
    /// stale containers. The fix is two strictly ordered phases: enumerate
    /// read-only into `eligibleNames`, then delete from that captured list
    /// in a second loop that runs only after the first is done.
    func testEnumerationPhaseNeverDeletesAndPrecedesTheDeletePhase() {
        for countDeleted in [true, false] {
            let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: countDeleted)
            guard let enumStart = script.range(of: "repeat with pp in (every user playlist)")?.lowerBound,
                  let enumEnd = script.range(of: "end repeat", range: enumStart..<script.endIndex)?.upperBound else {
                return XCTFail("expected a bounded enumeration loop (countDeleted=\(countDeleted))")
            }
            XCTAssertFalse(script[enumStart..<enumEnd].contains("delete"),
                           "enumeration loop must never delete (countDeleted=\(countDeleted))")
            guard let deleteStart = script.range(of: "repeat with nm in eligibleNames")?.lowerBound else {
                return XCTFail("expected a second loop over eligibleNames (countDeleted=\(countDeleted))")
            }
            XCTAssertLessThan(enumEnd, deleteStart,
                              "delete-by-name loop must start after enumeration ends (countDeleted=\(countDeleted))")
        }
    }

    /// §20.2: the snapshot is a DEDUPLICATED list of exact owned names — this
    /// is what makes the legacy same-second `__temp__` collision
    /// deterministic (one captured name, not one entry per duplicate).
    func testEnumerationDeduplicatesCapturedNames() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: false)
        XCTAssertTrue(script.contains("eligibleNames does not contain nm"),
                      "capture must check for an existing entry before appending")
    }

    /// §20.3: an active/paused container is excluded from the SNAPSHOT
    /// itself — never captured — not merely filtered out at delete time.
    /// `keepName` must be checked in the same `if` that appends to
    /// `eligibleNames`, not in a separate later step.
    func testKeepNameIsExcludedAtCaptureTimeNotFilteredLater() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: false)
        XCTAssertTrue(script.contains("(nm is not keepName) and (eligibleNames does not contain nm)"),
                      "keepName exclusion must gate the append into eligibleNames")
    }

    /// §20.3: the counted variant must distinguish "nothing existed" from
    /// "something existed but was entirely spared" — collapsing both into
    /// "0" was the exact live-measured misreport (a correctly spared paused
    /// container printed "Cleaned up 0 temp playlist(s)."). `matchedAny`
    /// tracks whether ANY playlist matched the prefix, spared one included,
    /// independent of whether anything ended up eligible for deletion.
    func testCountedVariantReturnsThreeDistinctOutcomesNotJustACount() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return \"deferred\"", countDeleted: true)
        XCTAssertTrue(script.contains("set matchedAny to false"))
        XCTAssertTrue(script.contains("set matchedAny to true"))
        XCTAssertTrue(script.contains("return \"none\""), "nothing matched at all")
        XCTAssertTrue(script.contains("return \"spared\""), "something matched but all of it was spared")
        XCTAssertTrue(script.contains("return deleted"), "one or more objects were actually removed")
    }

    /// The uncounted stale-sweep variant has no outcome to report — it runs
    /// silently on every album play — so it must not carry the counted
    /// variant's bookkeeping.
    func testUncountedVariantCarriesNoOutcomeBookkeeping() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: false)
        XCTAssertFalse(script.contains("\"none\""))
        XCTAssertFalse(script.contains("\"spared\""))
    }

    /// §20.3: count actual playlist OBJECTS removed, not unique names
    /// processed — exact-name deletion removes every duplicate sharing a
    /// captured name, so the counted delete loop must sum the actual object
    /// count per name rather than incrementing by one per name.
    ///
    /// Coordinator review caught a regression in an earlier draft: the count
    /// was taken and folded into `deleted` BEFORE `delete` ran, both inside
    /// the same `try` — so a `delete` that throws (a Music.app hiccup, a
    /// transient Apple Event failure) still inflated `deleted` for objects
    /// that are still there, and the CLI would report "Cleaned up N" for
    /// playlists the user can still see. The pre-§20 loop never had this bug
    /// (it did `delete pp` and only then `deleted + 1`, both inside one
    /// `try`); the fix restores that same delete-before-count order. A
    /// contains-only check on the count expression passes equally against
    /// the broken order, so this pins it POSITIONALLY: within the counted
    /// delete loop's own span, `delete` must appear before the increment.
    func testCountedDeleteLoopCountsObjectsOnlyAfterTheDeleteSucceeds() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return \"deferred\"", countDeleted: true)
        XCTAssertTrue(script.contains("count of (every user playlist whose name is nm)"),
                      "must count the actual object count per captured name")
        XCTAssertFalse(script.contains("set deleted to deleted + 1"),
                       "must never count names processed as a proxy for objects removed")

        guard let loopStart = script.range(of: "repeat with nm in eligibleNames")?.lowerBound,
              let loopEnd = script.range(of: "end repeat", range: loopStart..<script.endIndex)?.upperBound else {
            return XCTFail("expected the counted delete loop over eligibleNames")
        }
        let loop = script[loopStart..<loopEnd]
        guard let deleteIndex = loop.range(of: "delete (every user playlist whose name is nm)")?.lowerBound,
              let incrementIndex = loop.range(of: "set deleted to deleted +")?.lowerBound else {
            return XCTFail("expected both the delete statement and the increment inside the loop")
        }
        XCTAssertLessThan(deleteIndex, incrementIndex,
                          "delete must happen before the count is folded into deleted, or a throwing delete inflates the count")
    }

    /// Both variants delete via the same exact-name reference form
    /// `playlistDeleteScript` already uses — proven live against a
    /// REST-created playlist — applied to the CAPTURED name, never to a
    /// live `pp` reference from the enumeration loop.
    func testBothVariantsDeleteByExactCapturedNameNeverByLiveReference() {
        for countDeleted in [true, false] {
            let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: countDeleted)
            XCTAssertTrue(script.contains("delete (every user playlist whose name is nm)"),
                          "countDeleted=\(countDeleted)")
            XCTAssertFalse(script.contains("delete pp"), "countDeleted=\(countDeleted)")
        }
    }
}
