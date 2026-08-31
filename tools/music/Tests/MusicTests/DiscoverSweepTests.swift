import XCTest
@testable import music

/// The Discover container sweep, as a pure decision plus a pinned script.
///
/// These tests pin the RULE and the generated script text. They cannot prove
/// what Music does when a read fails — the guard that actually runs is
/// AppleScript, so only live verification covers behaviour. What they do buy is
/// that the Swift predicate and the emitted script can never disagree, which is
/// the twin-drift shape this repo has already paid for twice.
final class DiscoverSweepTests: XCTestCase {
    // MARK: - The spare rule

    /// Music's `player state` has five values (sdef, read 2026-08-31):
    /// stopped, playing, paused, fast forwarding, rewinding. Only the two idle
    /// ones release the container.
    func testActivePlaybackSparesTheCurrentPlaylist() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: "playing"))
    }

    func testPausedAndStoppedReleaseTheCurrentPlaylist() {
        XCTAssertFalse(shouldSpareCurrentPlaylist(playerState: "paused"))
        XCTAssertFalse(shouldSpareCurrentPlaylist(playerState: "stopped"))
    }

    /// A scrub is active playback. The filed fix shape ("spare only while
    /// playing") would have deleted the container out from under it.
    func testScrubbingSparesTheCurrentPlaylist() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: "fast forwarding"))
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: "rewinding"))
    }

    /// Read error. Sparing is the cheap side of the asymmetry: a spared
    /// container costs one leftover row the next sweep collects, a wrongly
    /// swept one reverts live playback to the library.
    func testAnUnreadableStateSparesTheCurrentPlaylist() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: nil))
    }

    /// Any value Apple adds later lands on the spare side by construction.
    func testAnUnknownStateSparesTheCurrentPlaylist() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: "buffering"))
    }

    // MARK: - Script / predicate agreement

    /// The live guard is the generated AppleScript, so the two must key on one
    /// set of literals. This is the `nowPlayingReadyState` shape.
    func testScriptKeysOnTheSameStatesAsThePredicate() {
        let script = discoverSweepScript()
        for state in sweepablePlayerStates {
            XCTAssertTrue(script.contains("\"\(state)\""),
                          "script must test the sweepable state \(state)")
            XCTAssertFalse(shouldSpareCurrentPlaylist(playerState: state))
        }
    }

    /// The fallback used when `player state` cannot be read must itself be a
    /// state the predicate spares, or an unreadable state would sweep.
    func testTheUnreadableFallbackIsASparedState() {
        XCTAssertTrue(shouldSpareCurrentPlaylist(playerState: unreadablePlayerStateFallback))
        XCTAssertTrue(discoverSweepScript().contains("\"\(unreadablePlayerStateFallback)\""))
    }

    func testScriptSweepsTheDiscoverPrefix() {
        XCTAssertTrue(discoverSweepScript().contains(discoverPlaylistPrefix))
    }

    /// The containers-only invariant, from DiscoverPlay.swift's module doc: this
    /// script enumerates playlists and can never reach a library row. Pinned
    /// here so it is enforced rather than merely documented.
    func testScriptCanNeverReachALibraryRow() {
        let script = discoverSweepScript()
        XCTAssertFalse(script.contains("track"), "sweep must never name a track")
        XCTAssertFalse(script.contains("song"), "sweep must never name a song")
    }
}
