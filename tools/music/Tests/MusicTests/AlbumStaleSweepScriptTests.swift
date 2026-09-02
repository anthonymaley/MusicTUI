import XCTest
@testable import music

/// §16.1: the next-invocation recovery sweep run at the start of
/// `playBoundedAlbum`, before the new container is built. `playlistCleanupScript`
/// tests already pin the identically-shaped user-invoked cleanup; these pin the
/// narrower, automatic one that runs on every album play.
final class AlbumStaleSweepScriptTests: XCTestCase {

    func testSweepsAlbumPrefixOnly() {
        let s = albumStaleSweepScript()
        XCTAssertTrue(s.contains(albumPlaylistPrefix))
    }

    /// The whole point of §16.1: this must be narrower than
    /// `playlistCleanupScript`, which also collects `__temp__`. A user may be
    /// relying on a `__temp__` playlist, and this sweep runs on every single
    /// album play, not on an explicit user command.
    func testNeverSweepsOtherOwnedPrefixes() {
        let s = albumStaleSweepScript()
        XCTAssertFalse(s.contains("__temp__"), "must never touch __temp__ containers")
        XCTAssertFalse(s.contains(discoverPlaylistPrefix), "must never touch __discover__ containers")
        XCTAssertFalse(s.contains("__queue__"), "must never touch __queue__ containers")
    }

    /// Containers only — this script enumerates playlists and can never reach
    /// a library row, the property that makes any of these three sweeps safe.
    func testScriptCanNeverReachALibraryRow() {
        let s = albumStaleSweepScript()
        XCTAssertFalse(s.contains("track"), "must never name a track")
        XCTAssertFalse(s.contains("song"), "must never name a song")
    }

    func testSparesEveryInUsePlayerState() {
        let s = albumStaleSweepScript()
        for state in albumInUsePlayerStates {
            XCTAssertTrue(s.contains("\"\(state)\""), "must test the in-use state \(state)")
        }
    }

    func testUnreadablePlayerStateSpares() {
        let s = albumStaleSweepScript()
        XCTAssertTrue(s.contains("\"\(unreadablePlayerStateFallback)\""),
                      "script must initialise to the unreadable fallback")
    }

    /// Unreadable context while in-use must abort the whole sweep (delete
    /// nothing), same shape as `playlistCleanupScript` — we cannot identify
    /// which container to spare, so we spare them all.
    func testUnreadableContextAbortsTheSweep() {
        let s = albumStaleSweepScript()
        XCTAssertTrue(s.contains("set contextReadable to false"))
        XCTAssertTrue(s.contains("if not contextReadable then return"),
                      "must abort before the repeat loop if context is not readable")
        let repeatIndex = s.range(of: "repeat with pp")?.lowerBound ?? s.startIndex
        let guardIndex = s.range(of: "if not contextReadable then return")?.lowerBound ?? s.endIndex
        XCTAssertTrue(guardIndex < repeatIndex, "guard must precede the repeat loop")
    }

    func testNeverPrefixWideBeyondAlbumPrefix() {
        let s = albumStaleSweepScript()
        // Only one "starts with" test, and it must be the album prefix.
        let occurrences = s.components(separatedBy: "starts with").count - 1
        XCTAssertEqual(occurrences, 1, "must test exactly one prefix")
        XCTAssertTrue(s.contains("nm starts with \"\(albumPlaylistPrefix)\""))
    }
}
