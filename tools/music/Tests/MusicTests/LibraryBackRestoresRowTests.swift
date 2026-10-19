import XCTest
@testable import music

/// Back out of an album's tracks lands on the album that was opened, not row 0,
/// whichever source fills the list. Fakes only: the Bridge wire is canned, the
/// Music.app side is the spy; nothing plays and no socket or config is read.
final class LibraryBackRestoresRowTests: XCTestCase {

    private let frame = shellLayout(width: 140, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private let albumPage = """
    {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":3,
     "items":[{"id":"al1","title":"Amnesiac","artist":"Radiohead","track_count":3,"kind":"album"},
              {"id":"al2","title":"Kid A","artist":"Radiohead","track_count":3,"kind":"album"},
              {"id":"al3","title":"In Rainbows","artist":"Radiohead","track_count":3,"kind":"album"}],
     "next_cursor":null}
    """
    private let tracksPage = """
    {"ok":true,"op":"slice.libraryAlbumTracks","generation":3,
     "items":[{"id":"t1","title":"One","artist":"Radiohead","album":"Kid A","kind":"song"}]}
    """

    private func openSecondThenBack(_ s: LibraryScene) {
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.down)
        _ = s.handle(.down)
        XCTAssertEqual(s.navCursorForTest, 2)
        _ = s.handle(.enter)
        XCTAssertEqual(s.navCursorForTest, 0)
        _ = s.handle(.escape)
    }

    func testBackFromAlbumTracksKeepsTheOpenedAlbumOnSpanDAC() {
        let wire = BridgeLibraryReadsWire(["slice.libraryAlbums": [albumPage],
                                           "slice.libraryAlbumTracks": [tracksPage]])
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy())
        openSecondThenBack(s)
        XCTAssertEqual(s.navCursorForTest, 2)
    }

    func testBackFromAlbumTracksKeepsTheOpenedAlbumOnMusicTUI() {
        let spy = LibraryAppleScriptSpy()
        spy.albums = (1...3).map { LibraryAlbum(id: "ma\($0)", name: $0 == 3 ? "In Rainbows" : "Album \($0)",
                                                artist: "Radiohead", trackCount: 3) }
        let s = libraryTestScene(flag: BridgeSelectedFlag(false), wire: BridgeLibraryReadsWire([:]), spy: spy)
        openSecondThenBack(s)
        XCTAssertEqual(s.navCursorForTest, 2)
    }
}
