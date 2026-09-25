import XCTest
@testable import music

/// P4: pure renderers for the Bridge-mode CLI reads (catalogue search,
/// station search, discover, playlist listings, playlist tracks, history).
/// Every renderer takes provider-surface types already in hand
/// (`ProviderSurfaces.swift`, `MusicRow`, `DiscoverRail`/`DiscoverItem`,
/// `Station`) and returns text lines and/or one JSON document — no cache, no
/// I/O. Literals are pinned against the shipped Music.app formatters named in
/// `score-part2.md` P4.
final class CLIBridgeReadsTests: XCTestCase {

    // MARK: - Catalogue search

    func testCatalogueSearchSongLineWithAlbum() {
        let r = CatalogueRecord(kind: .song, catalogueID: "111", title: "Fake Plastic Trees",
                                artist: "Radiohead", album: "The Bends")
        XCTAssertEqual(catalogueSearchLines([r]),
                       ["1. Fake Plastic Trees — Radiohead [The Bends] (id: 111)"])
    }

    func testCatalogueSearchSongLineWithoutAlbumOmitsBrackets() {
        let r = CatalogueRecord(kind: .song, catalogueID: "111", title: "Fake Plastic Trees",
                                artist: "Radiohead", album: nil)
        XCTAssertEqual(catalogueSearchLines([r]),
                       ["1. Fake Plastic Trees — Radiohead (id: 111)"])
    }

    func testCatalogueSearchNumbersSongsOnlyAlbumsUnnumberedUnderHeader() {
        let song = CatalogueRecord(kind: .song, catalogueID: "1", title: "Song One",
                                   artist: "Artist A", album: nil)
        let album = CatalogueRecord(kind: .album, catalogueID: "2", title: "Album One",
                                    artist: "Artist B", album: nil)
        XCTAssertEqual(catalogueSearchLines([song, album]), [
            "1. Song One — Artist A (id: 1)",
            "\nAlbums:",
            "  Album One — Artist B (id: 2)",
        ])
    }

    func testCatalogueSearchAlbumsOnlyHeaderHasNoLeadingBlankLine() {
        let album = CatalogueRecord(kind: .album, catalogueID: "2", title: "Album One",
                                    artist: "Artist B", album: nil)
        XCTAssertEqual(catalogueSearchLines([album]), [
            "Albums:",
            "  Album One — Artist B (id: 2)",
        ])
    }

    func testCatalogueSearchSongRowsNumberOnlySongsSkippingAlbums() {
        let song1 = CatalogueRecord(kind: .song, catalogueID: "1", title: "S1", artist: "A1", album: "Al1")
        let album = CatalogueRecord(kind: .album, catalogueID: "2", title: "Al", artist: "A2", album: nil)
        let song2 = CatalogueRecord(kind: .song, catalogueID: "3", title: "S2", artist: "A3", album: nil)
        let rows = catalogueSearchSongRows([song1, album, song2])
        XCTAssertEqual(rows, [
            BridgeCatalogueSongRow(index: 1, title: "S1", artist: "A1", album: "Al1", bridgeID: "1"),
            BridgeCatalogueSongRow(index: 2, title: "S2", artist: "A3", album: nil, bridgeID: "3"),
        ])
    }

    func testCatalogueSearchJSONSongsOnlyIsBareArrayAlbumAbsentNotEmpty() {
        let withAlbum = CatalogueRecord(kind: .song, catalogueID: "1", title: "S1", artist: "A1", album: "Al1")
        let withoutAlbum = CatalogueRecord(kind: .song, catalogueID: "2", title: "S2", artist: "A2", album: nil)
        let json = catalogueSearchJSON([withAlbum, withoutAlbum])
        let expected = "[{\"album\":\"Al1\",\"artist\":\"A1\",\"id\":\"1\",\"title\":\"S1\"}," +
                       "{\"artist\":\"A2\",\"id\":\"2\",\"title\":\"S2\"}]"
        XCTAssertEqual(json, expected)
        XCTAssertFalse(json.contains("\"album\":\"\""))
    }

