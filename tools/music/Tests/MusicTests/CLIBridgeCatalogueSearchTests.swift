// tools/music/Tests/MusicTests/CLIBridgeCatalogueSearchTests.swift
//
// Slice 3 Part 2, P6: `music search` (catalogue) executed through its real
// command path, `runSearch(…, library: false, env:, musicApp:)`. With Bridge
// selected it sends one `slice.search`, PUBLISHES `.bridgeCatalog` rows for the
// songs Bridge typed as songs (albums are never cached), and only then prints
// (D3, D6). Temp store, lock and cache on a scripted wire; the external-call
// tripwire armed throughout; nothing sleeps.
import ArgumentParser
import XCTest
@testable import music

/// `slice.search` replies a scripted Bridge sends (D5's `records` shape).
enum CLIBridgeCatalogueReplies {
    static func search(_ records: [(kind: String, id: String, title: String, subtitle: String, album: String?)]) -> String {
        let rows = records.map { r -> String in
            let album = r.album.map { ",\"album\":\"\($0)\"" } ?? ""
            return "{\"kind\":\"\(r.kind)\",\"id\":\"\(r.id)\",\"title\":\"\(r.title)\",\"subtitle\":\"\(r.subtitle)\"\(album)}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.search\",\"records\":[\(rows)]}"
    }

    /// Two songs and an album, the album between them, as Bridge may order them.
    static let mixed = search([
        ("song", "1440857781", "Angel", "Massive Attack", "Mezzanine"),
        ("album", "1440857000", "Mezzanine", "Massive Attack", nil),
        ("song", "1440857999", "Teardrop", "Massive Attack", nil),
    ])
}

final class CLIBridgeCatalogueSearchTests: XCTestCase {

    private typealias H = CLIBridgeCommandHarness
    private typealias C = CLIBridgeCatalogueReplies

    private let ready = CLIBridgeReplies.status()

    @discardableResult
    private func search(_ h: H, _ query: [String], artist: String? = nil, album: String? = nil,
                        types: String = "songs", limit: Int = 10, json: Bool = false,
                        musicApp: (() -> Void)? = nil) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let calls = withTripwire {
            do {
                try runSearch(query: query, artist: artist, album: album, types: types, library: false,
                              limit: limit, json: json, env: h.env,
                              musicApp: { _, _, _, _, _, _, _ in
                                  if let musicApp { musicApp() } else { XCTFail("Music.app ran") }
                              })
            } catch {
                thrown = error
            }
        }.calls
        return (thrown, calls)
    }

    // MARK: - The request

    func testBridgeSendsExactlyOneSearchWithTheShippedTermAndLimit() throws {
        let h = H(.source, ["slice.status": [ready], "slice.search": [C.mixed]])
        let (error, calls) = search(h, ["angel"], artist: "massive", album: "mezzanine", types: "songs,albums")
        XCTAssertNil(error)
        XCTAssertEqual(calls, [], "no REST, no AppleScript")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.search"])
        let body = try XCTUnwrap(h.seen.bodies("slice.search").first)
        XCTAssertEqual(body["term"] as? String, "angel massive mezzanine")
        XCTAssertEqual(body["limit"] as? Int, 10)
        XCTAssertEqual(Set(body.keys), ["op", "term", "limit"])
        XCTAssertEqual(h.seen.locked("slice.search"), [false], "a read takes no lock")
    }

    func testTheLimitIsPassedThrough() throws {
        let h = H(.source, ["slice.status": [ready], "slice.search": [C.mixed]])
        XCTAssertNil(search(h, ["angel"], limit: 3).error)
        XCTAssertEqual(h.seen.bodies("slice.search").first?["limit"] as? Int, 3)
    }

    // MARK: - Publish, then print

