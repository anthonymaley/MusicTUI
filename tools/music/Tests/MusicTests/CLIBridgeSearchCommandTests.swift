// tools/music/Tests/MusicTests/CLIBridgeSearchCommandTests.swift
//
// Slice 3 score, S7: `music search --library` executed through its real
// command path, `runSearch(…, env:, musicApp:)`, in both modes. Bridge search
// publishes its rows (D3) BEFORE it prints a numbered result, and a failed
// publication shows no numbered rows. Temp store, lock and cache; the
// external-call tripwire armed throughout; nothing sleeps.
import ArgumentParser
import XCTest
@testable import music

final class CLIBridgeSearchCommandTests: XCTestCase {

    private typealias H = CLIBridgeCommandHarness
    private typealias R = CLIBridgeLibraryReplies

    private let ready = CLIBridgeReplies.status()
    private let library = R.songs([("s1", "Angel", "Massive Attack", "Mezzanine"),
                                   ("s2", "Teardrop", "Massive Attack", "Mezzanine"),
                                   ("s3", "Unfinished Sympathy", "Massive Attack", "Blue Lines"),
                                   ("s4", "Glory Box", "Portishead", "Dummy")])

    @discardableResult
    private func search(_ h: H, _ query: [String], artist: String? = nil, album: String? = nil,
                        types: String = "songs", library: Bool = true, limit: Int = 10, json: Bool = false,
                        musicApp: (() -> Void)? = nil) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        var calls: [ExternalCall] = []
        do {
            calls = try withTripwire {
                do {
                    if let musicApp {
                        try runSearch(query: query, artist: artist, album: album, types: types, library: library,
                                      limit: limit, json: json, env: h.env,
                                      musicApp: { _, _, _, _, _, _, _ in musicApp() })
                    } else {
                        try runSearch(query: query, artist: artist, album: album, types: types, library: library,
                                      limit: limit, json: json, env: h.env,
                                      musicApp: { _, _, _, _, _, _, _ in XCTFail("Music.app ran") })
                    }
                } catch {
                    thrown = error
                }
            }.calls
        } catch {
            XCTFail("withTripwire threw \(error)")
        }
        return (thrown, calls)
    }

    // MARK: - Bridge

    func testBridgeSearchPublishesBridgeRowsThenPrintsThemNumbered() throws {
        var cachedAtFirstPrint: [SongResult]?
        var cacheForPrint: ResultCache?
        let h = H(.source, ["slice.status": [ready], "slice.librarySongs": [library]], out: { _ in
            if cachedAtFirstPrint == nil { cachedAtFirstPrint = (try? cacheForPrint?.readSongs()) ?? [] }
        })
        cacheForPrint = h.cache
        let (error, calls) = search(h, ["massive"], album: "mezz")
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, ["1. Angel \u{2014} Massive Attack [Mezzanine]",
                                  "2. Teardrop \u{2014} Massive Attack [Mezzanine]"])
        let expected = [
            SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine", catalogId: "",
                       origin: .bridgeLibrary, bridgeID: "s1"),
            SongResult(index: 2, title: "Teardrop", artist: "Massive Attack", album: "Mezzanine", catalogId: "",
                       origin: .bridgeLibrary, bridgeID: "s2"),
        ]
        XCTAssertEqual(try h.cache.readSongs(), expected)
        XCTAssertEqual(cachedAtFirstPrint, expected, "published before the first numbered row was printed")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.librarySongs"])
        XCTAssertEqual(h.seen.locked("slice.librarySongs"), [false], "a read takes no lock")
    }

    func testBridgeSearchJSONIsABareArrayWithNoCatalogueId() throws {
        let h = H(.source, ["slice.status": [ready], "slice.librarySongs": [library]])
        XCTAssertNil(search(h, ["Portishead"], json: true).error)
        XCTAssertEqual(h.io.out.count, 1)
        let rows = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(h.io.out[0].utf8))) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(Set(rows[0].keys), ["bridge_id", "title", "artist", "album"])
        XCTAssertEqual(rows[0]["bridge_id"] as? String, "s4")
        XCTAssertEqual(rows[0]["title"] as? String, "Glory Box")
        XCTAssertEqual(rows[0]["album"] as? String, "Dummy")
    }

    func testBridgeSearchHonoursTheLimit() throws {
        let h = H(.source, ["slice.status": [ready], "slice.librarySongs": [library]])
        XCTAssertNil(search(h, ["a"], limit: 2).error)
        XCTAssertEqual(h.io.out.count, 2)
        XCTAssertEqual(try h.cache.readSongs().count, 2)
    }

    func testBridgeSearchThenBridgePlayTwoQueuesRowTwosId() throws {
        let h = H(.source, [
            "slice.status": [ready, ready, CLIBridgeLibraryReplies.status("playing", title: "Teardrop")],
            "slice.librarySongs": [library],
            "slice.queue": [R.queued()],
        ])
        XCTAssertNil(search(h, ["Massive"]).error)
        var error: Error?
        let calls = try withTripwire {
            do {
                try runPlay(args: ["2"], playlist: nil, album: nil, song: nil, artist: nil, json: false, env: h.env,
                            musicAppDeps: PlayMusicAppDeps(readSongs: { XCTFail(); return [] },
                                                           resolveIndexed: { _, _ in XCTFail() }))
            } catch let e { error = e }
        }.calls
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["library_ids"] as? [String], ["s2"])
        XCTAssertEqual(queue["start_required"] as? Bool, true)
    }

    func testAFailedPublicationPrintsNoNumberedRows() throws {
        for asJSON in [false, true] {
            let h = H(.source, ["slice.status": [ready], "slice.librarySongs": [library]])
            // The cache directory is a FILE: the atomic write cannot land.
            XCTAssertTrue(FileManager.default.createFile(atPath: h.cache.directory, contents: Data("x".utf8)))
            let (error, calls) = search(h, ["Massive"], json: asJSON)
            XCTAssertEqual(error as? ExitCode, .failure)
            XCTAssertEqual(calls, [])
            XCTAssertEqual(h.io.out.count, 1)
            let line = asJSON ? (cliJSON(h.io.out.first)?["error"] as? String ?? "") : h.io.out[0]
            XCTAssertTrue(line.hasPrefix("Couldn't save these results, so music play N would not find them: "), line)
            XCTAssertFalse(h.io.out[0].contains("Angel"), "no numbered rows")
        }
    }

    func testNoResultsPublishesAnEmptyListSoALaterPlayOneIsOutOfRange() throws {
        let h = H(.source, [
            "slice.status": [ready, ready],
            "slice.librarySongs": [library],
        ])
        try h.cache.writeSongs([.row(1, .bridgeLibrary, bridgeID: "older-search")])
        let (error, _) = search(h, ["Nothing Matches This"])
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["No results for 'Nothing Matches This'"])
        XCTAssertEqual(try h.cache.readSongs(), [], "an older search's rows are gone")

        var playError: Error?
        do {
            try runPlay(args: ["1"], playlist: nil, album: nil, song: nil, artist: nil, json: false, env: h.env,
                        musicAppDeps: PlayMusicAppDeps(readSongs: { [] }, resolveIndexed: { _, _ in XCTFail() }))
        } catch { playError = error }
        XCTAssertEqual(playError as? ExitCode, .failure)
        XCTAssertEqual(h.io.out.last, "Index 1 is out of range.")
        XCTAssertEqual(h.wire.sent("slice.queue").count, 0)
    }

    func testNonSongTypesAndABlankSearchRefuseAfterReadiness() throws {
        let cases: [(query: [String], types: String, expected: String)] = [
            (["Massive"], "albums", "Bridge library search returns songs only in this version."),
            (["Massive"], "songs,artists", "Bridge library search returns songs only in this version."),
            ([], "songs", "Name something to search for."),
        ]
        for c in cases {
            let h = H(.source, ["slice.status": [ready]])
            try h.cache.writeSongs([.row(1, .catalog)])
            let (error, calls) = search(h, c.query, types: c.types)
            XCTAssertEqual(error as? ExitCode, .failure, c.types)
            XCTAssertEqual(h.io.out, [c.expected], c.types)
            XCTAssertEqual(h.seen.ops, ["slice.status"], "\(c.types): readiness only")
            XCTAssertEqual(try h.cache.readSongs(), [.row(1, .catalog)], "a refusal publishes nothing")
            XCTAssertEqual(calls, [])
        }
    }

    // MARK: - Music.app, and the catalogue branch

    func testMusicAppModeRunsTheShippedBodyWithNoLockAndNoBridge() {
        let h = H(.musicApp)
        var runs = 0
        var held: [Bool] = []
        let (error, calls) = search(h, ["Massive"], musicApp: {
            runs += 1
            held.append(!OutputLockTestSupport.isFree(h.lockPath))
        })
        XCTAssertNil(error)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(held, [false], "a read takes no lock")
        XCTAssertEqual(h.wire.requestCount, 0)
        XCTAssertEqual(calls, [])
    }

    /// The production Music.app body's first external effect is the shipped
    /// AppleScript library search.
    func testMusicAppModeProductionBodyIsTheShippedLibrarySearch() {
        let h = H(.musicApp)
        var calls: [ExternalCall] = []
        let printed = captureStdout {
            var thrown: Error?
            calls = try withTripwire {
                do {
                    try runSearch(query: ["Massive"], artist: nil, album: nil, types: "songs", library: true,
                                  limit: 10, json: false, env: h.env)
                } catch { thrown = error }
            }.calls
            if let thrown { throw thrown }
        }
        XCTAssertNotNil(printed.error)
        XCTAssertEqual(calls.count, 1)
        guard case .appleScript? = calls.first else { return XCTFail("\(calls)") }
        XCTAssertEqual(h.wire.requestCount, 0)
    }

    /// The catalogue search keeps its shipped backend on Bridge until S8 (Q2).
    func testCatalogueSearchOnBridgeStillRunsItsShippedBody() {
        let h = H(.source)
        var runs = 0
        XCTAssertNil(search(h, ["Massive"], library: false, musicApp: { runs += 1 }).error)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(h.wire.requestCount, 0)
    }
}
