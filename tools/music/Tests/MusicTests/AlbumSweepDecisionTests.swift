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
}
