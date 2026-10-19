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

    /// The `Rec###` names the RAIL draws, in order of appearance. The frame is a stream of
    /// cursor moves, each followed by the text for that spot; only the text placed at the
    /// rail's own column counts, so the hero's heading (the selected album's name) and the
    /// preview cannot satisfy a check that the rail shows a row.
    private func drawn(_ s: LibraryScene) -> [Int] {
        let out = s.render(frame: frame, snapshot: idle)
        let railX = playlistZones(width: frame.width).railX
        let move = try! NSRegularExpression(pattern: "\u{1B}\\[(\\d+);(\\d+)H")
        let ns = out as NSString
        let hits = move.matches(in: out, range: NSRange(location: 0, length: ns.length))
        var seen: [Int] = []
        for (i, m) in hits.enumerated() {
            guard Int(ns.substring(with: m.range(at: 2))) == railX else { continue }
            let from = m.range.location + m.range.length
            let to = i + 1 < hits.count ? hits[i + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: from, length: to - from))
            guard let r = text.range(of: "Rec") else { continue }
            let digits = text[r.upperBound...].prefix(3)
            if digits.count == 3, let n = Int(digits), !seen.contains(n) { seen.append(n) }
        }
        return seen
    }

    /// One key, then a paint, as the app does: the rail's scroll follows the cursor at render time.
    private func press(_ s: LibraryScene, _ key: KeyPress, _ n: Int = 1) {
        for _ in 0..<n { _ = s.handle(key); _ = s.render(frame: frame, snapshot: idle) }
    }
    private func down(_ s: LibraryScene, _ n: Int) { press(s, .down, n) }
    private func up(_ s: LibraryScene, _ n: Int) { press(s, .up, n) }

    /// Enter on the row under the cursor, proved to have opened its tracks.
    private func openTracks(_ s: LibraryScene, file: StaticString = #filePath, line: UInt = #line) {
        _ = s.handle(.enter)
        guard case .tracks = s.levelForTest else {
            return XCTFail("Enter did not open the album's tracks: \(s.levelForTest)", file: file, line: line)
        }
    }

    /// Escape from the tracks, proved to have landed on `level`.
    private func back(_ s: LibraryScene, to level: LibraryLevel, file: StaticString = #filePath, line: UInt = #line) {
        _ = s.handle(.escape)
        XCTAssertEqual(s.levelForTest, level, "Back did not reach the list", file: file, line: line)
    }

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

        openTracks(s)                                       // the album's tracks
        back(s, to: .albumList)                             // Back

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
        guard let top = window.min(), let bottom = window.max() else { return XCTFail("the rail drew no rows") }
        while s.navCursorForTest + 1 > top { up(s, 1) }
        // The cursor is on the top row of the window now (index top-1 is row `top`).
        XCTAssertEqual(s.navCursorForTest + 1, top)
        openTracks(s)
        back(s, to: .albumList)
        XCTAssertEqual(s.selectionIDForTest, id(top))
        XCTAssertEqual(drawn(s), window, "the top-edge album's window moved after Back")

        down(s, bottom - top)                               // the last row of the window
        XCTAssertEqual(s.navCursorForTest + 1, bottom)
        openTracks(s)
        back(s, to: .albumList)
        XCTAssertEqual(s.selectionIDForTest, id(bottom))
        XCTAssertEqual(drawn(s), window, "the bottom-edge album's window moved after Back")
    }

    /// The list was replaced under the drill (an automatic re-read) with rows
    /// inserted above: the opened album moved down the list, so the old scroll no
    /// longer shows it. Back follows it by id and the window follows the cursor.
    func testBackAfterRowsWereInsertedAboveKeepsTheOpenedAlbumOnScreen() {
        let s = albumsScene(albums(1...80))
        down(s, 50)                                         // Rec051
        openTracks(s)
        s.replaceAlbumsForTest(albums(101...140) + albums(1...80))   // 40 rows above it
        back(s, to: .albumList)
        XCTAssertEqual(s.selectionIDForTest, id(51))
        XCTAssertEqual(s.navCursorForTest, 90)
        XCTAssertTrue(drawn(s).contains(51), "the opened album is off screen after the list moved under it: \(drawn(s))")
    }

    /// The list shrank under the drill so the saved scroll is past the end: Back
    /// must not draw an empty rail (nor trap).
    func testBackAfterTheListShrankDrawsARealWindow() {
        let s = albumsScene(albums(1...80))
        down(s, 70)
        openTracks(s)
        s.replaceAlbumsForTest(albums(1...5))               // the opened album is gone
        back(s, to: .albumList)
        let shown = drawn(s)
        XCTAssertFalse(shown.isEmpty, "the rail is empty after Back")
        guard let selected = s.selectionIDForTest, let row = Int(selected) else {
            return XCTFail("no row under the cursor after Back")
        }
        XCTAssertTrue(shown.contains(row), "the cursor row is off screen")
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
        XCTAssertEqual(s.levelForTest, .artistAlbums(artistID: "R", artistName: "Artist R"), "Enter did not open the artist")
        s.replaceArtistAlbumsForTest(albums(1...80))
        down(s, 55)
        up(s, 5)                // Rec051, mid-window
        XCTAssertEqual(s.selectionIDForTest, id(51))
        let before = drawn(s)
        XCTAssertTrue(before.contains(51) && before.contains(56))
        openTracks(s)                                       // album -> tracks
        back(s, to: .artistAlbums(artistID: "R", artistName: "Artist R"))   // Back to the artist's albums
        XCTAssertEqual(s.selectionIDForTest, id(51))
        XCTAssertEqual(drawn(s), before, "Back moved the artist's albums window")
    }
}
