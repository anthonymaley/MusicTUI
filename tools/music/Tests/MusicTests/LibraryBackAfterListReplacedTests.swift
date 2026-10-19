import XCTest
@testable import music

/// Back out of a drill when the parent list was replaced under it (an automatic
/// re-read). The cursor follows the opened row by id; if the row is gone it lands
/// on a real row. Fakes only: the Music.app side is the spy, nothing plays, no
/// socket or config is read, and the replacement is applied directly, so there is
/// no clock or wall-time wait beyond the first list landing.
final class LibraryBackAfterListReplacedTests: XCTestCase {

    private let frame = shellLayout(width: 140, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func album(_ id: String) -> LibraryAlbum {
        LibraryAlbum(id: id, name: "Album \(id)", artist: "Band", trackCount: 3)
    }
    private func albums(_ ids: String...) -> [LibraryAlbum] { ids.map(album) }

    private func albumsScene(_ ids: [String]) -> LibraryScene {
        let spy = LibraryAppleScriptSpy()
        spy.albums = ids.map(album)
        let s = libraryTestScene(flag: BridgeSelectedFlag(false), wire: BridgeLibraryReadsWire([:]), spy: spy)
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Album \(ids.last!)") })
        return s
    }

    /// Opens the row at `index`, replaces the parent list, goes Back.
    private func openReplaceBack(_ s: LibraryScene, index: Int, _ rows: [LibraryAlbum]) {
        for _ in 0..<index { _ = s.handle(.down) }
        XCTAssertEqual(s.navCursorForTest, index)
        _ = s.handle(.enter)
        s.replaceAlbumsForTest(rows)
        _ = s.handle(.escape)
    }

    func testInsertionAboveReturnsToTheOpenedAlbum() {
        let s = albumsScene(["A", "B", "C"])
        openReplaceBack(s, index: 2, albums("X", "A", "B", "C"))
        XCTAssertEqual(s.selectionIDForTest, "C")
        XCTAssertEqual(s.navCursorForTest, 3)
    }

    func testShrinkKeepingTheOpenedAlbumFollowsIt() {
        let s = albumsScene(["A", "B", "C"])
        openReplaceBack(s, index: 2, albums("C"))
        XCTAssertEqual(s.navCursorForTest, 0)
        XCTAssertEqual(s.selectionIDForTest, "C")
    }

    func testRemovalOfTheOpenedAlbumClampsToARealRow() {
        let s = albumsScene(["A", "B", "C"])
        openReplaceBack(s, index: 2, albums("A", "B"))
        XCTAssertEqual(s.navCursorForTest, 1)
        XCTAssertNotNil(s.selectionIDForTest)
    }

    func testRemovalDownToOneRowClampsToIt() {
        let s = albumsScene(["A", "B", "C"])
        openReplaceBack(s, index: 2, albums("Z"))
        XCTAssertEqual(s.navCursorForTest, 0)
        XCTAssertEqual(s.selectionIDForTest, "Z")
    }

    func testReplacementWithAnEmptyListLeavesCursorAtZero() {
        let s = albumsScene(["A", "B", "C"])
        openReplaceBack(s, index: 2, [])
        XCTAssertEqual(s.navCursorForTest, 0)
        XCTAssertNil(s.selectionIDForTest)
    }

    func testArtistAlbumTracksStackSurvivesBothParentsChanging() {
        let spy = LibraryAppleScriptSpy()
        spy.artists = ["P", "Q", "R"].map { LibraryArtist(id: $0, name: "Artist \($0)") }
        let s = libraryTestScene(flag: BridgeSelectedFlag(false), wire: BridgeLibraryReadsWire([:]), spy: spy)
        XCTAssertEqual(s.subViewForTest, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Artist R") })
        _ = s.handle(.down); _ = s.handle(.down)            // artist R, row 2
        _ = s.handle(.enter)                                // artist -> albums (no tick: the read stays unlanded)
        s.replaceArtistAlbumsForTest(albums("A", "B", "C"))
        _ = s.handle(.down); _ = s.handle(.down)            // album C, row 2
        XCTAssertEqual(s.selectionIDForTest, "C")
        _ = s.handle(.enter)                                // album -> tracks
        s.replaceArtistAlbumsForTest(albums("X", "A", "B", "C"))
        s.replaceArtistsForTest([LibraryArtist(id: "R", name: "Artist R")])
        _ = s.handle(.escape)                               // tracks -> artist albums
        XCTAssertEqual(s.selectionIDForTest, "C")
        XCTAssertEqual(s.navCursorForTest, 3)
        s.replaceArtistAlbumsForTest(albums("A"))
        _ = s.handle(.escape)                               // albums -> artists
        XCTAssertEqual(s.navCursorForTest, 0)
        XCTAssertEqual(s.selectionIDForTest, "R")
    }
}
