// tools/music/Tests/MusicTests/SearchTests.swift
import XCTest
@testable import music

final class SearchTests: XCTestCase {
    // MARK: - parseSearchTypes

    func testParseTypesBasic() {
        XCTAssertEqual(parseSearchTypes("songs,albums"), [.songs, .albums])
    }

    func testParseTypesDefaultsToSongs() {
        XCTAssertEqual(parseSearchTypes(""), [.songs])
        XCTAssertEqual(parseSearchTypes("bogus,nonsense"), [.songs])
    }

    func testParseTypesDedupesPreservingOrder() {
        XCTAssertEqual(parseSearchTypes("albums, songs, albums"), [.albums, .songs])
    }

    func testParseTypesTolerantOfSpacesAndCase() {
        XCTAssertEqual(parseSearchTypes("Songs ARTISTS"), [.songs, .artists])
    }

    // MARK: - searchPath

    func testCatalogSearchPath() {
        let p = searchPath(storefront: "us", term: "gypsy woman", types: [.songs, .albums], limit: 10, library: false)
        XCTAssertEqual(p, "/v1/catalog/us/search?term=gypsy%20woman&types=songs,albums&limit=10")
    }

    func testLibrarySearchPathUsesLibraryEndpointAndTypeNames() {
        let p = searchPath(storefront: "us", term: "kid a", types: [.songs, .playlists], limit: 5, library: true)
        XCTAssertEqual(p, "/v1/me/library/search?term=kid%20a&types=library-songs,library-playlists&limit=5")
    }

    func testSearchPathEncodesReservedChars() {
        let p = searchPath(storefront: "gb", term: "Simon & Garfunkel", types: [.songs], limit: 3, library: false)
        XCTAssertFalse(p.contains(" "))
        // The literal & must be percent-encoded so it is not read as a query separator.
        XCTAssertTrue(p.contains("Simon%20%26%20Garfunkel"), p)
        XCTAssertTrue(p.contains("&types=songs&limit=3"), p)
    }

    // MARK: - parseSearchResults

    func testParsesAllCatalogTypes() {
        let r = parseSearchResults(from: Data(Self.catalog.utf8),
                                   types: [.songs, .albums, .artists, .playlists], library: false)
        XCTAssertEqual(r.songs.map(\.title), ["Song A"])
        XCTAssertEqual(r.songs.first?.artist, "Artist A")
        XCTAssertEqual(r.albums.map(\.name), ["Album B"])
        XCTAssertEqual(r.albums.first?.artist, "Artist B")
        XCTAssertEqual(r.artists.map(\.name), ["Artist C"])
        XCTAssertEqual(r.playlists.first?.name, "Playlist D")
        XCTAssertEqual(r.playlists.first?.curator, "Curator D")
        XCTAssertFalse(r.isEmpty)
    }

    func testParsesOnlyRequestedTypes() {
        // Only songs requested → albums/artists ignored even though present.
        let r = parseSearchResults(from: Data(Self.catalog.utf8), types: [.songs], library: false)
        XCTAssertEqual(r.songs.count, 1)
        XCTAssertTrue(r.albums.isEmpty)
        XCTAssertTrue(r.artists.isEmpty)
    }

    func testParsesLibraryKeys() {
        let r = parseSearchResults(from: Data(Self.library.utf8), types: [.songs], library: true)
        XCTAssertEqual(r.songs.first?.title, "Lib Song")
        XCTAssertEqual(r.songs.first?.album, "Lib Album")
    }

    func testParseEmptyAndGarbageYieldEmpty() {
        XCTAssertTrue(parseSearchResults(from: Data("{}".utf8), types: [.songs], library: false).isEmpty)
        XCTAssertTrue(parseSearchResults(from: Data("not json".utf8), types: [.songs], library: false).isEmpty)
    }

    // Catalog response shape is the verified one the shipped song search uses
    // (results.<type>.data[].attributes); library keys are the `library-` variant.
    static let catalog = """
    { "results": {
      "songs":     { "data": [ { "id": "s1",  "attributes": { "name": "Song A", "artistName": "Artist A", "albumName": "Album A" } } ] },
      "albums":    { "data": [ { "id": "a1",  "attributes": { "name": "Album B", "artistName": "Artist B" } } ] },
      "artists":   { "data": [ { "id": "ar1", "attributes": { "name": "Artist C" } } ] },
      "playlists": { "data": [ { "id": "p1",  "attributes": { "name": "Playlist D", "curatorName": "Curator D" } } ] }
    } }
    """

    static let library = """
    { "results": {
      "library-songs": { "data": [ { "id": "l1", "attributes": { "name": "Lib Song", "artistName": "Lib Artist", "albumName": "Lib Album" } } ] }
    } }
    """
}
