import XCTest
@testable import music

final class PlaylistBrowserModelTests: XCTestCase {
    // badge derivation
    func testRecentBadgeFromKnownName() {
        XCTAssertEqual(playlistBadge(name: "Recently Played", isSmart: true, specialKind: "Music"), .recent)
        XCTAssertEqual(playlistBadge(name: "Top 25 Most Played", isSmart: true, specialKind: "Music"), .recent)
    }
    func testSmartBadge() {
        XCTAssertEqual(playlistBadge(name: "Deep House Finds", isSmart: true, specialKind: "none"), .smart)
    }
    func testNoneBadgeForPlainUserPlaylist() {
        XCTAssertEqual(playlistBadge(name: "Bluecoats 2024", isSmart: false, specialKind: "none"), .none)
    }
    func testAppleBadgeForSubscriptionPlaylist() {
        XCTAssertEqual(playlistBadge(name: "Loops", isSmart: false, specialKind: "none", isSubscription: true), .apple)
    }
    func testAppleWinsOverSmart() {
        // `smart` errors on subscription playlists and defaults false, but if a
        // future read ever reports true, the Apple identity is the useful badge.
        XCTAssertEqual(playlistBadge(name: "Replay 2022", isSmart: true, specialKind: "none", isSubscription: true), .apple)
    }
    func testRecentWinsOverApple() {
        XCTAssertEqual(playlistBadge(name: "Recently Played", isSmart: false, specialKind: "none", isSubscription: true), .recent)
    }

    // subscription-aware rail fetch parsing
    func testParseRailNamesSplitsUserAndSubscription() {
        let raw = "U\u{1F}Working Vibes\nS\u{1F}Loops\nU\u{1F}__queue__ leftover\nS\u{1F}Replay 2022\n"
        let parsed = parseRailPlaylistNames(raw)
        XCTAssertEqual(parsed.names, ["Working Vibes", "Loops", "Replay 2022"])
        XCTAssertEqual(parsed.subscription, ["Loops", "Replay 2022"])
    }
    func testParseRailNamesTolerantOfMalformedLines() {
        let raw = "garbage-no-sep\nU\u{1F}Real One\n\n"
        let parsed = parseRailPlaylistNames(raw)
        XCTAssertEqual(parsed.names, ["Real One"])
        XCTAssertTrue(parsed.subscription.isEmpty)
    }

    // duration formatting
    func testFormatDurationHoursAndMinutes() {
        XCTAssertEqual(formatPlaylistDuration(15132), "4h 12m")
    }
    func testFormatDurationMinutesOnly() {
        XCTAssertEqual(formatPlaylistDuration(360), "6m")
    }
    func testFormatDurationZero() {
        XCTAssertEqual(formatPlaylistDuration(0), "0m")
    }
    func testFormatDurationRoundsDownToMinute() {
        XCTAssertEqual(formatPlaylistDuration(59), "0m")
    }

    // zone layout
    func testThreeZonesWhenWide() {
        let z = playlistZones(width: 188)
        XCTAssertEqual(z.mode, .three)
        XCTAssertGreaterThanOrEqual(z.railWidth, 30)
        XCTAssertNotNil(z.rightX)
        XCTAssertGreaterThan(z.heroX, z.railX + z.railWidth)
        XCTAssertGreaterThan(z.rightX!, z.heroX + z.heroWidth)
    }
    func testTwoZonesMidWidth() {
        let z = playlistZones(width: 120)
        XCTAssertEqual(z.mode, .two)
        XCTAssertNil(z.rightX)
    }
    func testOneZoneNarrow() {
        let z = playlistZones(width: 80)
        XCTAssertEqual(z.mode, .one)
        XCTAssertNil(z.rightX)
    }

    // gradient determinism
    func testGradientDeterministicAndSized() {
        let a = gradientBlock(name: "House Classics", width: 12, height: 5)
        let b = gradientBlock(name: "House Classics", width: 12, height: 5)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 5)
    }
    func testGradientDiffersByName() {
        let a = gradientBlock(name: "House Classics", width: 12, height: 5)
        let c = gradientBlock(name: "Jazz Nights", width: 12, height: 5)
        XCTAssertNotEqual(a, c)
    }

    // rail name truncation
    func testRailNameTruncatesWithEllipsis() {
        let r = railName("A Very Long Playlist Name That Overflows", nameWidth: 10)
        XCTAssertEqual(r.count, 10)
        XCTAssertTrue(r.hasSuffix("\u{2026}"))
    }
    func testRailNameShortUnchanged() {
        XCTAssertEqual(railName("Short", nameWidth: 10), "Short")
    }
}
