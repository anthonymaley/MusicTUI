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
        XCTAssertTrue(counted.contains("set beforeCount to 0"))
        XCTAssertTrue(counted.contains("return removedCount"))
        XCTAssertFalse(uncounted.contains("set beforeCount to 0"))
        XCTAssertFalse(uncounted.contains("return removedCount"))
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
        let uncounted = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: false)
        XCTAssertTrue(uncounted.contains("(nm is not keepName) and (eligibleNames does not contain nm)"),
                      "uncounted: keepName exclusion must gate the append into eligibleNames")

        // §20.6 split this capture body per variant so the counted one could
        // record `protectedMatch`, which dropped the counted variant's only
        // coverage of this property.
        //
        // What follows is a TEXT pin, and a text pin cannot see conditionality
        // or reachability: a dead `else` branch with the append hoisted below
        // `end if`, or the whole token sequence hoisted into an `if false`
        // decoy, keeps every token present and ordered while capturing the
        // container the user is listening to. Those shapes are caught by
        // SweepCaptureExecutionTests, which RUNS this loop over a synthetic
        // name list. This pin is kept as a cheap structural guard; it is not
        // the guarantee. See §20.7.
        let counted = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return \"deferred\"", countDeleted: true)
        XCTAssertEqual(counted.components(separatedBy: "set end of eligibleNames to nm").count - 1, 1,
                       "counted: exactly one append path into eligibleNames")

        // Pin the ORDERED SEQUENCE, not the four tokens independently. Checking
        // that each token merely appears somewhere passed against a mutation
        // that SWAPPED the two branch bodies — appending keepName itself and
        // recording protectedMatch for the stale containers, i.e. deleting the
        // album the user is listening to and sparing the orphans. That mutation
        // compiled, and all 925 tests passed. Order is the property; presence
        // is not.
        guard let keepTest = counted.range(of: "if (nm is keepName) then")?.lowerBound,
              let protectedSet = counted.range(of: "set protectedMatch to true")?.lowerBound,
              let elseIf = counted.range(of: "else if (eligibleNames does not contain nm) then")?.lowerBound,
              let append = counted.range(of: "set end of eligibleNames to nm")?.lowerBound else {
            return XCTFail("counted: expected keepName test, protected set, else-if and append")
        }
        XCTAssertLessThan(keepTest, protectedSet,
                          "counted: the THEN branch of the keepName test records protectedMatch")
        XCTAssertLessThan(protectedSet, elseIf,
                          "counted: protectedMatch belongs to the THEN branch, before the else-if")
        XCTAssertLessThan(elseIf, append,
                          "counted: the append belongs to the ELSE branch, after the else-if")
    }

    /// §20.6: the counted variant must distinguish FOUR outcomes, and each
    /// must be reachable only from measured state.
    ///
    /// The original §20.3 shape had three and used `matchedAny` ("some
    /// playlist matched a prefix") as the evidence for sparing. That was
    /// wrong: a name captured into the snapshot also matched a prefix, so a
    /// non-empty snapshot that removed nothing reported "spared" and the CLI
    /// told the user a container was playing when nothing was. Sparing is now
    /// gated on `protectedMatch` — the match that IS the active container —
    /// and a fourth outcome carries a measured partial deletion.
    func testCountedVariantReturnsFourMeasuredOutcomes() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return \"deferred\"", countDeleted: true)
        XCTAssertFalse(script.contains("matchedAny"),
                       "matchedAny conflated a prefix match with sparing")
        XCTAssertTrue(script.contains("set protectedMatch to false"))
        XCTAssertTrue(script.contains("set protectedMatch to true"))
        XCTAssertTrue(script.contains("return \"none\""), "nothing matched, or nothing was removed")
        XCTAssertTrue(script.contains("return \"spared\""), "the only match was the protected container")
        XCTAssertTrue(script.contains("return removedCount"), "objects were measurably removed")
        XCTAssertTrue(script.contains("return \"partial:\" & removedCount & \":\" & afterCount"),
                      "some captured names still resolve to live objects")
    }

    /// The uncounted stale-sweep variant has no outcome to report — it runs
    /// silently on every album play — so it must not carry the counted
    /// variant's bookkeeping.
    func testUncountedVariantCarriesNoOutcomeBookkeeping() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return", countDeleted: false)
        XCTAssertFalse(script.contains("\"none\""))
        XCTAssertFalse(script.contains("\"spared\""))
    }

    /// §20.6: the reported count is MEASURED, never predicted.
    ///
    /// The pre-§20.6 shape took the object count BEFORE deleting and reported
    /// it, so a `delete` that threw (a Music.app hiccup, a transient Apple
    /// Event failure) still reported objects the user can still see. Counting
    /// after the delete and subtracting is correct whatever the plural-delete
    /// semantics turn out to be, so it removes an unmeasured premise rather
    /// than betting on one. Pinned POSITIONALLY: a contains-only check passes
    /// equally against a script that measures the after-count too early.
    func testReportedCountIsMeasuredAfterDeletionNotPredictedBeforeIt() {
        let script = albumSweepGuardedScript(prefixes: ["x"], deferReturn: "return \"deferred\"", countDeleted: true)
        XCTAssertFalse(script.contains("set deleted to deleted +"),
                       "must not fold a pre-delete count into the reported total")
        XCTAssertTrue(script.contains("set removedCount to beforeCount - afterCount"),
                      "removed is a measured delta, not a prediction")
        XCTAssertTrue(script.contains("if removedCount < 0 then set removedCount to 0"),
                      "clamped defensively at zero")

        guard let before = script.range(of: "set beforeCount to beforeCount +")?.lowerBound,
              let delete = script.range(of: "delete (every user playlist whose name is nm)")?.lowerBound,
              let after = script.range(of: "set afterCount to afterCount +")?.lowerBound else {
            return XCTFail("expected a before-count, a delete pass and an after-count")
        }
        XCTAssertLessThan(before, delete, "the before-count precedes the delete pass")
        XCTAssertLessThan(delete, after, "the after-count FOLLOWS the delete pass")
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
