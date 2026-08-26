import XCTest
@testable import music

final class DiscoverDisplayTests: XCTestCase {
    private func item(_ kind: DiscoverItemKind, _ name: String) -> DiscoverItem {
        let detail: DiscoverItemDetail
        switch kind {
        case .station:  detail = .station(isLive: false)
        case .album:    detail = .album(trackCount: nil, year: nil, genre: nil)
        case .playlist: detail = .playlist(description: nil)
        case .song:     detail = .song
        }
        return DiscoverItem(id: name, name: name, subtitle: nil,
                        url: nil, artworkURL: nil, detail: detail)
    }

    private func rail(_ title: String, recent: Bool = false, _ names: [String]) -> DiscoverRail {
        DiscoverRail(id: title, title: title, items: names.map { item(.album, $0) },
                 isRecentlyPlayed: recent, resourceTypes: ["albums"])
    }

    // MARK: - Ordering

    /// Music.app's Discover leads with picks and then Recently Played. We cannot
    /// fetch its Top Picks rail at all, but we can at least put the row the user
    /// recognizes near the top instead of burying it at position 2.
    func testHoistsTheRecentlyPlayedRailToTheFront() {
        let out = orderedDiscoverRails([rail("Made for You", ["a"]),
                                    rail("Recently Played", recent: true, ["b"]),
                                    rail("Electronic", ["c"])])
        XCTAssertEqual(out.map(\.title), ["Recently Played", "Made for You", "Electronic"])
    }

    func testLeavesOrderAloneWhenThereIsNoRecentlyPlayedRail() {
        let out = orderedDiscoverRails([rail("A", ["a"]), rail("B", ["b"])])
        XCTAssertEqual(out.map(\.title), ["A", "B"])
    }

    /// Defensive: the feed has only ever returned one, but hoisting must not
    /// reorder two against each other or drop one.
    func testKeepsRelativeOrderOfMultipleRecentlyPlayedRails() {
        let out = orderedDiscoverRails([rail("X", ["a"]),
                                    rail("R1", recent: true, ["b"]),
                                    rail("R2", recent: true, ["c"])])
        XCTAssertEqual(out.map(\.title), ["R1", "R2", "X"])
    }

    // MARK: - Flattening

    func testFlattensRailsIntoHeadersAndItems() {
        let rows = discoverDisplayRows(rails: [rail("One", ["a", "b"])], perRail: 6)
        XCTAssertEqual(rows, [.header("One"), .item(item(.album, "a")), .item(item(.album, "b"))])
    }

    func testCapsItemsPerRail() {
        let rows = discoverDisplayRows(rails: [rail("One", ["a", "b", "c"])], perRail: 2)
        XCTAssertEqual(rows.count, 4)   // header + 2 items + View all
    }

    /// A rail that arrives empty renders as a bare heading with nothing under
    /// it, which reads as a bug. DiscoverFeed drops them, and so does this.
    func testDropsRailsWithNoItems() {
        let rows = discoverDisplayRows(rails: [rail("Empty", []), rail("Full", ["a"])], perRail: 6)
        XCTAssertEqual(rows, [.header("Full"), .item(item(.album, "a"))])
    }

    // MARK: - Cursor movement

    func testSelectableIndicesSkipHeaders() {
        let rows = discoverDisplayRows(rails: [rail("One", ["a"]), rail("Two", ["b"])], perRail: 6)
        XCTAssertEqual(selectableDiscoverIndices(rows), [1, 3])
    }

    func testSelectableIndicesAreEmptyForNoRails() {
        XCTAssertEqual(selectableDiscoverIndices([]), [])
    }

    // MARK: - View all

    /// Rails longer than the visible cap get a selectable row that opens the
    /// rail level, so a curated Discover never silently throws recommendations away.
    func testEmitsViewAllWhenTheRailIsLongerThanTheCap() {
        let r = rail("One", ["a", "b", "c", "d", "e"])
        let rows = discoverDisplayRows(rails: [r], perRail: 4)
        XCTAssertEqual(rows.count, 6)   // header + 4 items + View all
        XCTAssertEqual(rows.last, .viewAll(r))
    }

    /// Below the cap it is needless navigation: the rail is already fully shown.
    func testSuppressesViewAllWhenTheRailFitsExactly() {
        let rows = discoverDisplayRows(rails: [rail("One", ["a", "b", "c", "d"])], perRail: 4)
        XCTAssertEqual(rows.count, 5)   // header + 4 items, no View all
        XCTAssertNotEqual(rows.last, .viewAll(rail("One", ["a", "b", "c", "d"])))
    }

    func testSuppressesViewAllWhenTheRailIsShorterThanTheCap() {
        let rows = discoverDisplayRows(rails: [rail("One", ["a"])], perRail: 4)
        XCTAssertEqual(rows, [.header("One"), .item(item(.album, "a"))])
    }

    func testViewAllRowsAreSelectable() {
        let rows = discoverDisplayRows(rails: [rail("One", ["a", "b", "c", "d", "e"])], perRail: 4)
        XCTAssertEqual(selectableDiscoverIndices(rows), [1, 2, 3, 4, 5])
    }

    // MARK: - Selection projection

    /// A row you can land on but cannot act from is worse than no row. The
    /// projection guarantees every selectable row has a defined target.
    func testProjectsAnItemSelection() {
        let rows = discoverDisplayRows(rails: [rail("One", ["a", "b"])], perRail: 4)
        XCTAssertEqual(discoverSelection(rows: rows, cursor: 0), .item(item(.album, "a")))
    }

    func testProjectsAViewAllSelection() {
        let r = rail("One", ["a", "b", "c", "d", "e"])
        let rows = discoverDisplayRows(rails: [r], perRail: 4)
        XCTAssertEqual(discoverSelection(rows: rows, cursor: 4), .viewAll(r))
    }

    func testProjectsNilWhenTheCursorIsOutOfRange() {
        let rows = discoverDisplayRows(rails: [rail("One", ["a"])], perRail: 4)
        XCTAssertNil(discoverSelection(rows: rows, cursor: 9))
        XCTAssertNil(discoverSelection(rows: [], cursor: 0))
    }
}
