// tools/music/Tests/MusicTests/MarkedSetTests.swift
import XCTest
@testable import music

final class MarkedSetTests: XCTestCase {
    private let a = MarkedItem.album(title: "Kid A", artist: "Radiohead")
    private let b = MarkedItem.album(title: "Amnesiac", artist: "Radiohead")
    private let p = MarkedItem.playlist(id: "00000000000000E1", name: "Road Trip")

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
        s.toggle(.playlist(id: "00000000000000E2", name: "Mix"), source: .musicApp)
        XCTAssertEqual(s.count, 2)
    }

    /// A marked playlist is the playlist with that persistent ID, whatever it
    /// is called: the same ID under a new name is the same mark (`m` again
    /// unmarks it), and two playlists sharing a name are two marks.
    func testAPlaylistMarkIsItsIDNotItsName() {
        let s = MarkedSetStore()
        s.toggle(.playlist(id: "00000000000000F1", name: "Chill"), source: .musicApp)
        s.toggle(.playlist(id: "00000000000000F2", name: "Chill"), source: .musicApp)
        XCTAssertEqual(s.count, 2, "two playlists named alike are two marks")
        XCTAssertTrue(s.contains(.playlist(id: "00000000000000F1", name: "Chill Old")), "renamed, still marked")
        s.toggle(.playlist(id: "00000000000000F1", name: "Chill Old"), source: .musicApp)
        XCTAssertEqual(s.count, 1, "the renamed row unmarks the mark it is")
        guard case .playlist(let id, let name)? = s.items.first else { return XCTFail("\(s.items)") }
        XCTAssertEqual(id, "00000000000000F2")
        XCTAssertEqual(name, "Chill")
    }

    func testConcurrentTogglesDoNotCorrupt() {
        let s = MarkedSetStore()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            s.toggle(.playlist(id: String(format: "%016X", i % 50), name: "P\(i % 50)"), source: .musicApp)
            _ = s.items
        }
        // each of 50 names is toggled 4 times, so all end unmarked
        XCTAssertTrue(s.isEmpty)
    }
}
