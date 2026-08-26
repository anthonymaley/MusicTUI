import XCTest
@testable import music

final class HomeDisplayTests: XCTestCase {
    private func item(_ kind: HomeItemKind, _ name: String) -> HomeItem {
        let detail: HomeItemDetail
        switch kind {
        case .station:  detail = .station(isLive: false)
        case .album:    detail = .album(trackCount: nil, year: nil, genre: nil)
        case .playlist: detail = .playlist(description: nil)
        case .song:     detail = .song
        }
        return HomeItem(id: name, name: name, subtitle: nil,
                        url: nil, artworkURL: nil, detail: detail)
    }

    private func rail(_ title: String, recent: Bool = false, _ names: [String]) -> HomeRail {
        HomeRail(id: title, title: title, items: names.map { item(.album, $0) },
                 isRecentlyPlayed: recent, resourceTypes: ["albums"])
    }

    // MARK: - Ordering

    /// Music.app's Home leads with picks and then Recently Played. We cannot
    /// fetch its Top Picks rail at all, but we can at least put the row the user
    /// recognizes near the top instead of burying it at position 2.
    func testHoistsTheRecentlyPlayedRailToTheFront() {
        let out = orderedHomeRails([rail("Made for You", ["a"]),
                                    rail("Recently Played", recent: true, ["b"]),
                                    rail("Electronic", ["c"])])
        XCTAssertEqual(out.map(\.title), ["Recently Played", "Made for You", "Electronic"])
    }

    func testLeavesOrderAloneWhenThereIsNoRecentlyPlayedRail() {
        let out = orderedHomeRails([rail("A", ["a"]), rail("B", ["b"])])
        XCTAssertEqual(out.map(\.title), ["A", "B"])
    }

    /// Defensive: the feed has only ever returned one, but hoisting must not
    /// reorder two against each other or drop one.
    func testKeepsRelativeOrderOfMultipleRecentlyPlayedRails() {
        let out = orderedHomeRails([rail("X", ["a"]),
                                    rail("R1", recent: true, ["b"]),
                                    rail("R2", recent: true, ["c"])])
        XCTAssertEqual(out.map(\.title), ["R1", "R2", "X"])
    }

    // MARK: - Flattening

    func testFlattensRailsIntoHeadersAndItems() {
        let rows = homeDisplayRows(rails: [rail("One", ["a", "b"])], perRail: 6)
        XCTAssertEqual(rows, [.header("One"), .item(item(.album, "a")), .item(item(.album, "b"))])
    }

    func testCapsItemsPerRail() {
        let rows = homeDisplayRows(rails: [rail("One", ["a", "b", "c"])], perRail: 2)
        XCTAssertEqual(rows.count, 3)   // header + 2
    }

    /// A rail that arrives empty renders as a bare heading with nothing under
    /// it, which reads as a bug. HomeFeed drops them, and so does this.
    func testDropsRailsWithNoItems() {
        let rows = homeDisplayRows(rails: [rail("Empty", []), rail("Full", ["a"])], perRail: 6)
        XCTAssertEqual(rows, [.header("Full"), .item(item(.album, "a"))])
    }

    // MARK: - Cursor movement

    func testSelectableIndicesSkipHeaders() {
        let rows = homeDisplayRows(rails: [rail("One", ["a"]), rail("Two", ["b"])], perRail: 6)
        XCTAssertEqual(selectableHomeIndices(rows), [1, 3])
    }

    func testSelectableIndicesAreEmptyForNoRails() {
        XCTAssertEqual(selectableHomeIndices([]), [])
    }
}
