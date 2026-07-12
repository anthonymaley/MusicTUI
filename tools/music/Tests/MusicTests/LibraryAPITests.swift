// tools/music/Tests/MusicTests/LibraryAPITests.swift
import XCTest
@testable import music

final class LibraryAPITests: XCTestCase {
    func testAlbumsPath() {
        XCTAssertEqual(libraryAlbumsPath(limit: 100, offset: 0),
                       "/v1/me/library/albums?limit=100&offset=0")
        XCTAssertEqual(libraryAlbumsPath(limit: 25, offset: 50),
                       "/v1/me/library/albums?limit=25&offset=50")
    }

    func testParsesLibraryAlbums() {
        let r = parseLibraryAlbums(from: Data(Self.albums.utf8))
        XCTAssertEqual(r.map(\.name), ["Kid A", "OK Computer"])
        XCTAssertEqual(r.first?.artist, "Radiohead")
        XCTAssertEqual(r.first?.id, "l.aaa")
    }

    func testParsesEmptyAndGarbage() {
        XCTAssertTrue(parseLibraryAlbums(from: Data("{}".utf8)).isEmpty)
        XCTAssertTrue(parseLibraryAlbums(from: Data("nope".utf8)).isEmpty)
    }

    func testParsesLibrarySongs() {
        let json = """
        { "data": [ { "id": "i.s1", "attributes": { "name": "Idioteque", "artistName": "Radiohead", "albumName": "Kid A" } } ] }
        """
        let r = parseLibrarySongs(from: Data(json.utf8))
        XCTAssertEqual(r.first?.title, "Idioteque")
        XCTAssertEqual(r.first?.artist, "Radiohead")
        XCTAssertEqual(r.first?.album, "Kid A")
    }

    func testSongsPath() {
        XCTAssertEqual(librarySongsPath(limit: 100, offset: 0), "/v1/me/library/songs?limit=100&offset=0")
    }

    func testParsesLibraryArtists() {
        let json = "{ \"data\": [ { \"id\": \"r.1\", \"attributes\": { \"name\": \"Radiohead\" } } ] }"
        XCTAssertEqual(parseLibraryArtists(from: Data(json.utf8)).first?.name, "Radiohead")
    }

    func testArtistsPath() {
        XCTAssertEqual(libraryArtistsPath(limit: 100, offset: 0), "/v1/me/library/artists?limit=100&offset=0")
    }

    func testArtistAlbumsPath() {
        XCTAssertEqual(artistAlbumsPath(artistID: "r.1"), "/v1/me/library/artists/r.1/albums?limit=100")
    }

    static let albums = """
    { "data": [
      { "id": "l.aaa", "attributes": { "name": "Kid A", "artistName": "Radiohead" } },
      { "id": "l.bbb", "attributes": { "name": "OK Computer", "artistName": "Radiohead" } }
    ] }
    """

    // MARK: - fetchAllPages (pagination walk)

    /// 250 items over a page size of 100 → three fetches (100, 100, 50); the short
    /// final page stops the walk. This is the artists-stuck-at-100 fix.
    func testFetchAllPagesWalksUntilShortPage() {
        let source = Array(0..<250)
        var offsets: [Int] = []
        let out: [Int] = fetchAllPages(pageSize: 100) { limit, offset in
            offsets.append(offset)
            let end = min(offset + limit, source.count)
            return offset >= source.count ? [] : Array(source[offset..<end])
        }
        XCTAssertEqual(out.count, 250)
        XCTAssertEqual(out, source)
        XCTAssertEqual(offsets, [0, 100, 200])   // stops after the 50-item page
    }

    /// A single short page is the whole result and costs exactly one fetch.
    func testFetchAllPagesSinglePage() {
        var calls = 0
        let out: [Int] = fetchAllPages(pageSize: 100) { _, _ in calls += 1; return Array(0..<30) }
        XCTAssertEqual(out.count, 30)
        XCTAssertEqual(calls, 1)
    }

    /// The cap is a safety valve against an endpoint that never returns a short
    /// page: with cap 250 and always-full pages, the walk stops once it has ≥ cap.
    func testFetchAllPagesHonorsCap() {
        var calls = 0
        let out: [Int] = fetchAllPages(pageSize: 100, cap: 250) { _, _ in calls += 1; return Array(0..<100) }
        XCTAssertEqual(calls, 3)                  // 0→100→200 (200<250), then 300 ≥ 250 stops
        XCTAssertEqual(out.count, 300)
    }

    // MARK: - fetchPagesStreaming (progressive-render page walk)

    /// Each page is handed to onPage as it lands, in order; the concatenation is the
    /// whole list and the page fetcher is asked for the same offsets as fetchAllPages.
    /// This is the incremental-render primitive: rows show after page 1, not the walk.
    func testFetchPagesStreamingDeliversPagesInOrder() {
        let source = Array(0..<250)
        var offsets: [Int] = []
        var pages: [[Int]] = []
        fetchPagesStreaming(pageSize: 100, page: { limit, offset in
            offsets.append(offset)
            let end = min(offset + limit, source.count)
            return offset >= source.count ? [] : Array(source[offset..<end])
        }, onPage: { batch in pages.append(batch); return true })
        XCTAssertEqual(offsets, [0, 100, 200])            // short 50-item page stops it
        XCTAssertEqual(pages.map(\.count), [100, 100, 50]) // delivered page-by-page
        XCTAssertEqual(pages.flatMap { $0 }, source)       // in order, whole list
    }

    /// Returning false from onPage aborts the walk immediately — no further pages are
    /// fetched. This is how the scene stops a walk when it has deallocated mid-load.
    func testFetchPagesStreamingAbortsWhenOnPageReturnsFalse() {
        var calls = 0
        var delivered = 0
        fetchPagesStreaming(pageSize: 100, page: { _, _ in calls += 1; return Array(0..<100) },
                            onPage: { _ in delivered += 1; return false })
        XCTAssertEqual(calls, 1)      // aborted after fetching page 1
        XCTAssertEqual(delivered, 1)  // onPage saw exactly one page
    }

    /// An empty source never calls onPage (nothing to render) and stops after one
    /// fetch — the caller flips "loaded" from the walk finishing, showing "(no …)".
    func testFetchPagesStreamingEmptySourceNeverDelivers() {
        var calls = 0
        var delivered = 0
        fetchPagesStreaming(pageSize: 100, page: { _, _ in calls += 1; return [] as [Int] },
                            onPage: { _ in delivered += 1; return true })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(delivered, 0)
    }

    // MARK: - parseLibraryTrackPositions (AppQueue source rows for album/artist play)

    func testParseLibraryTrackPositions() {
        let fs = String(asFieldSep)
        let raw = "26\(fs)La Femme D'Argent\(fs)Air\n28\(fs)Sexy Boy\(fs)Air\n29\(fs)All I Need\(fs)Air"
        let rows = parseLibraryTrackPositions(raw)
        XCTAssertEqual(rows.map(\.index), [26, 28, 29])   // Library positions preserved
        XCTAssertEqual(rows[1].name, "Sexy Boy")
        XCTAssertEqual(rows[2].artist, "Air")
        XCTAssertFalse(rows[0].isCurrent)
    }

    func testParseLibraryTrackPositionsSkipsMalformed() {
        let fs = String(asFieldSep)
        let raw = "bad\(fs)X\(fs)Y\n\n30\(fs)Kelly\(fs)Air"   // non-numeric index + blank line dropped
        XCTAssertEqual(parseLibraryTrackPositions(raw).map(\.index), [30])
    }
}
