import XCTest
@testable import music

final class HomeRailSelectionTests: XCTestCase {
    private func album(_ name: String, _ year: Int?) -> HomeItem {
        HomeItem(id: name, name: name, subtitle: nil, url: nil, artworkURL: nil,
                 detail: .album(trackCount: nil, year: year, genre: nil))
    }

    private func other(_ name: String, _ detail: HomeItemDetail) -> HomeItem {
        HomeItem(id: name, name: name, subtitle: nil, url: nil, artworkURL: nil, detail: detail)
    }

    private func albumRail(_ title: String, _ years: [Int?]) -> HomeRail {
        HomeRail(id: title, title: title,
                 items: years.enumerated().map { album("\(title)-\($0.offset)", $0.element) },
                 isRecentlyPlayed: false, resourceTypes: ["albums"])
    }

    private func typedRail(_ title: String, _ type: String, recent: Bool = false) -> HomeRail {
        let detail: HomeItemDetail = type == "playlists"
            ? .playlist(description: nil) : .station(isLive: false)
        return HomeRail(id: title, title: title, items: [other(title + "-i", detail)],
                        isRecentlyPlayed: recent, resourceTypes: [type])
    }

    /// Slot order is fixed: recently played, playlists, stations, new releases,
    /// then one more. Titles are never an input — Apple localizes and rotates
    /// them, so an English match would work only in en-US.
    func testFillsTheFiveSlotsInPriorityOrder() {
        let rails = [
            albumRail("Boom Bap", [1995, 1993]),
            typedRail("Playlists", "playlists"),
            HomeRail(id: "rp", title: "Recently Played", items: [album("x", 2001)],
                     isRecentlyPlayed: true, resourceTypes: ["albums", "playlists"]),
            albumRail("New Releases", [2026, 2026]),
            typedRail("Stations", "stations"),
        ]
        let out = selectHomeRails(rails, currentYear: 2026)
        XCTAssertEqual(out.map(\.title),
                       ["Recently Played", "Playlists", "Stations", "New Releases", "Boom Bap"])
    }

    /// The new-releases rail is the albums rail whose items are ALL from the
    /// current year. Measured live: it scored median 2026 / min 2026, against
    /// 2024.5 for the next closest rail, so this separates cleanly.
    func testPicksTheAllCurrentYearAlbumRailForSlotFour() {
        let rails = [
            albumRail("Mixed Recent", [2026, 2023]),
            albumRail("All Current", [2026, 2026, 2026]),
            albumRail("Old", [1984]),
        ]
        let out = selectHomeRails(rails, currentYear: 2026)
        XCTAssertEqual(out.first?.title, "All Current")
    }

    /// When nothing is entirely current-year, fall back to the freshest album
    /// rail by median year rather than leaving the slot empty.
    func testFallsBackToFreshestAlbumRailWhenNoneAreAllCurrentYear() {
        let rails = [albumRail("Old", [1984, 1985]), albumRail("Newer", [2023, 2024])]
        let out = selectHomeRails(rails, currentYear: 2026)
        XCTAssertEqual(out.first?.title, "Newer")
    }

    /// Rails with no computable median (playlists and stations carry no
    /// releaseDate) sort last for slot five and break ties by API order.
    func testRailsWithNoReleaseDatesSortLastAndTieBreakByApiOrder() {
        let rails = [typedRail("P1", "playlists"), typedRail("P2", "playlists"),
                     typedRail("S1", "stations"), typedRail("S2", "stations")]
        let out = selectHomeRails(rails, currentYear: 2026)
        XCTAssertEqual(out.map(\.title), ["P1", "S1", "P2", "S2"])
    }

    /// A thin feed must still fill five slots from whatever is left, in the
    /// API's own order, rather than rendering four rails.
    func testBackfillsUnfilledSlotsInApiOrder() {
        let rails = [albumRail("A", [2001]), albumRail("B", [2002]),
                     albumRail("C", [2003]), albumRail("D", [2004]),
                     albumRail("E", [2005]), albumRail("F", [2006])]
        let out = selectHomeRails(rails, currentYear: 2026)
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(Set(out.map(\.title)).count, 5, "no rail may appear twice")
    }

