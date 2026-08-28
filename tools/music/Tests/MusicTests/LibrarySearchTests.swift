// tools/music/Tests/MusicTests/LibrarySearchTests.swift
// The library search AppleScript builders: the whose clause assembled from
// only the non-empty inputs, and the small playlist-name read used when
// playlist results are requested.
import XCTest
@testable import music

final class LibrarySearchTests: XCTestCase {
    func testTermOnlyClauseSearchesNameArtistAndAlbum() {
        let script = librarySearchScript(term: "smiths", artist: nil, album: nil)
        XCTAssertTrue(script.contains("whose (name contains \"smiths\" or artist contains \"smiths\" or album contains \"smiths\")"))
        XCTAssertTrue(script.contains("persistent ID of (every track of playlist \"Library\" whose (name contains \"smiths\""))
        XCTAssertTrue(script.contains("album artist of (every track of playlist \"Library\" whose (name contains \"smiths\""))
        XCTAssertFalse(script.contains("repeat"))
        XCTAssertFalse(script.contains("cloud status"))
    }

    func testArtistAndAlbumBecomeClausesNotTermText() {
        let script = librarySearchScript(term: "kid", artist: "Radiohead", album: "Kid A")
        XCTAssertTrue(script.contains("and artist contains \"Radiohead\""))
        XCTAssertTrue(script.contains("and album contains \"Kid A\""))
        XCTAssertFalse(script.contains("contains \"kid Radiohead\""))
    }

    func testEmptyTermWithArtistOnlyEmitsOnlyTheArtistClause() {
        let script = librarySearchScript(term: "", artist: "Radiohead", album: nil)
        XCTAssertTrue(script.contains("whose artist contains \"Radiohead\""))
        XCTAssertFalse(script.contains("contains \"\""))

        let script2 = librarySearchScript(term: "x", artist: "", album: "")
        XCTAssertFalse(script2.contains("contains \"\""))
    }

    func testAllEmptyEmitsNoWhose() {
        let script = librarySearchScript(term: "", artist: nil, album: nil)
        XCTAssertTrue(script.contains("persistent ID of (every track of playlist \"Library\"))"))
        XCTAssertFalse(script.contains("whose"))
    }

    // Music throws -1728 on a column get over a whose that matches nothing,
    // so the script must return "" itself; measured live 2026-08-28.
    func testZeroMatchesReturnEmptyBeforeAnyColumnGet() {
        let script = librarySearchScript(term: "smiths", artist: nil, album: nil)
        XCTAssertTrue(script.contains("if (count of (every track of playlist \"Library\" whose (name contains \"smiths\" or artist contains \"smiths\" or album contains \"smiths\"))) is 0 then return \"\""))
        XCTAssertFalse(script.contains("set hits to"))
        XCTAssertFalse(script.contains("set lib to"))
        XCTAssertFalse(script.contains("repeat"))
        XCTAssertLessThan(script.range(of: "if (count of")!.lowerBound, script.range(of: "persistent ID of")!.lowerBound)
    }

    func testEscapesQuotesAndBackslashes() {
        let script = librarySearchScript(term: "AC\\DC \"Live\"", artist: nil, album: nil)
        XCTAssertTrue(script.contains("AC\\\\DC \\\"Live\\\""))
    }

    func testPlaylistNamesScriptReadsUserPlaylistsUnderRowSeparator() {
        let script = libraryPlaylistNamesScript()
        XCTAssertTrue(script.contains("name of every user playlist"))
        XCTAssertTrue(script.contains("ASCII character 30"))
        XCTAssertFalse(script.contains("repeat"))
    }

