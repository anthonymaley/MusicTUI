// tools/music/Tests/MusicTests/NowPlayingLayoutTests.swift
import XCTest
@testable import music

/// nowPlayingLeftWidth: the Now tab's two-pane left column width. Floors at
/// 44 (the pre-existing width at the twoPane threshold, frameWidth 92) and
/// scales up to 54 (the hero tabs' width) by frameWidth 180, so wide
/// terminals get Now's art sized identically to Library/Playlists/Radio.
final class NowPlayingLayoutTests: XCTestCase {

    func testFloorsAtFortyFourAtTwoPaneThreshold() {
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 92), 44)
    }

    func testFloorsAtFortyFourBelowTwoPaneThreshold() {
        // Callers don't actually invoke this below 92 (one-pane uses
        // `frame.width - 6` instead), but the function itself should still
        // clamp rather than go negative or below the floor.
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 50), 44)
    }

    func testCapsAtFiftyFourOnTheUsersTerminalWidth() {
        // The user's actual terminal: 214 columns. This must match the hero
        // tabs' art width (54) exactly per the task spec.
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 214), 54)
    }

    func testCapsAtFiftyFourAtAndAboveMaxWidth() {
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 180), 54)
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 400), 54)
    }

    func testScalesMonotonicallyBetweenFloorAndCap() {
        var previous = nowPlayingLeftWidth(frameWidth: 92)
        for w in stride(from: 92, through: 180, by: 4) {
            let current = nowPlayingLeftWidth(frameWidth: w)
            XCTAssertGreaterThanOrEqual(current, previous, "width \(w) regressed vs a narrower width")
            XCTAssertGreaterThanOrEqual(current, 44)
            XCTAssertLessThanOrEqual(current, 54)
            previous = current
        }
    }

    // At the twoPane boundary (92), a fixed 54-wide left column would leave
    // the Up Next list only ~34 columns (92 - 3 - 54 - 2 - 1). Confirm the
    // adaptive width doesn't regress that: at 92 it must still be 44, exactly
    // what it was before this fix, so the list keeps the room it always had.
    func testNarrowTwoPaneDoesNotSqueezeTheList() {
        let leftW = nowPlayingLeftWidth(frameWidth: 92)
        let listX = 3 + leftW + 2
        let listW = 92 - listX - 1
        XCTAssertEqual(leftW, 44)
        XCTAssertGreaterThanOrEqual(listW, 40, "Up Next list squeezed too narrow at the twoPane boundary")
    }
}
