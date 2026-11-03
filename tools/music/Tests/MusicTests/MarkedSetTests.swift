// tools/music/Tests/MusicTests/MarkedSetTests.swift
import XCTest
@testable import music

final class MarkedSetTests: XCTestCase {
    private let a = MarkedItem.album(title: "Kid A", artist: "Radiohead")
    private let b = MarkedItem.album(title: "Amnesiac", artist: "Radiohead")
    private let p = MarkedItem.playlist(name: "Road Trip")

    func testStartsEmpty() {
        let s = MarkedSetStore()
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.items, [])
    }

    func testToggleKeepsMarkOrder() {
        let s = MarkedSetStore()
        s.toggle(b, source: .musicApp)
        s.toggle(a, source: .musicApp)
        s.toggle(p, source: .musicApp)
        XCTAssertEqual(s.items, [b, a, p])
        XCTAssertEqual(s.count, 3)
        XCTAssertTrue(s.contains(a))
    }

    func testUnmarkRemovesOnlyThatMark() {
        let s = MarkedSetStore()
        s.toggle(a, source: .musicApp)
        s.toggle(b, source: .musicApp)
        s.toggle(p, source: .musicApp)
        s.toggle(b, source: .musicApp)
        XCTAssertEqual(s.items, [a, p])
        XCTAssertFalse(s.contains(b))
    }

    func testRemarkAfterUnmarkGoesToTheEnd() {
        let s = MarkedSetStore()
        s.toggle(a, source: .musicApp)
        s.toggle(b, source: .musicApp)
        s.toggle(a, source: .musicApp)
        s.toggle(a, source: .musicApp)
        XCTAssertEqual(s.items, [b, a])
    }

    func testClearEmpties() {
        let s = MarkedSetStore()
        s.toggle(a, source: .musicApp)
        s.toggle(p, source: .musicApp)
        s.clear()
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.items, [])
        XCTAssertFalse(s.contains(a))
    }

    func testSourceChangeClears() {
        let s = MarkedSetStore()
        s.toggle(a, source: .musicApp)
        s.toggle(p, source: .musicApp)
        s.toggle(b, source: .bridge)
        XCTAssertEqual(s.items, [b])
        XCTAssertFalse(s.contains(a))
    }

    func testSourceChangeOnAlreadyMarkedItemClearsThenAddsIt() {
        let s = MarkedSetStore()
        s.toggle(a, source: .musicApp)
        s.toggle(a, source: .bridge)
        XCTAssertEqual(s.items, [a])
    }

    func testClearForgetsSourceSoNextSourceIsFree() {
        let s = MarkedSetStore()
        s.toggle(a, source: .musicApp)
        s.clear()
        s.toggle(b, source: .bridge)
        s.toggle(p, source: .bridge)
        XCTAssertEqual(s.items, [b, p])
    }

    func testSameAlbumTitleDifferentArtistIsDistinct() {
        let s = MarkedSetStore()
        let x = MarkedItem.album(title: "Greatest Hits", artist: "Queen")
        let y = MarkedItem.album(title: "Greatest Hits", artist: "ABBA")
        s.toggle(x, source: .musicApp)
        s.toggle(y, source: .musicApp)
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s.contains(x))
        XCTAssertTrue(s.contains(y))
        s.toggle(x, source: .musicApp)
        XCTAssertEqual(s.items, [y])
    }

    func testAlbumAndPlaylistWithSameTextAreDistinct() {
        let s = MarkedSetStore()
        s.toggle(.album(title: "Mix", artist: ""), source: .musicApp)
        s.toggle(.playlist(name: "Mix"), source: .musicApp)
        XCTAssertEqual(s.count, 2)
    }

    func testConcurrentTogglesDoNotCorrupt() {
        let s = MarkedSetStore()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            s.toggle(.playlist(name: "P\(i % 50)"), source: .musicApp)
            _ = s.items
        }
        // each of 50 names is toggled 4 times, so all end unmarked
        XCTAssertTrue(s.isEmpty)
    }
}
