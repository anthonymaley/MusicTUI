import XCTest
@testable import music

/// Back out of an opened album: the cursor returns to the opened row by id AND the
/// scroll offset keeps that row on screen. The cursor half is covered by
/// `LibraryBackAfterListReplacedTests`; this is the half that was untested, read off
/// the rendered rail (which rows are drawn), not off a private offset. Fakes only:
/// the Music.app side is the spy, nothing plays, no socket or config is read.
final class LibraryBackScrollRestoreTests: XCTestCase {

    private let frame = shellLayout(width: 140, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    /// Zero-padded so one id's name is never a prefix of another's.
    private func id(_ n: Int) -> String { String(format: "%03d", n) }
    private func album(_ n: Int) -> LibraryAlbum {
        LibraryAlbum(id: id(n), name: "Rec\(id(n))", artist: "Band", trackCount: 3)
    }
    private func albums(_ range: ClosedRange<Int>) -> [LibraryAlbum] { range.map(album) }

    private func albumsScene(_ rows: [LibraryAlbum]) -> LibraryScene {
        let spy = LibraryAppleScriptSpy()
        spy.albums = rows
        let s = libraryTestScene(flag: BridgeSelectedFlag(false), wire: BridgeLibraryReadsWire([:]), spy: spy)
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains(rows[0].name) })
        return s
    }

    /// The `Rec###` names the rail draws, in order of appearance.
    private func drawn(_ s: LibraryScene) -> [Int] {
        let out = s.render(frame: frame, snapshot: idle)
        var seen: [Int] = []
        var rest = Substring(out)
        while let r = rest.range(of: "Rec") {
            let digits = rest[r.upperBound...].prefix(3)
            if digits.count == 3, let n = Int(digits), !seen.contains(n) { seen.append(n) }
            rest = rest[r.upperBound...]
        }
        return seen
    }

    /// One key, then a paint, as the app does: the rail's scroll follows the cursor at render time.
    private func press(_ s: LibraryScene, _ key: KeyPress, _ n: Int = 1) {
        for _ in 0..<n { _ = s.handle(key); _ = s.render(frame: frame, snapshot: idle) }
    }
    private func down(_ s: LibraryScene, _ n: Int) { press(s, .down, n) }
    private func up(_ s: LibraryScene, _ n: Int) { press(s, .up, n) }

    /// A row far enough down that the rail has scrolled: the opened row is not
    /// among the first screenful, so a scroll that fell back to 0 would hide it
    /// only if the renderer did not follow the cursor, and a restored scroll is
    /// observable as the SAME window of rows.
    func testBackKeepsTheOpenedAlbumOnScreenInTheSameWindow() {
        let s = albumsScene(albums(1...80))
        down(s, 50)
        up(s, 5)                // Rec046, mid-window: the cursor is not at the window's edge
        XCTAssertEqual(s.selectionIDForTest, id(46))
        let before = drawn(s)
        XCTAssertFalse(before.contains(1), "the rail never scrolled: \(before)")
        XCTAssertTrue(before.contains(46))
        XCTAssertTrue(before.contains(51), "the window should reach past the cursor, or it proves nothing about the offset")

        _ = s.handle(.enter)                                // the album's tracks
        _ = s.handle(.escape)                               // Back

        XCTAssertEqual(s.selectionIDForTest, id(46), "Back lost the opened album")
        XCTAssertEqual(s.navCursorForTest, 45)
        let after = drawn(s)
        XCTAssertTrue(after.contains(46), "the opened album is off screen after Back: \(after)")
        XCTAssertEqual(after, before, "Back moved the scroll window")
    }

    /// The cursor is the first row of a scrolled window, then the last: the two
    /// edges where a scroll off by one would hide the opened row.
    func testBackKeepsTheOpenedAlbumVisibleAtBothEdgesOfTheWindow() {
        let s = albumsScene(albums(1...80))
        down(s, 60)                                         // scrolled well past the first screenful
        let window = drawn(s)
        let top = window.min()!, bottom = window.max()!
        while s.navCursorForTest + 1 > top { up(s, 1) }
        // The cursor is on the top row of the window now (index top-1 is row `top`).
        XCTAssertEqual(s.navCursorForTest + 1, top)
        _ = s.handle(.enter)
        _ = s.handle(.escape)
        XCTAssertEqual(s.selectionIDForTest, id(top))
        XCTAssertEqual(drawn(s), window, "the top-edge album's window moved after Back")

        down(s, bottom - top)                               // the last row of the window
        XCTAssertEqual(s.navCursorForTest + 1, bottom)
        _ = s.handle(.enter)
        _ = s.handle(.escape)
        XCTAssertEqual(s.selectionIDForTest, id(bottom))
        XCTAssertEqual(drawn(s), window, "the bottom-edge album's window moved after Back")
    }

    /// The list was replaced under the drill (an automatic re-read) with rows
    /// inserted above: the opened album moved down the list, so the old scroll no
    /// longer shows it. Back follows it by id and the window follows the cursor.
    func testBackAfterRowsWereInsertedAboveKeepsTheOpenedAlbumOnScreen() {
        let s = albumsScene(albums(1...80))
        down(s, 50)                                         // Rec051
        _ = s.handle(.enter)
        s.replaceAlbumsForTest(albums(101...140) + albums(1...80))   // 40 rows above it
        _ = s.handle(.escape)
        XCTAssertEqual(s.selectionIDForTest, id(51))
        XCTAssertEqual(s.navCursorForTest, 90)
        XCTAssertTrue(drawn(s).contains(51), "the opened album is off screen after the list moved under it: \(drawn(s))")
    }

    /// The list shrank under the drill so the saved scroll is past the end: Back
    /// must not draw an empty rail (nor trap).
    func testBackAfterTheListShrankDrawsARealWindow() {
        let s = albumsScene(albums(1...80))
        down(s, 70)
        _ = s.handle(.enter)
        s.replaceAlbumsForTest(albums(1...5))               // the opened album is gone
        _ = s.handle(.escape)
        let shown = drawn(s)
        XCTAssertFalse(shown.isEmpty, "the rail is empty after Back")
        XCTAssertNotNil(s.selectionIDForTest)
        XCTAssertTrue(shown.contains(Int(s.selectionIDForTest!)!), "the cursor row is off screen")
    }

    /// An artist's albums rail, opened to an album's tracks and back, is restored
    /// the same way.
    func testBackFromAnArtistsAlbumTracksKeepsTheOpenedAlbumOnScreen() {
        let spy = LibraryAppleScriptSpy()
        spy.artists = [LibraryArtist(id: "R", name: "Artist R")]
        let s = libraryTestScene(flag: BridgeSelectedFlag(false), wire: BridgeLibraryReadsWire([:]), spy: spy)
        XCTAssertEqual(s.subViewForTest, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Artist R") })
        _ = s.handle(.enter)                                // artist -> albums (the read stays unlanded)
        s.replaceArtistAlbumsForTest(albums(1...80))
        down(s, 55)
        up(s, 5)                // Rec051, mid-window
        XCTAssertEqual(s.selectionIDForTest, id(51))
        let before = drawn(s)
        XCTAssertTrue(before.contains(51) && before.contains(56))
        _ = s.handle(.enter)                                // album -> tracks
        _ = s.handle(.escape)                               // Back to the artist's albums
        XCTAssertEqual(s.selectionIDForTest, id(51))
        XCTAssertEqual(drawn(s), before, "Back moved the artist's albums window")
    }
}
