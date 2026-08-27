import XCTest
@testable import music

final class DiscoverLayoutTests: XCTestCase {
    private func item(_ detail: DiscoverItemDetail, _ name: String = "n") -> DiscoverItem {
        DiscoverItem(id: name, name: name, subtitle: nil, url: nil, artworkURL: nil, detail: detail)
    }

    private func rail(_ n: Int) -> DiscoverRail {
        DiscoverRail(id: "r", title: "R",
                 items: (0..<n).map { item(.album(trackCount: nil, year: nil, genre: nil), "i\($0)") },
                 isRecentlyPlayed: false, resourceTypes: ["albums"])
    }

    // MARK: - Widths

    /// Same breakpoint as the Now tab (NowPlayingScene.swift:347) so the two
    /// designed scenes agree on when a second pane is affordable.
    func testTwoPaneStartsAt92Columns() {
        XCTAssertFalse(discoverIsTwoPane(width: 91))
        XCTAssertTrue(discoverIsTwoPane(width: 92))
    }

    func testLeftWidthInterpolatesAndClamps() {
        XCTAssertEqual(discoverLeftWidth(frameWidth: 92), 56)
        XCTAssertEqual(discoverLeftWidth(frameWidth: 180), 88)
        XCTAssertEqual(discoverLeftWidth(frameWidth: 400), 88, "clamped at the top")
        let mid = discoverLeftWidth(frameWidth: 136)
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
    /// `View all` row (30 rows from discoverDisplayRows), plus a spacer between
    /// rails (4, not 5 — no trailing spacer), plus the scene's own chrome: the
    /// "Discover" heading and the blank line under it, which renderRails consumes
    /// before any rail is drawn and which discoverDisplayRows knows nothing about.
    ///
    /// 30 + 4 + 2 = 36. An earlier draft of the spec compared this against raw
    /// terminal height rather than bodyHeight and concluded a 30-row terminal
    /// scrolled six rows; it scrolls ten.
    func testFullDiscoverIsThirtySixRowsAndFitsAtHeightForty() {
        let rails = (0..<5).map { _ in rail(8) }
        let rows = discoverDisplayRows(rails: rails, perRail: 4)
        let spacersBetweenRails = rails.count - 1
        let sceneChrome = 2   // the "Discover" heading and its blank line
        XCTAssertEqual(rows.count + spacersBetweenRails + sceneChrome, 36)
        XCTAssertLessThanOrEqual(36, shellLayout(width: 150, height: 40).bodyHeight)
        XCTAssertGreaterThan(36, shellLayout(width: 150, height: 30).bodyHeight)
    }

    // MARK: - Footer

    /// Enter Play/Open was ambiguous exactly where the tab needs honesty: a
    /// station listens, an album only opens a read-only track list.
    func testFooterNamesTheRealActionPerSelection() {
        XCTAssertTrue(discoverFooterHint(.item(item(.station(isLive: false))), canGoBack: false, canRefresh: true)
            .contains("Enter Listen"))
        XCTAssertTrue(discoverFooterHint(.item(item(.album(trackCount: 5, year: 1992, genre: "House"))),
                                     canGoBack: false, canRefresh: true).contains("Enter Browse"))
        XCTAssertTrue(discoverFooterHint(.item(item(.playlist(description: nil))), canGoBack: false, canRefresh: true)
            .contains("Enter Browse"))
        XCTAssertTrue(discoverFooterHint(.viewAll(rail(9)), canGoBack: false, canRefresh: true).contains("Enter View all"))
    }

    func testFooterShowsBackOnlyBelowTheTopLevel() {
        XCTAssertFalse(discoverFooterHint(.item(item(.song)), canGoBack: false, canRefresh: true).contains("Back"))
        XCTAssertTrue(discoverFooterHint(.item(item(.song)), canGoBack: true, canRefresh: true).contains("Back"))
    }

    func testFooterIsSafeWithNothingSelected() {
        XCTAssertFalse(discoverFooterHint(nil, canGoBack: false, canRefresh: true).isEmpty)
    }

    /// `r` is guarded to the Discover level in DiscoverScene.handle() because refresh()
    /// resets the whole navigation stack — advertising it inside a rail or
    /// track list would promise an action the app silently ignores (worse: if
    /// it WERE allowed there, it would teleport the user back to Discover without
    /// warning). The footer must show `r Refresh` exactly when the level
    /// actually accepts it, regardless of what is selected.
    /// `p` plays the container only from a rail row (album/playlist) — never
    /// on a station, `View all`, or track row, where DiscoverScene's `p`
    /// handler is a no-op (a track row has no play action of its own; there
    /// is no per-track play path). This repo has already shipped a footer
    /// that advertised a key the handler ignored; this test is the guard
    /// against doing it again.
    func testFooterAdvertisesPOnlyWhereItActs() {
        XCTAssertFalse(discoverFooterHint(.item(item(.station(isLive: false))), canGoBack: false, canRefresh: true)
            .contains("p Play"), "station: Enter already plays; p does nothing")
        XCTAssertTrue(discoverFooterHint(.item(item(.album(trackCount: nil, year: nil, genre: nil))),
                                         canGoBack: false, canRefresh: true).contains("p Play"))
        XCTAssertTrue(discoverFooterHint(.item(item(.playlist(description: nil))), canGoBack: false, canRefresh: true)
            .contains("p Play"))
        XCTAssertFalse(discoverFooterHint(.item(item(.song)), canGoBack: true, canRefresh: true).contains("p Play"),
                       "track row: no per-track play path; p does nothing here")
        XCTAssertFalse(discoverFooterHint(.viewAll(rail(9)), canGoBack: false, canRefresh: true).contains("p Play"),
                       "View all: nothing to play at this row")
        XCTAssertFalse(discoverFooterHint(nil, canGoBack: false, canRefresh: true).contains("p Play"))
    }

    /// The track row's exact footer text the spec names verbatim: bare
    /// movement plus Back, since neither Enter nor p acts on a track row.
    func testTrackRowFooterMatchesTheAgreedGrammar() {
        XCTAssertEqual(discoverFooterHint(.item(item(.song)), canGoBack: true, canRefresh: true),
                       "\u{2191}\u{2193} Move  \u{2190} Back")
    }

    func testFooterShowsRefreshOnlyWhenCanRefreshIsTrue() {
        XCTAssertTrue(discoverFooterHint(.item(item(.station(isLive: false))), canGoBack: false, canRefresh: true)
            .contains("r Refresh"))
        XCTAssertFalse(discoverFooterHint(.item(item(.station(isLive: false))), canGoBack: false, canRefresh: false)
            .contains("r Refresh"))
        XCTAssertTrue(discoverFooterHint(.viewAll(rail(9)), canGoBack: true, canRefresh: true).contains("r Refresh"))
        XCTAssertFalse(discoverFooterHint(.viewAll(rail(9)), canGoBack: true, canRefresh: false).contains("r Refresh"))
        XCTAssertTrue(discoverFooterHint(nil, canGoBack: false, canRefresh: true).contains("r Refresh"))
        XCTAssertFalse(discoverFooterHint(nil, canGoBack: false, canRefresh: false).contains("r Refresh"))
    }

    // MARK: - Panel

    func testAlbumPanelJoinsOnlyThePartsPresent() {
        XCTAssertEqual(discoverPanelMeta(.album(trackCount: 5, year: 1992, genre: "House")),
                       "5 tracks · 1992 · House")
        XCTAssertEqual(discoverPanelMeta(.album(trackCount: 1, year: nil, genre: nil)), "1 track")
        XCTAssertNil(discoverPanelMeta(.album(trackCount: nil, year: nil, genre: nil)))
    }

    /// Playlists carry no trackCount, so they show description. User-authored
    /// playlists carry neither and must not render a blank block.
    func testPlaylistPanelUsesDescriptionAndDegrades() {
        XCTAssertEqual(discoverPanelMeta(.playlist(description: "The ones you play.")),
                       "The ones you play.")
        XCTAssertNil(discoverPanelMeta(.playlist(description: nil)))
    }

    /// An empty description is "absent", not "present and blank". Apple can
    /// return {"standard": ""} for a field that exists but has no content, and
    /// Some("") would render a blank line in the panel rather than nothing.
    func testPlaylistPanelTreatsAnEmptyDescriptionAsAbsent() {
        XCTAssertNil(discoverPanelMeta(.playlist(description: "")))
    }

    /// ra.u- is an observed id prefix, not a documented contract, so PERSONAL
    /// is deliberately not product language. Only LIVE and STATION ship.
    func testStationBadgeIsOnlyLiveOrStation() {
        XCTAssertEqual(discoverPanelBadge(.station(isLive: true)), "LIVE")
        XCTAssertEqual(discoverPanelBadge(.station(isLive: false)), "STATION")
        XCTAssertEqual(discoverPanelBadge(.album(trackCount: nil, year: nil, genre: nil)), "ALBUM")
        XCTAssertEqual(discoverPanelBadge(.playlist(description: nil)), "PLAYLIST")
    }

    /// A marker or action on a row that cannot play is a promise the tab cannot
    /// keep. The panel's action line obeys the same rule as the play marker.
    func testPanelActionNeverPromisesPlayOnANonStation() {
        XCTAssertEqual(discoverPanelAction(.item(item(.station(isLive: false)))), "Enter  Listen")
        XCTAssertEqual(discoverPanelAction(.item(item(.album(trackCount: nil, year: nil, genre: nil)))),
                       "Enter  Browse tracks")
        XCTAssertEqual(discoverPanelAction(.viewAll(rail(11))), "Enter  View all 11")
    }

    // MARK: - Wrap text

    /// A single word wider than the panel must be truncated to fit, not
    /// carried through unclamped past the column — playlist descriptions are
    /// API text and a long URL or hashtag run is realistic. Also proves the
    /// overflow branch does not emit a leading blank line for the word that
    /// triggered it.
    func testWrapTextTruncatesAWordLongerThanWidth() {
        XCTAssertEqual(discoverWrapText("aaaaaaaaaa", to: 5, maxLines: 4), ["aaaa\u{2026}"])
    }

    /// Ordinary short words wrap at the column, none of them clipped, because
    /// every word fits and nothing runs past maxLines.
    func testWrapTextWrapsOrdinaryWordsAcrossLines() {
        XCTAssertEqual(discoverWrapText("the quick brown fox jumps", to: 11, maxLines: 5),
                       ["the quick", "brown fox", "jumps"])
    }

    /// maxLines caps the line count exactly, and the last kept line carries a
    /// visible clip marker so the cut reads as clipped, not as complete text.
    func testWrapTextRespectsMaxLinesAndMarksTheCut() {
        let result = discoverWrapText("one two three four five six", to: 8, maxLines: 2)
        XCTAssertEqual(result, ["one two", "three\u{2026}"])
        XCTAssertEqual(result.count, 2)
    }

    func testWrapTextOfEmptyStringIsEmpty() {
        XCTAssertEqual(discoverWrapText("", to: 20, maxLines: 4), [])
    }

    // MARK: - Row columns

    /// With a subtitle, it gets a third of the usable width and the name
    /// takes the rest; without one, the name gets everything.
    func testRowColumnsSplitsWidthWhenSubtitlePresent() {
        let cols = discoverRowColumns(width: 80, hasSubtitle: true)
        XCTAssertEqual(cols.subW, 24)
        XCTAssertEqual(cols.nameW, 48)
    }

    func testRowColumnsGivesTheNameEverythingWithNoSubtitle() {
        let cols = discoverRowColumns(width: 80, hasSubtitle: false)
        XCTAssertEqual(cols.subW, 0)
        XCTAssertEqual(cols.nameW, 72)
    }

    /// The name column has a 12-column floor regardless of how narrow the
    /// pane gets, so a subtitle can never squeeze the title unreadable.
    func testRowColumnsClampsNameWidthToAFloorOfTwelve() {
        let cols = discoverRowColumns(width: 20, hasSubtitle: true)
        XCTAssertEqual(cols.subW, 4)
        XCTAssertEqual(cols.nameW, 12)
    }

    // MARK: - Right arrow

    /// → drills in like Enter, but never plays: the convention LibraryScene
    /// and PlaylistsScene both document (LibraryScene.swift:485,
    /// PlaylistsScene.swift:345). A station's Enter means Listen, so → must
    /// stay a no-op there — otherwise an arrow key starts playback and pulls
    /// Music.app to the front, which is the bug this guards against.
    func testRightArrowDrillsInButNeverPlays() {
        XCTAssertTrue(discoverRightArrowActivates(.item(item(.album(trackCount: nil, year: nil, genre: nil)))),
                      "album: → drills in")
        XCTAssertTrue(discoverRightArrowActivates(.item(item(.playlist(description: nil)))),
                      "playlist: → drills in")
        XCTAssertTrue(discoverRightArrowActivates(.viewAll(rail(9))),
                      "View all: → drills in")
        XCTAssertFalse(discoverRightArrowActivates(.item(item(.station(isLive: false)))),
                       "station: Enter means Listen, so → must not fire it")
        XCTAssertFalse(discoverRightArrowActivates(.item(item(.song))),
                       "song: already a no-op on Enter")
        XCTAssertFalse(discoverRightArrowActivates(nil))
    }
}
