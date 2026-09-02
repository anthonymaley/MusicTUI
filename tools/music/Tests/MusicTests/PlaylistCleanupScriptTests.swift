import XCTest
@testable import music

final class PlaylistCleanupScriptTests: XCTestCase {

    func testCollectsBothOwnedPrefixes() {
        let s = playlistCleanupScript()
        XCTAssertTrue(s.contains("__temp__"))
        XCTAssertTrue(s.contains(albumPlaylistPrefix))
    }

    /// The command is user invoked. Deleting a container someone is audibly
    /// listening to is worse than leaving a row behind, whatever its prefix.
    func testSparesEveryInUsePlayerState() {
        let s = playlistCleanupScript()
        for state in albumInUsePlayerStates {
            XCTAssertTrue(s.contains("\"\(state)\""),
                          "cleanup must test the in-use state \(state)")
        }
    }

    func testReadsPlayerStateAndCurrentPlaylist() {
        let s = playlistCleanupScript()
        XCTAssertTrue(s.contains("player state"))
        XCTAssertTrue(s.contains("current playlist"))
    }

    /// Containers only. This script enumerates playlists and can never reach a
    /// library row, which is the property that makes a sweep safe at all.
    func testScriptCanNeverReachALibraryRow() {
        let s = playlistCleanupScript()
        XCTAssertFalse(s.contains("track"), "cleanup must never name a track")
        XCTAssertFalse(s.contains("song"), "cleanup must never name a song")
    }

    /// The Discover sweep keeps its own, different rule.
    func testDiscoverSweepIsUnchangedAndStillCollectsPaused() {
        XCTAssertFalse(shouldSpareCurrentPlaylist(playerState: "paused"))
    }

    /// If `player state` throws, the script defaults to `unreadablePlayerStateFallback`,
    /// which must be an in-use state so the container is spared when a read fails.
    func testUnreadablePlayerStateSpares() {
        let s = playlistCleanupScript()
        XCTAssertTrue(s.contains("\"\(unreadablePlayerStateFallback)\""),
                      "script must initialise to unreadable fallback")
    }

    /// The default player state used when a read fails must itself be an in-use state,
    /// or a throwing `player state` would delete containers that are actually playing.
    /// This mirrors the check in DiscoverSweepTests.
    func testTheUnreadableFallbackIsItselfAnInUseState() {
        XCTAssertTrue(albumInUsePlayerStates.contains(unreadablePlayerStateFallback),
                      "fallback must be in-use so a thrown read spares, not deletes")
    }

    /// When the player is in an in-use state but the context read throws, the
    /// script must return the text "deferred" without deleting. We cannot
    /// identify which container to spare, so we spare them all. §16.5
    /// (corrects §11): this used to `return 0`, which the CLI printed as
    /// "Cleaned up 0 temp playlist(s)." — indistinguishable from "there was
    /// nothing to clean" — even though this is precisely the Autoplay-bleed
    /// signature a user hunting an orphan is likely to hit.
    func testUnreadableContextDefersTheSweep() {
        let s = playlistCleanupScript()
        XCTAssertTrue(s.contains("contextReadable"))
        XCTAssertTrue(s.contains("set contextReadable to false"))
        XCTAssertTrue(s.contains("if not contextReadable then return \"deferred\""),
                      "must abort before the repeat loop if context is not readable, and say so honestly")
        // Verify the guard precedes the loop
        let repeatIndex = s.range(of: "repeat with pp")?.lowerBound ?? s.startIndex
        let guardIndex = s.range(of: "if not contextReadable then return \"deferred\"")?.lowerBound ?? s.endIndex
        XCTAssertTrue(guardIndex < repeatIndex, "guard must precede the repeat loop")
    }

    // MARK: - §17.2: an unrecognised player state must abort, not sweep everything

