import XCTest
@testable import music

final class HomeLayoutTests: XCTestCase {
    private func item(_ detail: HomeItemDetail, _ name: String = "n") -> HomeItem {
        HomeItem(id: name, name: name, subtitle: nil, url: nil, artworkURL: nil, detail: detail)
    }

    private func rail(_ n: Int) -> HomeRail {
        HomeRail(id: "r", title: "R",
                 items: (0..<n).map { item(.album(trackCount: nil, year: nil, genre: nil), "i\($0)") },
                 isRecentlyPlayed: false, resourceTypes: ["albums"])
    }

    // MARK: - Widths

    /// Same breakpoint as the Now tab (NowPlayingScene.swift:347) so the two
    /// designed scenes agree on when a second pane is affordable.
    func testTwoPaneStartsAt92Columns() {
        XCTAssertFalse(homeIsTwoPane(width: 91))
        XCTAssertTrue(homeIsTwoPane(width: 92))
    }

    func testLeftWidthInterpolatesAndClamps() {
        XCTAssertEqual(homeLeftWidth(frameWidth: 92), 56)
        XCTAssertEqual(homeLeftWidth(frameWidth: 180), 88)
        XCTAssertEqual(homeLeftWidth(frameWidth: 400), 88, "clamped at the top")
        let mid = homeLeftWidth(frameWidth: 136)
        XCTAssertTrue(mid > 56 && mid < 88, "interpolates between the ends, got \(mid)")
    }

    // MARK: - Row budget against real shell geometry

    /// Measure against bodyHeight, never against terminal height: shellLayout
    /// reserves labelY/tabsY/ruleY above and the footer below, so
    /// bodyHeight == height - 4. An earlier spec draft compared 36 rows against
    /// raw height and concluded a 30-row terminal scrolled six rows; it scrolls ten.
    func testRowBudgetAgainstRealBodyHeight() {
        XCTAssertEqual(shellLayout(width: 150, height: 48).bodyHeight, 44)
        XCTAssertEqual(shellLayout(width: 150, height: 40).bodyHeight, 36)
        XCTAssertEqual(shellLayout(width: 150, height: 30).bodyHeight, 26)
    }

    /// The dashboard's full row budget, measured against real shell geometry.
    ///
    /// Five rails of four items, each contributing a header, its items and a
    /// `View all` row (30 rows from homeDisplayRows), plus a spacer between
    /// rails (4, not 5 — no trailing spacer), plus the scene's own chrome: the
    /// "Home" heading and the blank line under it, which renderRails consumes
    /// before any rail is drawn and which homeDisplayRows knows nothing about.
    ///
    /// 30 + 4 + 2 = 36. An earlier draft of the spec compared this against raw
    /// terminal height rather than bodyHeight and concluded a 30-row terminal
    /// scrolled six rows; it scrolls ten.
    func testFullHomeIsThirtySixRowsAndFitsAtHeightForty() {
        let rails = (0..<5).map { _ in rail(8) }
        let rows = homeDisplayRows(rails: rails, perRail: 4)
        let spacersBetweenRails = rails.count - 1
        let sceneChrome = 2   // the "Home" heading and its blank line
        XCTAssertEqual(rows.count + spacersBetweenRails + sceneChrome, 36)
        XCTAssertLessThanOrEqual(36, shellLayout(width: 150, height: 40).bodyHeight)
        XCTAssertGreaterThan(36, shellLayout(width: 150, height: 30).bodyHeight)
    }

    // MARK: - Footer

    /// Enter Play/Open was ambiguous exactly where the tab needs honesty: a
    /// station listens, an album only opens a read-only track list.
    func testFooterNamesTheRealActionPerSelection() {
        XCTAssertTrue(homeFooterHint(.item(item(.station(isLive: false))), canGoBack: false)
            .contains("Enter Listen"))
        XCTAssertTrue(homeFooterHint(.item(item(.album(trackCount: 5, year: 1992, genre: "House"))),
                                     canGoBack: false).contains("Enter Browse"))
        XCTAssertTrue(homeFooterHint(.item(item(.playlist(description: nil))), canGoBack: false)
            .contains("Enter Browse"))
        XCTAssertTrue(homeFooterHint(.viewAll(rail(9)), canGoBack: false).contains("Enter View all"))
    }

    func testFooterShowsBackOnlyBelowTheTopLevel() {
        XCTAssertFalse(homeFooterHint(.item(item(.song)), canGoBack: false).contains("Back"))
        XCTAssertTrue(homeFooterHint(.item(item(.song)), canGoBack: true).contains("Back"))
    }

    func testFooterIsSafeWithNothingSelected() {
        XCTAssertFalse(homeFooterHint(nil, canGoBack: false).isEmpty)
    }

    // MARK: - Panel