    func testCatalogueSearchJSONMultiTypeIsKeyedObject() {
        let song = CatalogueRecord(kind: .song, catalogueID: "1", title: "S1", artist: "A1", album: nil)
        let album = CatalogueRecord(kind: .album, catalogueID: "2", title: "Al", artist: "A2", album: nil)
        let json = catalogueSearchJSON([song, album], songsOnlyRequest: false)
        let expected = "{\"albums\":[{\"artist\":\"A2\",\"id\":\"2\",\"title\":\"Al\"}]," +
                       "\"songs\":[{\"artist\":\"A1\",\"id\":\"1\",\"title\":\"S1\"}]}"
        XCTAssertEqual(json, expected)
    }

    func testCatalogueSearchJSONAlbumsOnlyOmitsSongsKey() {
        let album = CatalogueRecord(kind: .album, catalogueID: "2", title: "Al", artist: "A2", album: nil)
        let json = catalogueSearchJSON([album], songsOnlyRequest: false)
        XCTAssertFalse(json.contains("\"songs\""))
        XCTAssertTrue(json.contains("\"albums\""))
    }

    // MARK: - Station search (shipped RadioSearch lines exactly)

    func testStationSearchLineWithLiveSuffixAndURL() {
        let s = Station(id: "ra.1", name: "BBC Radio 1", url: "https://music.apple.com/x", isLive: true, artworkURL: nil)
        XCTAssertEqual(stationSearchLines([s]), ["BBC Radio 1  [LIVE]\n  https://music.apple.com/x"])
    }

    func testStationSearchLineWithoutLiveSuffix() {
        let s = Station(id: "ra.1", name: "Chill", url: "https://music.apple.com/y", isLive: false, artworkURL: nil)
        XCTAssertEqual(stationSearchLines([s]), ["Chill\n  https://music.apple.com/y"])
    }

    func testStationSearchLineNilIsLiveTreatedAsNotLive() {
        let s = Station(id: "ra.1", name: "Chill", url: "https://music.apple.com/y", isLive: nil, artworkURL: nil)
        XCTAssertEqual(stationSearchLines([s]), ["Chill\n  https://music.apple.com/y"])
    }

    func testStationSearchEmptyIsShippedSentence() {
        XCTAssertEqual(stationSearchLines([]),
                       ["No stations found. Station search is shallow — pasting the URL always works."])
    }

    // MARK: - Discover

    private func discoverItem(kind: DiscoverItemDetail, name: String = "Item", subtitle: String? = "Someone",
                              id: String = "id1") -> DiscoverItem {
        DiscoverItem(id: id, name: name, subtitle: subtitle, url: nil, artworkURL: nil, detail: kind)
    }

    func testDiscoverStationLineHasPlayMarker() {
        let rail = DiscoverRail(id: "r1", title: "Stations For You",
                                items: [discoverItem(kind: .station(isLive: true), name: "Alt", subtitle: nil)],
                                isRecentlyPlayed: false, resourceTypes: ["stations"])
        XCTAssertEqual(bridgeDiscoverLines([rail]), [
            "\nStations For You",
            "  ▶ Alt  [station]",
        ])
    }

    func testDiscoverNonStationLineHasBlankMarkerAndSubtitle() {
        let rail = DiscoverRail(id: "r1", title: "New Albums",
                                items: [discoverItem(kind: .album(trackCount: nil, year: nil, genre: nil),
                                                     name: "OK Computer", subtitle: "Radiohead")],
                                isRecentlyPlayed: false, resourceTypes: ["albums"])
        XCTAssertEqual(bridgeDiscoverLines([rail]), [
            "\nNew Albums",
            "    OK Computer — Radiohead  [album]",
        ])
    }

    func testDiscoverJSONOmitsRecentlyPlayedAndURLNeverFalseOrEmpty() {
        let rail = DiscoverRail(id: "r1", title: "New Albums",
                                items: [discoverItem(kind: .album(trackCount: nil, year: nil, genre: nil),
                                                     name: "OK Computer", subtitle: "Radiohead")],
                                isRecentlyPlayed: false, resourceTypes: ["albums"])
        let json = bridgeDiscoverJSON([rail])
        XCTAssertFalse(json.contains("recentlyPlayed"))
        XCTAssertFalse(json.contains("\"url\""))
        XCTAssertTrue(json.contains("\"title\":\"New Albums\""))
    }

