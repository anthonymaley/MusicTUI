// tools/music/Tests/MusicTests/LibraryIndexTests.swift
import XCTest
@testable import music

final class LibraryIndexTests: XCTestCase {

    // MARK: bulk read script

    func testBulkReadScriptBindsLibraryAndGetsSixColumnsWithoutALoop() {
        let s = libraryBulkReadScript()
        XCTAssertTrue(s.contains("set lib to playlist \"Library\""))
        XCTAssertTrue(s.contains("set fs to (ASCII character 31)"))
        XCTAssertTrue(s.contains("set rs to (ASCII character 30)"))
        XCTAssertTrue(s.contains("set AppleScript's text item delimiters to rs"))
        XCTAssertTrue(s.contains("set AppleScript's text item delimiters to astid"))
        XCTAssertTrue(s.contains("(persistent ID of every track of lib) as text"))
        XCTAssertTrue(s.contains("(name of every track of lib) as text"))
        XCTAssertTrue(s.contains("(artist of every track of lib) as text"))
        XCTAssertTrue(s.contains("(album of every track of lib) as text"))
        XCTAssertTrue(s.contains("(album artist of every track of lib) as text"))
        XCTAssertTrue(s.contains("(cloud status of every track of lib) as text"))
        XCTAssertFalse(s.contains("repeat"))
        XCTAssertFalse(s.contains("whose"))
    }

    // MARK: parseLibraryTrackRows

