import XCTest
@testable import music

final class RadioNavTests: XCTestCase {
    private func sel(_ id: String) -> Station {
        Station(id: id, name: id, url: "https://music.apple.com/us/station/s/\(id)",
                isLive: nil, artworkURL: nil)
    }

    func testInitialIsFavorites() {
        XCTAssertEqual(RadioNav.initial.subView, .favorites)
        XCTAssertEqual(RadioNav.initial.cursor, 0)
    }

    func testDownClampsToItemCount() {
        let (s, _) = radioReduce(RadioNav.initial, .down, itemCount: 2, selection: nil)
        XCTAssertEqual(s.cursor, 1)
        let (s2, _) = radioReduce(s, .down, itemCount: 2, selection: nil)
        XCTAssertEqual(s2.cursor, 1)   // clamped
    }

    func testDownOnEmptyListStaysAtZero() {
        let (s, _) = radioReduce(RadioNav.initial, .down, itemCount: 0, selection: nil)
        XCTAssertEqual(s.cursor, 0)
    }

    func testUpClampsAtZero() {
        let (s, _) = radioReduce(RadioNav.initial, .up, itemCount: 3, selection: nil)
        XCTAssertEqual(s.cursor, 0)
    }

    func testSwitchNextCyclesForwardAndWraps() {
        var s = RadioNav.initial
        s = radioReduce(s, .switchNext, itemCount: 0, selection: nil).0
        XCTAssertEqual(s.subView, .live)
        s = radioReduce(s, .switchNext, itemCount: 0, selection: nil).0
        XCTAssertEqual(s.subView, .personal)
        s = radioReduce(s, .switchNext, itemCount: 0, selection: nil).0
        XCTAssertEqual(s.subView, .favorites)   // wraps
    }

    func testSwitchPrevWrapsBackwards() {
        let (s, _) = radioReduce(RadioNav.initial, .switchPrev, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .personal)
    }

    func testSwitchResetsCursor() {
        var s = radioReduce(RadioNav.initial, .down, itemCount: 5, selection: nil).0
        XCTAssertEqual(s.cursor, 1)
        s = radioReduce(s, .switchNext, itemCount: 5, selection: nil).0
        XCTAssertEqual(s.cursor, 0)
    }

    func testEnterEmitsPlay() {
        let (_, a) = radioReduce(RadioNav.initial, .enter, itemCount: 1, selection: sel("ra.1"))
        XCTAssertEqual(a, .play(sel("ra.1")))
    }

    func testEnterWithNoSelectionIsNoOp() {
        let (_, a) = radioReduce(RadioNav.initial, .enter, itemCount: 0, selection: nil)
        XCTAssertEqual(a, .none)
    }

    func testToggleFavEmitsToggle() {
        let (_, a) = radioReduce(RadioNav.initial, .toggleFav, itemCount: 1, selection: sel("ra.1"))
        XCTAssertEqual(a, .toggleFavorite(sel("ra.1")))
    }

    func testToggleFavWithNoSelectionIsNoOp() {
        let (_, a) = radioReduce(RadioNav.initial, .toggleFav, itemCount: 0, selection: nil)
        XCTAssertEqual(a, .none)
    }
}