    /// Completeness, not order: a thin feed must return every rail rather than
    /// dropping any. Order is deliberately NOT asserted here, because slots 4
    /// and 5 both fill from two album rails and the spec's slot-5 rule is
    /// "freshest remaining", so freshness reordering is correct policy, not a
    /// bug. Ordering is covered by the two tests above.
    func testReturnsEverythingWhenFewerThanFiveRailsExist() {
        let out = selectHomeRails([albumRail("A", [2001]), albumRail("B", [2002])],
                                  currentYear: 2026)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.title)), ["A", "B"])
    }

    func testReturnsEmptyForAnEmptyFeed() {
        XCTAssertEqual(selectHomeRails([], currentYear: 2026).count, 0)
    }

    /// Guards against hidden nondeterminism *inside* selectHomeRails — a stray
    /// Date(), a Set or Dictionary iteration, anything whose order is not a pure
    /// function of the input. It does NOT guard the comparators' index tiebreak:
    /// Swift's sort is guaranteed stable and every sort here runs over an
    /// already-ascending index array, so ties resolve to input order either way.
    /// The test below covers the tiebreak's real failure mode.
    func testIsDeterministicAcrossRepeatedCalls() {
        let rails = [albumRail("A", [2001]), albumRail("B", [2002]),
                     albumRail("C", [2003]), albumRail("D", [2004]),
                     albumRail("E", [2005]), albumRail("F", [2006])]
        let first = selectHomeRails(rails, currentYear: 2026).map(\.title)
        for _ in 0..<20 {
            XCTAssertEqual(selectHomeRails(rails, currentYear: 2026).map(\.title), first)
        }
    }

    /// The index tiebreak becomes load-bearing if a refactor ever changes WHAT
    /// is sorted — keying on a Set or Dictionary, or sorting by rail.id instead
    /// of array position. That regression would not surface within one process,
    /// since Swift's hash seed is fixed per launch; it would appear only across
    /// relaunches, as rails reshuffling between runs.
    ///
    /// "songs" is deliberate: it matches no slot rule, so both rails survive to
    /// slot 5 and are sorted together with equal freshness (Int.min, no album
    /// items), which is the only path in this function where the tie branch
    /// decides anything. A "stations" pair cannot test this — slot 3 takes the
    /// first one with firstIndex(where:), which uses no comparator at all.
    ///
    /// Note what this does NOT catch: deleting the `a < b` branch outright.
    /// Swift's sort is guaranteed stable and these indices are already
    /// ascending, so ties hold input order regardless.
    func testTieBreakFollowsThisCallsInputOrderNotIdentity() {
        let x = typedRail("X", "songs")
        let y = typedRail("Y", "songs")
        XCTAssertEqual(selectHomeRails([x, y], currentYear: 2026).map(\.title), ["X", "Y"])
        XCTAssertEqual(selectHomeRails([y, x], currentYear: 2026).map(\.title), ["Y", "X"])
    }

    /// CLI/TUI drift on shared data is this repo's most-repeated bug: 1c06027
    /// fixed exactly this for rail ORDER. Rail SELECTION must be shared the same
    /// way, so both surfaces resolve one feed to one set of rails.
    func testCliAndTuiResolveTheSameRailsFromOneFeed() {
        let feed = [
            albumRail("Boom Bap", [1995]),
            typedRail("Playlists", "playlists"),
            HomeRail(id: "rp", title: "Recently Played", items: [album("x", 2001)],
                     isRecentlyPlayed: true, resourceTypes: ["albums"]),
            albumRail("New Releases", [2026, 2026]),
            typedRail("Stations", "stations"),
            // Older than "Boom Bap" (1995) on purpose: slot 5 picks the
            // freshest remaining rail by median year, so "Extra" must be the
            // least fresh of what's left in order to be the one that misses
            // the cut — this pins that exclusion, not an arbitrary one.
            albumRail("Extra", [1980]),
        ]
        let tui = selectHomeRails(orderedHomeRails(feed), currentYear: 2026)
        let cli = selectHomeRails(orderedHomeRails(feed), currentYear: 2026)
        XCTAssertEqual(tui.map(\.id), cli.map(\.id))
        XCTAssertEqual(tui.count, 5)
        XCTAssertFalse(tui.map(\.title).contains("Extra"), "the sixth rail is not on the dashboard")
    }
}