    func testParsesSixColumnsIntoRowsByPosition() {
        let fs = String(asFieldSep)
        let rs = "\u{1E}"
        let ids = "P1\(rs)P2"
        let names = "Idioteque\(rs)Sexy Boy"
        let artists = "Radiohead\(rs)Air"
        let albums = "Kid A\(rs)Moon Safari"
        let albumArtists = "Radiohead\(rs)"
        let statuses = "subscription\(rs)matched"
        let raw = [ids, names, artists, albums, albumArtists, statuses].joined(separator: fs) + "\n"
        let rows = parseLibraryTrackRows(raw)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], LibraryTrackRow(persistentID: "P1", name: "Idioteque", artist: "Radiohead",
                                                album: "Kid A", albumArtist: "Radiohead", cloudStatus: "subscription"))
        XCTAssertEqual(rows[1].albumArtist, "")
        XCTAssertEqual(rows[1].cloudStatus, "matched")
    }

    func testParserKeepsEmptyFieldsInPosition() {
        let fs = String(asFieldSep)
        let rs = "\u{1E}"
        let ids = "P1\(rs)P2"
        let names = "Idioteque\(rs)Sexy Boy"
        let artists = "Radiohead\(rs)Air"
        let albums = "\(rs)Moon Safari"
        let albumArtists = "Radiohead\(rs)"
        let statuses = "subscription\(rs)matched"
        let raw = [ids, names, artists, albums, albumArtists, statuses].joined(separator: fs) + "\n"
        let rows = parseLibraryTrackRows(raw)
        XCTAssertEqual(rows[0].album, "")
        XCTAssertEqual(rows[1].album, "Moon Safari")
    }

    func testParserRejectsColumnCountMismatch() {
        let fs = String(asFieldSep)
        let rs = "\u{1E}"
        let fiveColumns = ["a\(rs)b", "c\(rs)d", "e\(rs)f", "g\(rs)h", "i\(rs)j"].joined(separator: fs)
        XCTAssertEqual(parseLibraryTrackRows(fiveColumns), [])

        let mismatched = ["a\(rs)b", "c\(rs)d\(rs)e", "f\(rs)g", "h\(rs)i", "j\(rs)k", "l\(rs)m"].joined(separator: fs)
        XCTAssertEqual(parseLibraryTrackRows(mismatched), [])
    }

    func testParserEmptyAndGarbage() {
        XCTAssertEqual(parseLibraryTrackRows(""), [])
        XCTAssertEqual(parseLibraryTrackRows("nope"), [])
    }

    func testParserSingleRowLibrary() {
        let fs = String(asFieldSep)
        let raw = ["P1", "Idioteque", "Radiohead", "Kid A", "Radiohead", "subscription"].joined(separator: fs)
        let rows = parseLibraryTrackRows(raw)
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: grouping fixtures

    private func row(_ id: String, _ name: String, _ artist: String, _ album: String,
                     albumArtist: String = "", status: String = "subscription") -> LibraryTrackRow {
        LibraryTrackRow(persistentID: id, name: name, artist: artist, album: album,
                        albumArtist: albumArtist, cloudStatus: status)
    }

    private var r1: LibraryTrackRow {
        row("P1", "Everything In Its Right Place", "Radiohead", "Kid A", albumArtist: "Radiohead")
    }
    private var r2: LibraryTrackRow {
        row("P2", "Kid A", "Radiohead", "Kid A", albumArtist: "Radiohead")
    }
    // empty album artist: credit falls back to artist
    private var r3: LibraryTrackRow {
        row("P3", "Sexy Boy", "Air", "Moon Safari")
    }
    private var r4: LibraryTrackRow {
        row("P4", "La Femme d'Argent", "Air", "Moon Safari")
    }
    // same album name, different credit
    private var r5: LibraryTrackRow {
        row("P5", "Kid A", "Someone Else", "Kid A", albumArtist: "Someone Else")
    }
    // empty album: a song, not an album
    private var r6: LibraryTrackRow {
        row("P6", "Loose Track", "Loose Artist", "")
    }
    // empty everything
    private var r7: LibraryTrackRow {
        row("P7", "Untitled", "", "")
    }

    // MARK: grouping

    func testAlbumKeyUsesAlbumArtistAndFallsBackToArtist() {
        XCTAssertEqual(libraryAlbumKey(album: "Kid A", albumArtist: "Radiohead", artist: "Thom Yorke"), "Kid A\u{0}Radiohead")
        XCTAssertEqual(libraryAlbumKey(album: "Moon Safari", albumArtist: "", artist: "Air"), "Moon Safari\u{0}Air")
    }

    func testAlbumIDIsStableHexOfTheKey() {
        // FNV-1a 64-bit reference vector for "a"; from reference tables, so if it
        // fails compare against a second independent FNV-1a 64 implementation
        // before changing the test.
        XCTAssertEqual(libraryAlbumID(forKey: "a"), "lib.af63dc4c8601ec8c")
        XCTAssertEqual(libraryAlbumID(forKey: "Kid A\u{0}Radiohead"), libraryAlbumID(forKey: "Kid A\u{0}Radiohead"))
        XCTAssertNotEqual(libraryAlbumID(forKey: "Kid A\u{0}Radiohead"), libraryAlbumID(forKey: "Kid A\u{0}Someone Else"))
    }

    func testGroupsAlbumsByAlbumAndCreditWithTrackCounts() {
        let albums = groupLibraryAlbums([r1, r2, r3, r4, r5, r6, r7])
        XCTAssertEqual(albums.map(\.name), ["Kid A", "Kid A", "Moon Safari"])
        let kidAs = albums.filter { $0.name == "Kid A" }
        XCTAssertEqual(kidAs.map(\.artist), ["Radiohead", "Someone Else"])
        XCTAssertEqual(kidAs.map(\.trackCount), [2, 1])
        let moonSafari = albums.first { $0.name == "Moon Safari" }
        XCTAssertEqual(moonSafari?.artist, "Air")
        XCTAssertEqual(moonSafari?.trackCount, 2)
        for album in albums {
            XCTAssertEqual(album.id, libraryAlbumID(forKey: libraryAlbumKey(album: album.name, albumArtist: album.artist, artist: album.artist)))
            XCTAssertNil(album.artworkURL)
        }
    }

    func testAlbumOrderIsCaseInsensitiveByName() {
        let lower = row("P8", "Come Together", "The Beatles", "abbey road", albumArtist: "The Beatles")
        let upper = row("P9", "Blue Motel Room", "Joni Mitchell", "Blue", albumArtist: "Joni Mitchell")
        let albums = groupLibraryAlbums([lower, upper])
        XCTAssertEqual(albums.map(\.name), ["abbey road", "Blue"])
    }

    func testSongsAreOneRowEachKeyedByPersistentID() {
        let songs = groupLibrarySongs([r3, r1, r6])
        XCTAssertEqual(songs.map(\.id), ["P1", "P6", "P3"])
        XCTAssertEqual(songs[0].album, "Kid A")
        XCTAssertEqual(songs[1].album, "")
    }

    func testArtistsAreDistinctCreditsSortedAndEmptyDropped() {
        let artists = groupLibraryArtists([r1, r2, r3, r4, r5, r6, r7])
        XCTAssertEqual(artists.map(\.name), ["Air", "Loose Artist", "Radiohead", "Someone Else"])
        XCTAssertEqual(artists.map(\.id), artists.map(\.name))
    }

    func testArtistAlbumsFilterByCreditThenGroup() {
        let radiohead = groupLibraryArtistAlbums([r1, r2, r3, r4, r5], artistID: "Radiohead")
        XCTAssertEqual(radiohead.map(\.name), ["Kid A"])
        XCTAssertEqual(radiohead.first?.trackCount, 2)

        let air = groupLibraryArtistAlbums([r1, r2, r3, r4, r5], artistID: "Air")
        XCTAssertEqual(air.first?.name, "Moon Safari")

        XCTAssertTrue(groupLibraryArtistAlbums([r1], artistID: "Nobody").isEmpty)
    }

    func testIndexCacheLoadsOnceAndSharesRows() {
        let cache = LibraryIndexCache()
        var loads = 0
        let fixture = r1

        let first = cache.rows { loads += 1; return .success([fixture]) }
        let second = cache.rows { loads += 1; return .success([fixture]) }

        let loaded = expectation(description: "background load")
        var third: [LibraryTrackRow]? = []
        DispatchQueue.global().async {
            third = cache.rows { loads += 1; return .success([fixture]) }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(first, [fixture])
        XCTAssertEqual(second, [fixture])
        XCTAssertEqual(third, [fixture])
        XCTAssertEqual(loads, 1)
    }

    func testIndexCacheAlbumLookupByID() {
        let cache = LibraryIndexCache()
        _ = cache.rows { .success([self.r1, self.r2, self.r3]) }
        let id = libraryAlbumID(forKey: libraryAlbumKey(album: "Kid A", albumArtist: "Radiohead", artist: "Radiohead"))
        XCTAssertEqual(cache.albumRows(id: id)?.map(\.persistentID), ["P1", "P2"])
        XCTAssertNil(cache.albumRows(id: "lib.nope"))
    }

    // MARK: artwork ladder

    func testTrackArtworkScriptLooksUpByPersistentIDAndWritesThePath() {
        let s = libraryTrackArtworkScript(persistentID: "ABC\"123", path: "/tmp/x.dat")
        XCTAssertTrue(s.contains("whose persistent ID is \"ABC\\\"123\""))
        XCTAssertTrue(s.contains("artworks of item 1 of hits"))
        XCTAssertTrue(s.contains("raw data of item 1 of"))
        XCTAssertTrue(s.contains("open for access POSIX file"))
        XCTAssertTrue(s.contains("set eof of fileRef to 0"))
        XCTAssertTrue(s.contains("return \"OK\""))
        XCTAssertTrue(s.contains("return \"NONE\""))
        XCTAssertFalse(s.contains("current track"))
    }

    func testCoverTempPathIsPerAlbumAndStable() {
        XCTAssertEqual(libraryCoverTempPath(albumID: "lib.af63dc4c8601ec8c"), "/tmp/music-lib-art-lib.af63dc4c8601ec8c.dat")
        XCTAssertEqual(libraryCoverTempPath(albumID: "lib.af63dc4c8601ec8c"), libraryCoverTempPath(albumID: "lib.af63dc4c8601ec8c"))
    }

    func testEmbeddedCoverKeyIsDerivedFromTheAlbumID() {
        XCTAssertEqual(libraryEmbeddedCoverKey(albumID: "lib.af63dc4c8601ec8c"), "lib.af63dc4c8601ec8c.emb")
        XCTAssertEqual(ArtworkStore.cacheKey(libraryEmbeddedCoverKey(albumID: "lib.af63dc4c8601ec8c")), "lib_af63dc4c8601ec8c_emb")
    }

    func testCoverLadderPrefersEmbeddedThenRESTThenNil() {
        XCTAssertEqual(
            resolveLibraryCover(albumID: "lib.1", embeddedPath: "/tmp/a.dat", restHit: (id: "l.9", url: "https://x/{w}x{h}bb.jpg")),
            LibraryCover(key: "lib.1.emb", url: "file:///tmp/a.dat"))
        XCTAssertEqual(
            resolveLibraryCover(albumID: "lib.1", embeddedPath: nil, restHit: (id: "l.9", url: "https://x/{w}x{h}bb.jpg")),
            LibraryCover(key: "l.9", url: "https://x/300x300bb.jpg"))
        XCTAssertNil(resolveLibraryCover(albumID: "lib.1", embeddedPath: nil, restHit: nil))
    }
}
