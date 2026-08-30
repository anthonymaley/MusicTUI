import XCTest
@testable import music

final class DiscoverPlayTests: XCTestCase {
    // MARK: - Readiness

    /// The add returns 202 and materializes asynchronously, so playback must wait
    /// for the expected track count rather than assume it. Playing a partially
    /// materialized playlist would start a short album that grows underneath.
    func testReadinessWaitsUntilTheFullCountLands() {
        XCTAssertEqual(discoverReadiness(observed: 0, expected: 5, elapsed: 0.2, timeout: 10), .wait)
        XCTAssertEqual(discoverReadiness(observed: 3, expected: 5, elapsed: 1.0, timeout: 10), .wait)
        XCTAssertEqual(discoverReadiness(observed: 5, expected: 5, elapsed: 2.1, timeout: 10), .ready)
    }

    /// More than expected is still ready — never block on an off-by-one from
    /// Apple's side.
    func testReadinessAcceptsMoreThanExpected() {
        XCTAssertEqual(discoverReadiness(observed: 6, expected: 5, elapsed: 1.0, timeout: 10), .ready)
    }

    /// On timeout the transaction is abandoned rather than played. The playlist
    /// survives for the sweep; a half-materialized play is worse than none.
    func testReadinessTimesOutRatherThanPlayingPartial() {
        XCTAssertEqual(discoverReadiness(observed: 2, expected: 5, elapsed: 10.0, timeout: 10), .timedOut)
    }

    // MARK: - Play-from-here slicing

    /// "Play from here" is the same bounded transaction as "play all", with a
    /// shorter id list: the container is sliced from the selected row to its
    /// end and played from ITS beginning. This is what dissolves the old
    /// deferral reason ("the only bounded mechanism starts a playlist from
    /// its beginning") — the slice's beginning IS the selected track.
    func testSliceFromMiddleKeepsSelectedTrackFirst() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(discoverPlaySlice(catalogIDs: ids, from: 2), ["c", "d", "e"])
    }

    /// Selecting the first row is "play all" by another name.
    func testSliceFromZeroIsTheWholeContainer() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(discoverPlaySlice(catalogIDs: ids, from: 0), ids)
    }

    /// The last row plays exactly one track and then stops.
    func testSliceFromLastRowIsASingleTrack() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(discoverPlaySlice(catalogIDs: ids, from: 2), ["c"])
    }

    /// An out-of-range index yields nothing rather than silently starting at
    /// position 1 — playing a DIFFERENT song than the one chosen is the exact
    /// failure the design doc refuses ("report and play nothing").
    func testSliceRefusesAnOutOfRangeIndex() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(discoverPlaySlice(catalogIDs: ids, from: 3), [])
        XCTAssertEqual(discoverPlaySlice(catalogIDs: ids, from: 99), [])
        XCTAssertEqual(discoverPlaySlice(catalogIDs: ids, from: -1), [])
    }

    /// An empty container has nothing to slice; the caller's non-empty guard
    /// then refuses the play.
    func testSliceOfAnEmptyContainerIsEmpty() {
        XCTAssertEqual(discoverPlaySlice(catalogIDs: [], from: 0), [])
    }

    // MARK: - Play script ordering (the shuffle guard)

    /// Track-level Enter promises the SELECTED track starts. `play playlist`
    /// honours Music's `shuffle enabled` (measured 2026-08-30, six trials:
    /// with shuffle on, three plays of a 275-track playlist started on three
    /// different non-first tracks; with it off, three plays started on track 1
    /// every time). So the guard has to precede the play, or the promise is
    /// broken by a setting the user turned on somewhere else entirely.
    func testShuffleIsDisabledBeforeThePlayWhenGuarded() {
        let scripts = discoverPlayScripts(playlistName: "__discover__ x", disableShuffle: true)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(scripts[0], "set shuffle enabled to false")
        XCTAssertTrue(scripts[1].hasPrefix("play playlist "))
    }

    /// `p` (play all) is deliberately UNCHANGED — the producer scoped the
    /// shuffle guard to track-level Enter alone. An unguarded play emits the
    /// play and nothing else, so a `p` user who turned shuffle on still gets
    /// a shuffled album, exactly as before this feature landed.
    func testUnguardedPlayEmitsOnlyThePlay() {
        let scripts = discoverPlayScripts(playlistName: "__discover__ x", disableShuffle: false)
        XCTAssertEqual(scripts, ["play playlist \"__discover__ x\""])
    }

    /// The two commands stay SEPARATE scripts. Combining them into one
    /// `tell` block is what produced parameter error -50 in the shipped
    /// playlist code (see PlaylistCommands' "Split into separate calls"), so
    /// this is a regression guard on a bug the project already paid for.
    func testGuardAndPlayAreSeparateScriptsNotOneBlock() {
        let scripts = discoverPlayScripts(playlistName: "p", disableShuffle: true)
        for script in scripts {
            XCTAssertFalse(script.contains("\n"), "scripts must stay separate runMusic calls")
        }
    }

    /// A quote in a title must not break out of the AppleScript string. Reuses
    /// the codebase's existing escaper rather than a second one.
    func testPlaylistNameIsEscaped() {
        let scripts = discoverPlayScripts(playlistName: "a\"b", disableShuffle: false)
        XCTAssertEqual(scripts, ["play playlist \"a\\\"b\""])
    }
}
