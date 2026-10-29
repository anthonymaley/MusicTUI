import XCTest
@testable import music

/// The Artists list's Uploaded header (ruling 2026-10-28 22:18): SpanDAC reports
/// a track count of 0 for some of a person's own copies, so the 12"/EP and Albums
/// tiers hide them and their artists. In those tiers, on SpanDAC's data, one
/// collapsible row at the bottom holds them. Pure helpers first, then the scene
/// through `libraryTestScene` (a canned SpanDAC wire, an inert AppleScript backend
/// and a temporary result cache: nothing reaches SpanDAC, Music or ~/.config/music).
final class UploadedArtistsHeaderTests: XCTestCase {

    private let frame = shellLayout(width: 140, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func album(_ id: String, _ name: String, _ artist: String, _ tracks: Int) -> LibraryAlbum {
        LibraryAlbum(id: id, name: name, artist: artist, trackCount: tracks)
    }

    // MARK: - Pure helpers

    func testUploadedAlbumsAreTheZeroCountOnesSortedByArtistThenTitle() {
        let albums = [
            album("a", "Garage Flower", "The Stone Roses", 0),
            album("b", "Souvlaki", "Slowdive", 10),
            album("c", "Loveless", "My Bloody Valentine", 0),
            album("d", "Isn't Anything", "my bloody  valentine", 0),
            album("e", "Stub", "Slowdive", 1),
        ]
        XCTAssertEqual(uploadedAlbumIndices(albums: albums), [3, 2, 0])
    }

    func testTheHeaderAppliesOnlyToAFilteredTierOfLoadedSpanDACAlbums() {
        XCTAssertTrue(showsUploadedHeader(tier: .epOr12, albumsFromSpanDAC: true, albumsLoaded: true))
        XCTAssertTrue(showsUploadedHeader(tier: .albums, albumsFromSpanDAC: true, albumsLoaded: true))
        XCTAssertFalse(showsUploadedHeader(tier: .all, albumsFromSpanDAC: true, albumsLoaded: true))
        XCTAssertFalse(showsUploadedHeader(tier: .albums, albumsFromSpanDAC: false, albumsLoaded: true))
        XCTAssertFalse(showsUploadedHeader(tier: .albums, albumsFromSpanDAC: true, albumsLoaded: false))
    }

    func testTheHeaderSitsAtTheBottomAndOpensToItsAlbums() {
        let albums = [album("a", "Garage Flower", "The Stone Roses", 0), album("c", "Loveless", "My Bloody Valentine", 0)]
        let uploaded = uploadedAlbumIndices(albums: albums)
        XCTAssertEqual(artistListRows(artistIndices: [4, 7], albums: albums, uploaded: uploaded,
                                      showUploaded: true, expanded: false, filter: ""),
                       [.artist(4), .artist(7), .uploadedHeader(count: 2)])
        XCTAssertEqual(artistListRows(artistIndices: [4, 7], albums: albums, uploaded: uploaded,
                                      showUploaded: true, expanded: true, filter: ""),
                       [.artist(4), .artist(7), .uploadedHeader(count: 2), .uploadedAlbum(1), .uploadedAlbum(0)])
    }

    func testNoUploadedAlbumsOrNoHeaderMeansJustTheArtists() {
        let albums = [album("b", "Souvlaki", "Slowdive", 10)]
        XCTAssertEqual(artistListRows(artistIndices: [0], albums: albums, uploaded: uploadedAlbumIndices(albums: albums),
                                      showUploaded: true, expanded: true, filter: ""), [.artist(0)])
        let withUploaded = [album("c", "Loveless", "My Bloody Valentine", 0)]
        XCTAssertEqual(artistListRows(artistIndices: [0], albums: withUploaded, uploaded: [0],
                                      showUploaded: false, expanded: true, filter: ""), [.artist(0)])
    }

    func testAFilterShowsTheHeaderOnlyForAMatchAndOpensItToTheMatches() {
        let albums = [album("a", "Garage Flower", "The Stone Roses", 0), album("c", "Loveless", "My Bloody Valentine", 0)]
        let uploaded = uploadedAlbumIndices(albums: albums)
        // Title match, collapsed: shown open with the match only; the count stays the whole header's.
        XCTAssertEqual(artistListRows(artistIndices: [], albums: albums, uploaded: uploaded,
                                      showUploaded: true, expanded: false, filter: "LOVE"),
                       [.uploadedHeader(count: 2), .uploadedAlbum(1)])
        // Artist match.
        XCTAssertEqual(artistListRows(artistIndices: [], albums: albums, uploaded: uploaded,
                                      showUploaded: true, expanded: false, filter: "stone"),
                       [.uploadedHeader(count: 2), .uploadedAlbum(0)])
        // No match: no header.
        XCTAssertEqual(artistListRows(artistIndices: [3], albums: albums, uploaded: uploaded,
                                      showUploaded: true, expanded: true, filter: "zzz"), [.artist(3)])
    }

    func testTheReducerOpensAndPlaysAnAlbumRowOnTheArtistsList() {
        let nav = LibraryNav(subView: .artists, stack: [.artistList], cursor: 3)
        let sel = LibrarySelection(id: "u1", primary: "Loveless", secondary: "My Bloody Valentine")
        let (opened, open) = libraryReduce(nav, .enter, itemCount: 5, selection: sel, albumRow: true)
        XCTAssertEqual(opened.stack, [.artistList, .tracks(albumID: "u1", albumTitle: "Loveless", artist: "My Bloody Valentine")])
        XCTAssertEqual(opened.returnCursors, [3])
        XCTAssertEqual(open, .fetchAlbumTracks(albumID: "u1", albumTitle: "Loveless", artist: "My Bloody Valentine"))
        XCTAssertEqual(libraryReduce(nav, .play, itemCount: 5, selection: sel, albumRow: true).1,
                       .play(.album(id: "u1", title: "Loveless", artist: "My Bloody Valentine")))
        XCTAssertEqual(libraryReduce(nav, .shuffle, itemCount: 5, selection: sel, albumRow: true).1,
                       .shuffle(.album(id: "u1", title: "Loveless", artist: "My Bloody Valentine")))
        // Without the flag an artist row still drills into the artist.
        XCTAssertEqual(libraryReduce(nav, .enter, itemCount: 5, selection: sel).1,
                       .fetchArtistAlbums(artistID: "u1", artistName: "Loveless"))
    }

    // MARK: - Scene, SpanDAC data

    private func albumsPage(_ albums: [(String, String, String, Int)]) -> String {
        let items = albums.map {
            "{\"id\":\"\($0.0)\",\"title\":\"\($0.1)\",\"artist\":\"\($0.2)\",\"track_count\":\($0.3),\"kind\":\"album\"}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryAlbums\",\"generation\":3,\"total\":\(albums.count),\"items\":[\(items)],\"next_cursor\":null}"
    }
    private let artistsPage = """
    {"ok":true,"op":"slice.libraryArtists","generation":3,"total":3,
     "items":[{"id":"ar1","title":"Slowdive","kind":"artist"},{"id":"ar2","title":"My Bloody Valentine","kind":"artist"},
              {"id":"ar3","title":"The Stone Roses","kind":"artist"}],"next_cursor":null}
    """
    private let ownCopies: [(String, String, String, Int)] = [
        ("al1", "Souvlaki", "Slowdive", 10), ("ep1", "Holding Our Breath", "Slowdive", 4),
        ("u2", "Garage Flower", "The Stone Roses", 0), ("u1", "Loveless", "My Bloody Valentine", 0),
    ]
    private func tracksReply(_ ids: [String]) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"T\($0)\",\"artist\":\"My Bloody Valentine\",\"album\":\"Loveless\",\"kind\":\"song\"}" }
            .joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":3,\"items\":[\(items)]}"
    }