    func testParsesFiveColumnsIntoRowsByPosition() {
        let fs = String(asFieldSep)
        let rs = "\u{1E}"
        let ids = "P1\(rs)P2"
        let names = "Idioteque\(rs)Sexy Boy"
        let artists = "Radiohead\(rs)Air"
        let albums = "Kid A\(rs)Moon Safari"
        let albumArtists = "Radiohead\(rs)"
        let raw = [ids, names, artists, albums, albumArtists].joined(separator: fs) + "\n"
        let rows = parseLibrarySearchRows(raw)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], LibrarySearchRow(persistentID: "P1", name: "Idioteque", artist: "Radiohead",
                                                  album: "Kid A", albumArtist: "Radiohead"))
        XCTAssertEqual(rows[1].albumArtist, "")
    }

    func testSixColumnsIsRejectedByTheFiveColumnParser() {
        let fs = String(asFieldSep)
        let rs = "\u{1E}"
        let ids = "P1\(rs)P2"
        let names = "Idioteque\(rs)Sexy Boy"
        let artists = "Radiohead\(rs)Air"
        let albums = "Kid A\(rs)Moon Safari"
        let albumArtists = "Radiohead\(rs)"
        let statuses = "subscription\(rs)matched"
        let raw = [ids, names, artists, albums, albumArtists, statuses].joined(separator: fs) + "\n"
        XCTAssertEqual(parseLibrarySearchRows(raw), [])
    }

    func testEmptyPayloadIsNoRows() {
        XCTAssertEqual(parseLibrarySearchRows("\n"), [])
        XCTAssertEqual(parseLibrarySearchRows(""), [])
    }

    func testUnequalColumnCountsAreRejected() {
        let fs = String(asFieldSep)
        let rs = "\u{1E}"
        let ids = "P1\(rs)P2"
        let names = "N1\(rs)N2\(rs)N3"
        let artists = "A1\(rs)A2"
        let albums = "Al1\(rs)Al2"
        let albumArtists = "AA1\(rs)AA2"
        let raw = [ids, names, artists, albums, albumArtists].joined(separator: fs) + "\n"
        XCTAssertEqual(parseLibrarySearchRows(raw), [])
    }

    // MARK: - groupLibrarySearch

    private let groupingRows = [
        LibrarySearchRow(persistentID: "P1", name: "Idioteque", artist: "Radiohead", album: "Kid A", albumArtist: "Radiohead"),
        LibrarySearchRow(persistentID: "P2", name: "Kid A", artist: "Radiohead", album: "Kid A", albumArtist: ""),
        LibrarySearchRow(persistentID: "P3", name: "Sexy Boy", artist: "Air", album: "", albumArtist: "")
    ]
    private let groupingPlaylistNames = ["House", "__queue__ x", "Deep House", "Jazz"]

    func testSongsKeepLibraryOrderAndPersistentIDs() {
        let results = groupLibrarySearch(rows: groupingRows, playlistNames: groupingPlaylistNames, term: "",
                                          types: [.songs], limit: 10)
        XCTAssertEqual(results.songs.map { $0.id }, ["P1", "P2", "P3"])
        XCTAssertTrue(results.albums.isEmpty)
        XCTAssertTrue(results.artists.isEmpty)
        XCTAssertTrue(results.playlists.isEmpty)
    }

    func testLimitCapsEachType() {
        let results = groupLibrarySearch(rows: groupingRows, playlistNames: groupingPlaylistNames, term: "",
                                          types: [.songs, .artists], limit: 1)
        XCTAssertEqual(results.songs.map { $0.id }, ["P1"])
        XCTAssertEqual(results.artists.map { $0.name }, ["Radiohead"])
    }

    func testAlbumsAreDistinctAndShareTheLibraryTabID() {
        let results = groupLibrarySearch(rows: groupingRows, playlistNames: groupingPlaylistNames, term: "",
                                          types: [.albums], limit: 10)
        XCTAssertEqual(results.albums.count, 1)
        let album = results.albums[0]
        XCTAssertEqual(album.name, "Kid A")
        XCTAssertEqual(album.artist, "Radiohead")
        let expectedKey = libraryAlbumKey(album: "Kid A", albumArtist: "Radiohead", artist: "Radiohead")
        XCTAssertEqual(album.id, libraryAlbumID(forKey: expectedKey))
        XCTAssertNil(album.artworkURL)
    }

    func testArtistsUseCreditAndDedupe() {
        let results = groupLibrarySearch(rows: groupingRows, playlistNames: groupingPlaylistNames, term: "",
                                          types: [.artists], limit: 10)
        XCTAssertEqual(results.artists.map { $0.name }, ["Radiohead", "Air"])
        XCTAssertEqual(results.artists.map { $0.id }, results.artists.map { $0.name })
    }

    func testPlaylistsFilterByTermCaseInsensitiveAndDropTemp() {
        let results = groupLibrarySearch(rows: groupingRows, playlistNames: groupingPlaylistNames, term: "house",
                                          types: [.playlists], limit: 10)
        XCTAssertEqual(results.playlists.map { $0.name }, ["House", "Deep House"])
        XCTAssertTrue(results.playlists.allSatisfy { $0.curator == "" })
        XCTAssertEqual(results.playlists.map { $0.id }, results.playlists.map { $0.name })
    }

    func testEmptyTermMatchesNoPlaylists() {
        let results = groupLibrarySearch(rows: groupingRows, playlistNames: groupingPlaylistNames, term: "",
                                          types: [.playlists], limit: 10)
        XCTAssertTrue(results.playlists.isEmpty)
    }

    func testOnlyRequestedTypesArePopulated() {
        let results = groupLibrarySearch(rows: groupingRows, playlistNames: groupingPlaylistNames, term: "",
                                          types: [.albums], limit: 10)
        XCTAssertTrue(results.songs.isEmpty)
    }

    // This test passes immediately against step 3's groupLibrarySearch; it
    // is written now (rather than waiting for a red state) because it
    // documents a contract, not a behavior change: library song ids are
    // Music's persistent ids ("P1" here from the fixture), never a catalog
    // id. That is what lets `music play N` resolve a cached library result
    // by title and artist via playLocalSong (PlaybackCommands.swift line
    // 267) instead of dereferencing catalogId, which a library search never
    // has a real value for.
    func testLibrarySongIDsAreMusicPersistentIDsNotCatalogIDs() {
        let results = groupLibrarySearch(rows: groupingRows, playlistNames: groupingPlaylistNames, term: "",
                                          types: [.songs], limit: 10)
        XCTAssertTrue(results.songs.allSatisfy { $0.id.hasPrefix("P") })
        XCTAssertEqual(results.songs.first?.id, "P1")
    }
}