    func testAlbumPanelJoinsOnlyThePartsPresent() {
        XCTAssertEqual(homePanelMeta(.album(trackCount: 5, year: 1992, genre: "House")),
                       "5 tracks · 1992 · House")
        XCTAssertEqual(homePanelMeta(.album(trackCount: 1, year: nil, genre: nil)), "1 track")
        XCTAssertNil(homePanelMeta(.album(trackCount: nil, year: nil, genre: nil)))
    }

    /// Playlists carry no trackCount, so they show description. User-authored
    /// playlists carry neither and must not render a blank block.
    func testPlaylistPanelUsesDescriptionAndDegrades() {
        XCTAssertEqual(homePanelMeta(.playlist(description: "The ones you play.")),
                       "The ones you play.")
        XCTAssertNil(homePanelMeta(.playlist(description: nil)))
    }

    /// An empty description is "absent", not "present and blank". Apple can
    /// return {"standard": ""} for a field that exists but has no content, and
    /// Some("") would render a blank line in the panel rather than nothing.
    func testPlaylistPanelTreatsAnEmptyDescriptionAsAbsent() {
        XCTAssertNil(homePanelMeta(.playlist(description: "")))
    }

    /// ra.u- is an observed id prefix, not a documented contract, so PERSONAL
    /// is deliberately not product language. Only LIVE and STATION ship.
    func testStationBadgeIsOnlyLiveOrStation() {
        XCTAssertEqual(homePanelBadge(.station(isLive: true)), "LIVE")
        XCTAssertEqual(homePanelBadge(.station(isLive: false)), "STATION")
        XCTAssertEqual(homePanelBadge(.album(trackCount: nil, year: nil, genre: nil)), "ALBUM")
        XCTAssertEqual(homePanelBadge(.playlist(description: nil)), "PLAYLIST")
    }

    /// A marker or action on a row that cannot play is a promise the tab cannot
    /// keep. The panel's action line obeys the same rule as the play marker.
    func testPanelActionNeverPromisesPlayOnANonStation() {
        XCTAssertEqual(homePanelAction(.item(item(.station(isLive: false)))), "Enter  Listen")
        XCTAssertEqual(homePanelAction(.item(item(.album(trackCount: nil, year: nil, genre: nil)))),
                       "Enter  Browse tracks")
        XCTAssertEqual(homePanelAction(.viewAll(rail(11))), "Enter  View all 11")
    }

    // MARK: - Wrap text

    /// A single word wider than the panel must be truncated to fit, not
    /// carried through unclamped past the column — playlist descriptions are
    /// API text and a long URL or hashtag run is realistic. Also proves the
    /// overflow branch does not emit a leading blank line for the word that
    /// triggered it.
    func testWrapTextTruncatesAWordLongerThanWidth() {
        XCTAssertEqual(homeWrapText("aaaaaaaaaa", to: 5, maxLines: 4), ["aaaa\u{2026}"])
    }

    /// Ordinary short words wrap at the column, none of them clipped, because
    /// every word fits and nothing runs past maxLines.
    func testWrapTextWrapsOrdinaryWordsAcrossLines() {
        XCTAssertEqual(homeWrapText("the quick brown fox jumps", to: 11, maxLines: 5),
                       ["the quick", "brown fox", "jumps"])
    }

    /// maxLines caps the line count exactly, and the last kept line carries a
    /// visible clip marker so the cut reads as clipped, not as complete text.
    func testWrapTextRespectsMaxLinesAndMarksTheCut() {
        let result = homeWrapText("one two three four five six", to: 8, maxLines: 2)
        XCTAssertEqual(result, ["one two", "three\u{2026}"])
        XCTAssertEqual(result.count, 2)
    }

    func testWrapTextOfEmptyStringIsEmpty() {
        XCTAssertEqual(homeWrapText("", to: 20, maxLines: 4), [])
    }

    // MARK: - Row columns

    /// With a subtitle, it gets a third of the usable width and the name
    /// takes the rest; without one, the name gets everything.
    func testRowColumnsSplitsWidthWhenSubtitlePresent() {
        let cols = homeRowColumns(width: 80, hasSubtitle: true)
        XCTAssertEqual(cols.subW, 24)
        XCTAssertEqual(cols.nameW, 48)
    }

    func testRowColumnsGivesTheNameEverythingWithNoSubtitle() {
        let cols = homeRowColumns(width: 80, hasSubtitle: false)
        XCTAssertEqual(cols.subW, 0)
        XCTAssertEqual(cols.nameW, 72)
    }

    /// The name column has a 12-column floor regardless of how narrow the
    /// pane gets, so a subtitle can never squeeze the title unreadable.
    func testRowColumnsClampsNameWidthToAFloorOfTwelve() {
        let cols = homeRowColumns(width: 20, hasSubtitle: true)
        XCTAssertEqual(cols.subW, 4)
        XCTAssertEqual(cols.nameW, 12)
    }
}