    /// Same defect as `albumStaleSweepScript` (§17.2, corrects §16.1): an
    /// implicit else on the old positive-in-use test let any unrecognised
    /// `player state` fall through with `keepName` empty and delete
    /// everything, including `__temp__` playlists a user may be relying on.
    /// `playlistCleanupScript` must agree with the stale sweep's fix.
    func testUnrecognisedPlayerStateAbortsTheSweep() {
        let s = playlistCleanupScript()
        XCTAssertTrue(s.contains("set recognised to"), "must compute a positive recognised flag")
        for state in albumInUsePlayerStates {
            XCTAssertTrue(s.contains("playerStateText is \"\(state)\""),
                          "recognised must test the in-use state \(state)")
        }
        XCTAssertTrue(s.contains("playerStateText is \"stopped\""), "recognised must test \"stopped\"")
        XCTAssertTrue(s.contains("if not recognised then return \"deferred\""),
                      "must abort (honestly, not as a silent 0) before the repeat loop on an unrecognised state")
        let repeatIndex = s.range(of: "repeat with pp")?.lowerBound ?? s.startIndex
        let guardIndex = s.range(of: "if not recognised then return \"deferred\"")?.lowerBound ?? s.endIndex
        XCTAssertTrue(guardIndex < repeatIndex, "the recognised guard must precede the repeat loop")
    }

    func testUnrecognisedGuardPrecedesTheContextGuard() {
        let s = playlistCleanupScript()
        guard let recognisedIndex = s.range(of: "if not recognised then return \"deferred\"")?.lowerBound,
              let contextIndex = s.range(of: "if not contextReadable then return \"deferred\"")?.lowerBound else {
            return XCTFail("expected both guards to be present")
        }
        XCTAssertLessThan(recognisedIndex, contextIndex, "recognised guard must precede the context guard")
    }

    // MARK: - §16.5: honest deferred result

    func testParsePlaylistCleanupResultRecognisesDeferred() {
        XCTAssertEqual(parsePlaylistCleanupResult("deferred"), .deferred)
        XCTAssertEqual(parsePlaylistCleanupResult("  deferred\n"), .deferred)
    }

    func testParsePlaylistCleanupResultParsesARemovedCount() {
        XCTAssertEqual(parsePlaylistCleanupResult("3"), .removed(3))
        XCTAssertEqual(parsePlaylistCleanupResult(" 2 \n"), .removed(2))
    }

    /// §20.3: four outcomes, not two. "none" and "spared" are distinct
    /// literals the script returns so the CLI can tell "nothing existed"
    /// apart from "something existed but was correctly spared" — collapsing
    /// both into "Cleaned up 0" was the exact live-measured misreport §20
    /// fixes (a paused container spared correctly still printed
    /// "Cleaned up 0 temp playlist(s).").
    func testParsePlaylistCleanupResultDistinguishesNothingFromSpared() {
        XCTAssertEqual(parsePlaylistCleanupResult("none"), .nothingExisted)
        XCTAssertEqual(parsePlaylistCleanupResult("spared"), .sparedCandidates)
        XCTAssertNotEqual(PlaylistCleanupResult.nothingExisted, .sparedCandidates)
    }

    /// A literal "0" is never emitted by the script (it always resolves to
    /// "none" or "spared" instead), so if one ever showed up it must be
    /// treated as unreadable, not silently accepted as a valid zero-count.
    func testParsePlaylistCleanupResultTreatsLiteralZeroAsUnreadable() {
        XCTAssertEqual(parsePlaylistCleanupResult("0"), .unreadable)
    }

    /// §17.4 (corrects this test's own prior expectation): garbage must never
    /// be silently read as "0 deleted" — that is the same misreport §16.5
    /// fixed for the deferred case (a caught AppleScript exception), in a
    /// different degradation (a garbled or unexpected return value). It gets
    /// its own honest outcome, `.unreadable`, distinguishable from a genuine
    /// empty sweep.
    func testParsePlaylistCleanupResultTreatsGarbageAsUnreadableNotZero() {
        XCTAssertEqual(parsePlaylistCleanupResult("garbage"), .unreadable)
        XCTAssertEqual(parsePlaylistCleanupResult(""), .unreadable)
    }

    /// When the player is not in an in-use state, contextReadable stays true,
    /// and the script proceeds to sweep normally without the context guard blocking it.
    func testNotInUseStillSweeps() {
        let s = playlistCleanupScript()
        guard let initIndex = s.range(of: "set contextReadable to true")?.lowerBound,
              let ifIndex = s.range(of: "if playerStateText is")?.lowerBound else {
            return XCTFail("expected both the contextReadable initialiser and the in-use guard")
        }
        // The initialiser must PRECEDE the in-use block, otherwise a not-in-use
        // player would fall through to the abort guard and spare everything.
        XCTAssertLessThan(initIndex, ifIndex, "initialiser must precede the in-use guard")
        XCTAssertTrue(s.contains("repeat with pp"), "script must proceed to the delete loop")
    }
}