    func testSongsArePublishedAsBridgeCatalogueRowsBeforeTheFirstPrint() throws {
        var cachedAtFirstPrint: [SongResult]?
        var cacheForPrint: ResultCache?
        let h = H(.source, ["slice.status": [ready], "slice.search": [C.mixed]], out: { _ in
            if cachedAtFirstPrint == nil { cachedAtFirstPrint = (try? cacheForPrint?.readSongs()) ?? [] }
        })
        cacheForPrint = h.cache
        let (error, calls) = search(h, ["massive"], types: "songs,albums")
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        let expected = [
            SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine", catalogId: "",
                       origin: .bridgeCatalog, bridgeID: "1440857781"),
            SongResult(index: 2, title: "Teardrop", artist: "Massive Attack", album: "", catalogId: "",
                       origin: .bridgeCatalog, bridgeID: "1440857999"),
        ]
        XCTAssertEqual(try h.cache.readSongs(), expected, "songs only; the album is never cached")
        XCTAssertEqual(cachedAtFirstPrint, expected, "published before the first line was printed")
        XCTAssertEqual(h.io.out, catalogueSearchLines(try SourceAppControl(path: "/nonexistent", transport: { _, _ in C.mixed })
                                                        .searchCatalogue(term: "x", limit: 10)))
        XCTAssertEqual(h.io.out.first, "1. Angel \u{2014} Massive Attack [Mezzanine] (id: 1440857781)")
    }

    func testTheDefaultSongsTypeShowsSongsOnlyAndStillCachesNoAlbum() throws {
        let h = H(.source, ["slice.status": [ready], "slice.search": [C.mixed]])
        XCTAssertNil(search(h, ["massive"]).error)
        XCTAssertEqual(h.io.out, ["1. Angel \u{2014} Massive Attack [Mezzanine] (id: 1440857781)",
                                  "2. Teardrop \u{2014} Massive Attack (id: 1440857999)"])
        XCTAssertEqual(try h.cache.readSongs().map(\.bridgeID), ["1440857781", "1440857999"])
    }

    func testAlbumsOnlyPublishesAnEmptyListAndPrintsTheAlbums() throws {
        let h = H(.source, ["slice.status": [ready], "slice.search": [C.mixed]])
        try h.cache.writeSongs([.row(1, .bridgeCatalog, bridgeID: "older")])
        XCTAssertNil(search(h, ["massive"], types: "albums").error)
        XCTAssertEqual(try h.cache.readSongs(), [], "albums are never cached, and an older search's rows are gone")
        XCTAssertEqual(h.io.out, ["Albums:", "  Mezzanine \u{2014} Massive Attack (id: 1440857000)"])
    }

    func testJSONSongsOnlyIsABareArray() throws {
        let h = H(.source, ["slice.status": [ready], "slice.search": [C.mixed]])
        XCTAssertNil(search(h, ["massive"], json: true).error)
        XCTAssertEqual(h.io.out.count, 1)
        let rows = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(h.io.out[0].utf8))) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["1440857781", "1440857999"])
        XCTAssertEqual(rows[0]["album"] as? String, "Mezzanine")
        XCTAssertNil(rows[1]["album"], "absent, never \"\"")
    }

    func testAFailedPublicationPrintsNoRowsAndExitsOne() throws {
        for asJSON in [false, true] {
            let h = H(.source, ["slice.status": [ready], "slice.search": [C.mixed]])
            XCTAssertTrue(FileManager.default.createFile(atPath: h.cache.directory, contents: Data("x".utf8)))
            let (error, calls) = search(h, ["massive"], json: asJSON)
            XCTAssertEqual(error as? ExitCode, .failure)
            XCTAssertEqual(calls, [])
            XCTAssertEqual(h.io.out.count, 1)
            let line = asJSON ? (cliJSON(h.io.out.first)?["error"] as? String ?? "") : h.io.out[0]
            XCTAssertTrue(line.hasPrefix("Couldn't save these results, so music play N would not find them: "), line)
            XCTAssertFalse(h.io.out[0].contains("Angel"), "no numbered rows")
        }
    }

    func testNoResultsPublishesEmptyAndALaterPlayOneIsOutOfRange() throws {
        let h = H(.source, ["slice.status": [ready, ready], "slice.search": [C.search([])]])
        try h.cache.writeSongs([.row(1, .bridgeCatalog, bridgeID: "older-search")])
        let (error, _) = search(h, ["nothing", "matches"])
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["No results for 'nothing matches'"])
        XCTAssertEqual(try h.cache.readSongs(), [])

        var playError: Error?
        do {
            try runPlay(args: ["1"], playlist: nil, album: nil, song: nil, artist: nil, json: false, env: h.env,
                        musicAppDeps: PlayMusicAppDeps(readSongs: { [] }, resolveIndexed: { _, _ in XCTFail() }))
        } catch { playError = error }
        XCTAssertEqual(playError as? ExitCode, .failure)
        XCTAssertEqual(h.io.out.last, "Index 1 is out of range.")
        XCTAssertEqual(h.wire.sent("slice.queue").count, 0)
    }

    // MARK: - Refusals before any search

    func testUnsupportedTypesAndABlankTermRefuseWithNoSearch() throws {
        let cases: [(query: [String], types: String, expected: String)] = [
            (["massive"], "artists", "Bridge catalogue search returns songs and albums only in this version."),
            (["massive"], "songs,playlists", "Bridge catalogue search returns songs and albums only in this version."),
            ([], "songs", "Name something to search for."),
            (["  "], "songs", "Name something to search for."),
        ]
        for c in cases {
            let h = H(.source, ["slice.status": [ready]])
            try h.cache.writeSongs([.row(1, .catalog)])
            let (error, calls) = search(h, c.query, types: c.types)
            XCTAssertEqual(error as? ExitCode, .failure, c.types)
            XCTAssertEqual(h.io.out, [c.expected], c.types)
            XCTAssertEqual(h.seen.ops, ["slice.status"], "\(c.types): readiness only, no slice.search")
            XCTAssertEqual(try h.cache.readSongs(), [.row(1, .catalog)], "a refusal publishes nothing")
            XCTAssertEqual(calls, [])
        }
    }

    /// An older Bridge answers `unknown_op`: the per-op sentence, nothing cached.
    func testAnOlderBridgeSaysUpdateBridge() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.search": [#"{"ok":false,"error":{"kind":"unknown_op","detail":"slice.search"}}"#]])
        try h.cache.writeSongs([.row(1, .catalog)])
        let (error, calls) = search(h, ["massive"])
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["This Bridge build can't search the catalogue \u{2014} update Bridge"])
        XCTAssertEqual(try h.cache.readSongs(), [.row(1, .catalog)])
        XCTAssertEqual(calls, [])
    }

    // MARK: - Music.app

    /// Decision 7: with Music.app selected the catalogue search is the shipped
    /// body (injected here: the production body reads the real developer key),
    /// with no lock and no Bridge request.
    func testMusicAppModeRunsTheShippedBodyAndSendsNothingToBridge() {
        let h = H(.musicApp)
        var runs = 0
        var held: [Bool] = []
        let (error, calls) = search(h, ["massive"], musicApp: {
            runs += 1
            held.append(!OutputLockTestSupport.isFree(h.lockPath))
        })
        XCTAssertNil(error)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(held, [false])
        XCTAssertEqual(h.wire.requestCount, 0)
        XCTAssertEqual(calls, [])
    }

    /// The shipped writer is untouched: Music.app catalogue rows stay `.catalog`.
    func testTheShippedCatalogueWriterStillWritesCatalogRows() {
        let rows = searchCacheRows([CatalogSong(id: "1440", title: "Angel", artist: "Massive Attack", album: "Mezzanine")],
                                   origin: .catalog)
        XCTAssertEqual(rows, [SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine",
                                         catalogId: "1440", origin: .catalog)])
    }
}
