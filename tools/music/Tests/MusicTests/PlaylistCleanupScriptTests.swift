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

    /// When the player is in an in-use state but the context read throws,
    /// the script must return 0 without deleting. We cannot identify which
    /// container to spare, so we spare them all.
    func testUnreadableContextAbortsTheSweep() {
        let s = playlistCleanupScript()
        XCTAssertTrue(s.contains("contextReadable"))
        XCTAssertTrue(s.contains("set contextReadable to false"))
        XCTAssertTrue(s.contains("if not contextReadable then return 0"),
                      "must abort before the repeat loop if context is not readable")
        // Verify the guard precedes the loop
        let repeatIndex = s.range(of: "repeat with pp")?.lowerBound ?? s.startIndex
        let guardIndex = s.range(of: "if not contextReadable then return 0")?.lowerBound ?? s.endIndex
        XCTAssertTrue(guardIndex < repeatIndex, "guard must precede the repeat loop")
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
