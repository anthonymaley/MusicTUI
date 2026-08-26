import XCTest
@testable import music

final class HomeNavTests: XCTestCase {
    private func item(_ name: String) -> HomeItem {
        HomeItem(id: name, name: name, subtitle: nil, url: nil, artworkURL: nil,
                 detail: .album(trackCount: nil, year: nil, genre: nil))
    }

    private func rail(_ title: String) -> HomeRail {
        HomeRail(id: title, title: title, items: [item("i")],
                 isRecentlyPlayed: false, resourceTypes: ["albums"])
    }

    // MARK: - Stack

    func testPushAddsALevelWithAFreshCursor() {
        var stack = [HomeFrameState(level: .home, cursor: HomeCursor(index: 7, scroll: 3))]
        stack = pushLevel(stack, .rail(rail("R")))
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack.last?.cursor, HomeCursor(index: 0, scroll: 0))
        XCTAssertEqual(stack.first?.cursor, HomeCursor(index: 7, scroll: 3),
                       "push must not disturb the parent's position")
    }

    /// The whole point of the stack: coming back from an item's track list must
    /// land on the rail you opened it from, at the row you left, not on Home.
    func testPopRestoresTheParentCursorAndScroll() {
        var stack = [HomeFrameState(level: .home, cursor: HomeCursor(index: 4, scroll: 2))]
        stack = pushLevel(stack, .rail(rail("R")))
        stack[1].cursor = HomeCursor(index: 9, scroll: 6)
        stack = pushLevel(stack, .tracks(item("a")))
        stack = popLevel(stack)
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack.last?.cursor, HomeCursor(index: 9, scroll: 6))
        stack = popLevel(stack)
        XCTAssertEqual(stack.last?.cursor, HomeCursor(index: 4, scroll: 2))
    }

    func testPopNeverEmptiesTheStack() {
        let stack = [HomeFrameState(level: .home, cursor: HomeCursor())]
        XCTAssertEqual(popLevel(popLevel(stack)).count, 1)
    }

    func testThreeLevelsRoundTrip() {
        var stack = [HomeFrameState(level: .home, cursor: HomeCursor())]
        stack = pushLevel(stack, .rail(rail("R")))
        stack = pushLevel(stack, .tracks(item("a")))
        XCTAssertEqual(stack.count, 3)
        XCTAssertEqual(popLevel(popLevel(stack)).count, 1)
        XCTAssertEqual(popLevel(popLevel(stack)).first?.level, .home)
    }

    // MARK: - Viewport

    /// The defect this fixes: the track drill-in advanced its cursor with no
    /// viewport at all, so on a 26-track album the selected row walked
    /// off-screen with no way to follow it.
    func testViewportFollowsTheCursorPastTheBottom() {
        var scroll = 0
        for index in 0..<26 {
            scroll = scrollToShow(row: index, scroll: scroll, visibleHeight: 10, count: 26)
            XCTAssertTrue(index >= scroll && index < scroll + 10,
                          "row \(index) fell outside the window [\(scroll), \(scroll + 10))")
        }
        XCTAssertEqual(scroll, 16, "last window shows rows 16..25")
    }

    func testViewportFollowsTheCursorBackUpwards() {
        var scroll = 16
        for index in stride(from: 25, through: 0, by: -1) {
            scroll = scrollToShow(row: index, scroll: scroll, visibleHeight: 10, count: 26)
            XCTAssertTrue(index >= scroll && index < scroll + 10)
        }
        XCTAssertEqual(scroll, 0)
    }

    func testViewportNeverScrollsAListShorterThanTheBody() {
        XCTAssertEqual(scrollToShow(row: 3, scroll: 0, visibleHeight: 20, count: 5), 0)
    }

    func testViewportIsSafeOnDegenerateGeometry() {
        XCTAssertEqual(scrollToShow(row: 0, scroll: 0, visibleHeight: 0, count: 5), 0)
        XCTAssertEqual(scrollToShow(row: 0, scroll: 0, visibleHeight: 10, count: 0), 0)
    }

    /// A stale cursor can outlive its list: the Home feed refreshes on a ten
    /// minute cache and on `r`, so `count` can shrink between a keypress and the
    /// next render, leaving `row` past the end.
    ///
    /// No explicit row clamp is needed for this, and deliberately none exists.
    /// The final `max(0, min(s, max(0, count - visibleHeight)))` saturates, so an
    /// out-of-range row can only push the intermediate scroll toward an endpoint
    /// the clamp was going to pin anyway — the overshoot's magnitude never
    /// survives, only its direction. This test guards that saturation, which IS
    /// load-bearing: weaken the final clamp and all three assertions fail.
    func testViewportSaturatesForARowPastTheListEnd() {
        // A 26-item list shrank to 5 while the cursor sat at row 20.
        XCTAssertEqual(scrollToShow(row: 20, scroll: 16, visibleHeight: 10, count: 5), 0,
                       "a 5-item list in a 10-row window never scrolls")
        // Same staleness, window now smaller than the shrunken list.
        XCTAssertEqual(scrollToShow(row: 20, scroll: 16, visibleHeight: 3, count: 5), 2,
                       "pinned to the last page, window [2, 5)")
        // A negative row is equally out of range and must not yield a negative scroll.
        XCTAssertEqual(scrollToShow(row: -4, scroll: 3, visibleHeight: 3, count: 5), 0)
    }
}