    func testDiscoverJSONIncludesArtworkOnlyWhenPresent() {
        var item = discoverItem(kind: .song, name: "Song", subtitle: nil)
        let railNoArt = DiscoverRail(id: "r1", title: "T", items: [item], isRecentlyPlayed: false, resourceTypes: [])
        XCTAssertFalse(bridgeDiscoverJSON([railNoArt]).contains("artwork"))

        item = DiscoverItem(id: "id1", name: "Song", subtitle: nil, url: nil, artworkURL: "https://a.png", detail: .song)
        let railWithArt = DiscoverRail(id: "r1", title: "T", items: [item], isRecentlyPlayed: false, resourceTypes: [])
        XCTAssertTrue(bridgeDiscoverJSON([railWithArt]).contains("\"artwork\":\"https:\\/\\/a.png\""))
    }

    // MARK: - Playlist list

    func testPlaylistListLinesAreJustNames() {
        let rows = [MusicRow(id: "p1", title: "Workout", artist: "", album: nil, kind: .playlist),
                   MusicRow(id: "p2", title: "Chill", artist: "", album: nil, kind: .playlist)]
        XCTAssertEqual(playlistListLines(rows), ["Workout", "Chill"])
    }

    func testPlaylistListJSONHasNameAndBridgeIDNoBareID() {
        let rows = [MusicRow(id: "p1", title: "Workout", artist: "", album: nil, kind: .playlist)]
        let json = playlistListJSON(rows)
        XCTAssertEqual(json, "{\"playlists\":[{\"bridge_id\":\"p1\",\"name\":\"Workout\"}]}")
        XCTAssertFalse(json.contains("\"id\":"))
    }

    func testPlaylistListEmpty() {
        XCTAssertEqual(playlistListLines([]), [])
        XCTAssertEqual(playlistListJSON([]), "{\"playlists\":[]}")
    }

    // MARK: - Playlist tracks

    func testPlaylistTracksLinesNumberedWithAlbumBracketAlwaysPresent() {
        let rows = [MusicRow(id: "t1", title: "Fake Plastic Trees", artist: "Radiohead", album: "The Bends", kind: .song),
                   MusicRow(id: "t2", title: "No Surprises", artist: "Radiohead", album: nil, kind: .song)]
        XCTAssertEqual(playlistTracksLines(rows), [
            "1. Fake Plastic Trees — Radiohead [The Bends]",
            "2. No Surprises — Radiohead []",
        ])
    }

    func testPlaylistTrackSongRowsNumberFromOneInOrder() {
        let rows = [MusicRow(id: "t1", title: "A", artist: "X", album: "Al", kind: .song),
                   MusicRow(id: "t2", title: "B", artist: "Y", album: nil, kind: .song)]
        XCTAssertEqual(playlistTrackSongRows(rows), [
            BridgePlaylistTrackRow(index: 1, title: "A", artist: "X", album: "Al", bridgeID: "t1"),
            BridgePlaylistTrackRow(index: 2, title: "B", artist: "Y", album: nil, bridgeID: "t2"),
        ])
    }

    func testPlaylistTracksJSONAlbumAbsentNotEmptyStringHasBridgeID() {
        let rows = [MusicRow(id: "t1", title: "A", artist: "X", album: "Al", kind: .song),
                   MusicRow(id: "t2", title: "B", artist: "Y", album: nil, kind: .song)]
        let json = playlistTracksJSON(playlist: "My Mix", tracks: rows)
        let expected = "{\"playlist\":\"My Mix\",\"tracks\":[" +
            "{\"album\":\"Al\",\"artist\":\"X\",\"bridge_id\":\"t1\",\"number\":1,\"track\":\"A\"}," +
            "{\"artist\":\"Y\",\"bridge_id\":\"t2\",\"number\":2,\"track\":\"B\"}]}"
        XCTAssertEqual(json, expected)
    }