    /// A SpanDAC scene on the Artists list with both lists loaded, at `tier`.
    private func spanDACScene(_ wire: BridgeLibraryReadsWire, tier: ArtistFilterMode,
                              status: StatusStore = StatusStore()) -> LibraryScene {
        let s = libraryTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: LibraryAppleScriptSpy(), status: status)
        XCTAssertTrue(settleScene(s) { render(s).contains("The Stone Roses") }, "the artists never loaded")
        var mode = ArtistFilterMode.all
        while mode != tier { _ = s.handle(.char("a")); mode = mode.next }
        return s
    }
    private func render(_ s: LibraryScene) -> String { s.render(frame: frame, snapshot: idle) }

    func testTheHeaderIsTheLastRowInBothFilteredTiersOnSpanDAC() {
        for tier in [ArtistFilterMode.epOr12, .albums] {
            let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                               "slice.libraryAlbums": [albumsPage(ownCopies)]])
            let s = spanDACScene(wire, tier: tier)
            XCTAssertTrue(settleScene(s) { render(s).contains("\u{203A} Uploaded (2)") }, "\(tier): no header")
            XCTAssertFalse(render(s).contains("Loveless"), "\(tier): the header starts closed")
            // Slowdive (the only tier artist), then the header: End lands on it.
            _ = s.handle(.end)
            XCTAssertEqual(s.navCursorForTest, 1, "\(tier)")
            XCTAssertNil(s.selectionIDForTest, "\(tier): the header is no artist or album")
            _ = s.handle(.down)
            XCTAssertEqual(s.navCursorForTest, 1, "\(tier): the header is the bottom row")
        }
    }

    func testTheHeaderIsAbsentInTheAllTier() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                           "slice.libraryAlbums": [albumsPage(ownCopies)]])
        let s = spanDACScene(wire, tier: .albums)
        XCTAssertTrue(settleScene(s) { render(s).contains("Uploaded (2)") })
        _ = s.handle(.char("a"))   // Albums -> All
        XCTAssertFalse(render(s).contains("Uploaded"))
        _ = s.handle(.end)
        XCTAssertEqual(s.selectionIDForTest, "ar3", "All lists the artists and nothing after them")
    }

    func testNoZeroCountAlbumsMeansNoHeader() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                           "slice.libraryAlbums": [albumsPage(Array(ownCopies.prefix(2)))]])
        let s = spanDACScene(wire, tier: .albums)
        XCTAssertTrue(settleScene(s) { wire.threadEnded(op: "slice.libraryAlbums", at: 0) })
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        XCTAssertTrue(render(s).contains("Slowdive"))
        XCTAssertFalse(render(s).contains("Uploaded"))
    }

    func testNoHeaderWhileTheAlbumsAreStillLoading() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                           "slice.libraryAlbums": [albumsPage(ownCopies)]])
        wire.gate(op: "slice.libraryAlbums", at: 0)
        let s = spanDACScene(wire, tier: .albums)
        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryAlbums", at: 0) })
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        XCTAssertFalse(render(s).contains("Uploaded"))
        wire.release(op: "slice.libraryAlbums")
        XCTAssertTrue(settleScene(s) { render(s).contains("Uploaded (2)") })
    }

    func testEnterOpensAndClosesTheHeaderInPlaceAndTheCursorStaysValid() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                           "slice.libraryAlbums": [albumsPage(ownCopies)]])
        let s = spanDACScene(wire, tier: .albums)
        XCTAssertTrue(settleScene(s) { render(s).contains("Uploaded (2)") })
        _ = s.handle(.end)                                   // the header
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertEqual(s.levelForTest, .artistList, "the header opens in place")
        XCTAssertEqual(s.navCursorForTest, 1)
        let open = render(s)
        XCTAssertTrue(open.contains("\u{2304} Uploaded (2)"))
        // Sorted by artist: My Bloody Valentine before The Stone Roses.
        // Labelled like album rows (`title — artist`), cut to the rail's width.
        let loveless = open.range(of: "Loveless \u{2014} My Bloody")
        let garage = open.range(of: "Garage Flower \u{2014} The")
        XCTAssertNotNil(loveless); XCTAssertNotNil(garage)
        if let loveless, let garage { XCTAssertLessThan(loveless.lowerBound, garage.lowerBound) }
        _ = s.handle(.down)
        XCTAssertEqual(s.selectionIDForTest, "u1")
        _ = s.handle(.down)
        XCTAssertEqual(s.selectionIDForTest, "u2")
        _ = s.handle(.down)
        XCTAssertEqual(s.selectionIDForTest, "u2", "the last album is the bottom row")
        _ = s.handle(.end)
        XCTAssertEqual(s.navCursorForTest, 3)
        // Back to the header and close it with → (the list's drill key).
        _ = s.handle(.up); _ = s.handle(.up)
        XCTAssertEqual(s.handle(.right), .redraw)
        XCTAssertEqual(s.navCursorForTest, 1)
        XCTAssertTrue(render(s).contains("\u{203A} Uploaded (2)"))
        XCTAssertFalse(render(s).contains("Loveless"))
        _ = s.handle(.end)
        XCTAssertEqual(s.navCursorForTest, 1, "closed, the header is the bottom row again")
    }

    func testEnterOnAnUploadedAlbumOpensItsTracksThroughTheAlbumPath() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                           "slice.libraryAlbums": [albumsPage(ownCopies)],
                                           "slice.libraryAlbumTracks": [tracksReply(["t1", "t2"])]])
        let s = spanDACScene(wire, tier: .albums)
        XCTAssertTrue(settleScene(s) { render(s).contains("Uploaded (2)") })
        _ = s.handle(.end); _ = s.handle(.enter); _ = s.handle(.down)   // Loveless
        _ = s.handle(.enter)
        XCTAssertEqual(s.levelForTest, .tracks(albumID: "u1", albumTitle: "Loveless", artist: "My Bloody Valentine"))
        XCTAssertTrue(settleScene(s) { s.trackCacheForTest["u1"] == ["Tt1", "Tt2"] }, "the album's tracks never landed")
        XCTAssertEqual(wire.sent("slice.libraryAlbumTracks").map { $0["id"] as? String }, ["u1"])
        XCTAssertTrue(wire.sent("slice.libraryArtistAlbums").isEmpty, "an Uploaded album is no artist drill")
        XCTAssertTrue(render(s).contains("Tt1"))
        // Back lands on the album that was opened, the header still open.
        _ = s.handle(.escape)
        XCTAssertEqual(s.levelForTest, .artistList)
        XCTAssertEqual(s.selectionIDForTest, "u1")
    }

    func testPOnAnUploadedAlbumPlaysItAsAnAlbum() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                           "slice.libraryAlbums": [albumsPage(ownCopies)]])
        let s = spanDACScene(wire, tier: .albums)
        XCTAssertTrue(settleScene(s) { render(s).contains("Uploaded (2)") })
        _ = s.handle(.end); _ = s.handle(.enter); _ = s.handle(.down); _ = s.handle(.down)   // Garage Flower
        XCTAssertEqual(s.handle(.char("p")), .push(.nowPlaying))
        // Bridge's album play asks for the album's revision or rows by its id first
        // (both unscripted here, so it stops there and nothing is queued).
        XCTAssertTrue(settleScene(s) {
            (wire.sent("slice.listRev") + wire.sent("slice.libraryAlbumTracks")).contains { ($0["id"] as? String) == "u2" }
        }, "ops: \(wire.opsInOrder())")
        XCTAssertFalse(wire.opsInOrder().contains("slice.libraryArtistSongs"), "an album row never plays an artist")
    }

    func testPAndSOnTheHeaderPlayNothingAndSayWhatToDo() {
        let status = StatusStore()
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                           "slice.libraryAlbums": [albumsPage(ownCopies)]])
        let s = spanDACScene(wire, tier: .epOr12, status: status)
        XCTAssertTrue(settleScene(s) { render(s).contains("Uploaded (2)") })
        _ = s.handle(.end)
        // The Artists refresh watch may read `slice.status` meanwhile; nothing else may go out.
        func asked() -> [String] { wire.opsInOrder().filter { $0 != "slice.status" } }
        for key in [KeyPress.char("p"), .char("s")] {
            let before = asked()
            XCTAssertEqual(s.handle(key), .none)
            XCTAssertEqual(status.current()?.text, "Open Uploaded and pick an album")
            for _ in 0..<10 { _ = s.tick(snapshot: idle) }
            XCTAssertEqual(asked(), before, "a key on the header reached SpanDAC")
        }
        XCTAssertEqual(s.levelForTest, .artistList)
    }

    func testTheFilterShowsTheHeaderOnlyWithAMatchingAlbumAndOpensIt() {
        let wire = BridgeLibraryReadsWire(["slice.libraryArtists": [artistsPage],
                                           "slice.libraryAlbums": [albumsPage(ownCopies)]])
        let s = spanDACScene(wire, tier: .albums)
        XCTAssertTrue(settleScene(s) { render(s).contains("Uploaded (2)") })
        _ = s.handle(.char("/"))
        for c in "garage" { _ = s.handle(.char(c)) }
        _ = s.handle(.enter)
        let filtered = render(s)
        XCTAssertTrue(filtered.contains("\u{2304} Uploaded (2)"), "a match opens the header")
        XCTAssertTrue(filtered.contains("Garage Flower"))
        XCTAssertFalse(filtered.contains("Loveless"))
        XCTAssertFalse(filtered.contains("Slowdive"))
        _ = s.handle(.end)
        XCTAssertEqual(s.selectionIDForTest, "u2")
        // A filter no uploaded album matches: no header.
        _ = s.handle(.char("/"))
        for c in "zz" { _ = s.handle(.char(c)) }
        _ = s.handle(.enter)
        XCTAssertFalse(render(s).contains("Uploaded"))
        XCTAssertTrue(render(s).contains("(no matches)"))
    }

    // MARK: - Scene, Music.app data

    func testTheMusicAppPathNeverShowsTheHeader() {
        let spy = LibraryAppleScriptSpy()
        spy.artists = [LibraryArtist(id: "ar1", name: "Slowdive"), LibraryArtist(id: "ar2", name: "My Bloody Valentine")]
        spy.albums = [album("al1", "Souvlaki", "Slowdive", 10), album("u1", "Loveless", "My Bloody Valentine", 0)]
        let s = libraryTestScene(flag: BridgeSelectedFlag(false), wire: BridgeLibraryReadsWire(), spy: spy)
        XCTAssertTrue(settleScene(s) { render(s).contains("My Bloody Valentine") })
        _ = s.handle(.char("a")); _ = s.handle(.char("a"))   // Albums tier
        XCTAssertTrue(settleScene(s) { spy.count("onAlbums") == 1 && !render(s).contains("My Bloody Valentine") },
                      "the Albums tier never applied")
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        XCTAssertTrue(render(s).contains("Slowdive"))
        XCTAssertFalse(render(s).contains("Uploaded"))
    }
}
