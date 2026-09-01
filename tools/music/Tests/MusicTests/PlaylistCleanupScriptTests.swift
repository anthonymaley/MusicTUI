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
}