    // MARK: - History

    func testHistoryNumberedSongLineWithCatalogueIDAndAlbum() {
        let item = HistoryItem(type: "songs", id: "s1", name: "Idioteque", artist: "Radiohead",
                               album: "Kid A", catalogueID: "999")
        XCTAssertEqual(historyLines([item], label: "recent"), ["1. Idioteque — Radiohead [Kid A]"])
    }

    func testHistoryNumberedSongLineOmitsAlbumBracketWhenAbsent() {
        let item = HistoryItem(type: "songs", id: "s1", name: "Idioteque", artist: "Radiohead",
                               album: nil, catalogueID: "999")
        XCTAssertEqual(historyLines([item], label: "recent"), ["1. Idioteque — Radiohead"])
    }

    func testHistoryLibraryOnlySongIsUnnumberedWithLibraryLabel() {
        let item = HistoryItem(type: "songs", id: "s1", name: "Idioteque", artist: "Radiohead",
                               album: nil, catalogueID: nil)
        XCTAssertEqual(historyLines([item], label: "recent"), ["   Idioteque — Radiohead (library)"])
    }

    func testHistoryOtherTypeIsUnnumberedWithKindLabel() {
        let item = HistoryItem(type: "library-playlists", id: "p1", name: "Focus", artist: nil,
                               album: nil, catalogueID: nil)
        XCTAssertEqual(historyLines([item], label: "recent"), ["   Focus (playlist)"])
    }

    func testHistoryNumberingSkipsUnnumberedRows() {
        let song = HistoryItem(type: "songs", id: "s1", name: "Numbered", artist: "A",
                               album: nil, catalogueID: "1")
        let libraryOnly = HistoryItem(type: "songs", id: "s2", name: "LibOnly", artist: "A",
                                      album: nil, catalogueID: nil)
        let song2 = HistoryItem(type: "songs", id: "s3", name: "Second", artist: "A",
                                album: nil, catalogueID: "2")
        XCTAssertEqual(historyLines([song, libraryOnly, song2], label: "recent"), [
            "1. Numbered — A",
            "   LibOnly — A (library)",
            "2. Second — A",
        ])
    }

    func testHistorySongRowsOnlyIncludeCatalogueIDItemsNumberedFromOne() {
        let song = HistoryItem(type: "songs", id: "s1", name: "Numbered", artist: "A",
                               album: "Al", catalogueID: "1")
        let libraryOnly = HistoryItem(type: "songs", id: "s2", name: "LibOnly", artist: "A",
                                      album: nil, catalogueID: nil)
        let rows = historySongRows([song, libraryOnly])
        XCTAssertEqual(rows, [BridgeHistorySongRow(index: 1, title: "Numbered", artist: "A", album: "Al", catalogueID: "1")])
    }

    func testHistoryEmptyLineAndJSON() {
        XCTAssertEqual(historyLines([], label: "recent"), ["No recent history."])
        XCTAssertEqual(historyJSON([], label: "recent"), "{\"recent\":[]}")
        XCTAssertEqual(historyJSON([], label: "heavy rotation"), "{\"heavy-rotation\":[]}")
    }

    func testHistoryJSONKeepsAlbumAndArtistKeysAsShippedEvenWhenEmpty() {
        let item = HistoryItem(type: "songs", id: "s1", name: "Idioteque", artist: nil,
                               album: nil, catalogueID: "999")
        let json = historyJSON([item], label: "recent")
        XCTAssertEqual(json, "{\"items\":[{\"album\":\"\",\"artist\":\"\",\"name\":\"Idioteque\",\"type\":\"songs\"}]}")
    }

    /// A mixed request that finds no albums still prints the keyed object, as the
    /// shipped multi-type body does, never a bare array.
    func testAMixedRequestWithNoAlbumsStillPrintsAnObject() throws {
        let song = CatalogueRecord(kind: .song, catalogueID: "1", title: "S", artist: "A", album: nil)
        let json = catalogueSearchJSON([song], songsOnlyRequest: false)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["songs"]); XCTAssertNil(obj["albums"])
    }
}
