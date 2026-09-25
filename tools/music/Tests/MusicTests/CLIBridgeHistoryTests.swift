// tools/music/Tests/MusicTests/CLIBridgeHistoryTests.swift
//
// Slice 3 Part 2, P9 [serve] (D9 passed for both ops, b2/b2-summary.md):
// `music recent` and `music rotation`, executed through their real command
// paths (`runRecent`, `runRotation`) in both modes. The Bridge wire is
// scripted and records each request with whether the output lock was held;
// the mode store, lock and cache are temp; the external-call tripwire is
// armed; nothing sleeps. No real Music.app, network, Bridge or ~/.config/music.
//
// Caching follows the controller's ruling on D6 for history: a `songs` item
// is a catalogue song whose own `id` is its catalogue id; a `library-songs`
// item is one only by its `catalog_id`; nothing else is cached as playable.
// The type is Bridge's, never inferred from an id's spelling.
import ArgumentParser
import XCTest
@testable import music

/// History replies a scripted Bridge sends (D5's `items` shape).
enum CLIBridgeHistoryReplies {
    static func items(op: String, _ items: [[String: Any]]) -> String {
        let doc: [String: Any] = ["ok": true, "op": op, "items": items]
        let data = try! JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// B2's measured shape for catalogue songs (`type: songs`, `catalog_id`
    /// null), mixed with every other kind the renderer must not number.
    static let recent = items(op: "slice.recentTracks", [
        ["type": "songs", "id": "1109715151", "name": "Lotus Flower", "artist": "Radiohead",
         "album": "The King of Limbs", "catalog_id": NSNull()],
        ["type": "library-songs", "id": "i.abc", "name": "Dreams", "artist": "Fleetwood Mac",
         "album": "Rumours", "catalog_id": "202272624"],
        ["type": "library-songs", "id": "i.lib", "name": "Home Demo", "artist": "Me"],
        ["type": "library-playlists", "id": "p.JLl8PsQBWKZO", "name": "House"],
        ["type": "albums", "id": "1440857000", "name": "Mezzanine", "artist": "Massive Attack"],
        ["type": "songs", "id": "742434939", "name": "Someone Great", "artist": "LCD Soundsystem"],
    ])

    /// B2's measured heavy rotation: one library playlist.
    static let rotation = items(op: "slice.heavyRotation", [
        ["type": "library-playlists", "id": "p.JLl8PsQBWKZO", "name": "House"],
    ])
}

final class CLIBridgeHistoryTests: XCTestCase {

    private typealias H = CLIBridgeCommandHarness
    private typealias Y = CLIBridgeHistoryReplies
    private typealias R = CLIBridgeLibraryReplies

    private let ready = CLIBridgeReplies.status()
    private let playing = CLIBridgeLibraryReplies.status("playing", title: "Dreams", artist: "Fleetwood Mac")

    private enum Op { case recent, rotation }

    private func run(_ op: Op, _ h: H, limit: Int = 10, json: Bool = false,
                     musicApp: (() -> Void)? = nil) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let body = { if let musicApp { musicApp() } else { XCTFail("Music.app ran") } }
        let calls = withTripwire {
            do {
                switch op {
                case .recent:   try runRecent(limit: limit, json: json, env: h.env, musicApp: body)
                case .rotation: try runRotation(limit: limit, json: json, env: h.env, musicApp: body)
                }
            } catch { thrown = error }
        }.calls
        return (thrown, calls)
    }

    // MARK: - recent, Bridge

    func testBridgeRecentPublishesCatalogueSongsByTypeThenPrints() throws {
        var cachedAtFirstPrint: [SongResult]?
        var cacheForPrint: ResultCache?
        let h = H(.source, ["slice.status": [ready], "slice.recentTracks": [Y.recent]],
                  out: { _ in if cachedAtFirstPrint == nil { cachedAtFirstPrint = (try? cacheForPrint?.readSongs()) ?? [] } })
        cacheForPrint = h.cache
        try h.cache.writeSongs([.row(1, .catalog), .row(2, .catalog)])

        let (error, calls) = run(.recent, h)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [], "no token read reaches REST, no AppleScript")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.recentTracks"])
        XCTAssertEqual(h.seen.bodies("slice.recentTracks").first?["limit"] as? Int, 10)
        XCTAssertEqual(h.seen.locked("slice.recentTracks"), [false], "a read takes no output lock")

        let published = try h.cache.readSongs()
        XCTAssertEqual(published, [
            SongResult(index: 1, title: "Lotus Flower", artist: "Radiohead", album: "The King of Limbs",
                       catalogId: "", origin: .bridgeCatalog, bridgeID: "1109715151"),
            SongResult(index: 2, title: "Dreams", artist: "Fleetwood Mac", album: "Rumours",
                       catalogId: "", origin: .bridgeCatalog, bridgeID: "202272624"),
            SongResult(index: 3, title: "Someone Great", artist: "LCD Soundsystem", album: "",
                       catalogId: "", origin: .bridgeCatalog, bridgeID: "742434939"),
        ])
        XCTAssertEqual(cachedAtFirstPrint, published, "published before the first line was printed")
        XCTAssertEqual(h.io.out, [
            "1. Lotus Flower — Radiohead [The King of Limbs]",
            "2. Dreams — Fleetwood Mac [Rumours]",
            "   Home Demo — Me (library)",
            "   House (playlist)",
            "   Mezzanine — Massive Attack (album)",
            "3. Someone Great — LCD Soundsystem",
        ])
    }

    /// The origin comes from Bridge's `type`, never from how an id is spelled:
    /// a numeric-looking library song with no `catalog_id` is not cached, a
    /// `songs` item is cached by its own id whatever it looks like, and a
    /// numeric music video is not a song.
    func testTheTypeDecidesNotTheIdsSpelling() throws {
        let reply = Y.items(op: "slice.recentTracks", [
            ["type": "library-songs", "id": "1109715151", "name": "Numeric Library", "artist": "A"],
            ["type": "songs", "id": "i.lookslibrary", "name": "Catalogue", "artist": "B"],
            ["type": "music-videos", "id": "1234567890", "name": "Video", "artist": "C"],
            ["type": "library-songs", "id": "i.x", "name": "Empty Catalog", "artist": "D", "catalog_id": ""],
        ])
        let h = H(.source, ["slice.status": [ready], "slice.recentTracks": [reply]])
        XCTAssertNil(run(.recent, h).error)
        XCTAssertEqual(try h.cache.readSongs().map(\.bridgeID), ["i.lookslibrary"])
        XCTAssertEqual(try h.cache.readSongs().map(\.origin), [.bridgeCatalog])
        XCTAssertEqual(h.io.out, [
            "   Numeric Library — A (library)",
            "1. Catalogue — B",
            "   Video — C (music-video)",
            "   Empty Catalog — D (library)",
        ])
    }

    func testLimitIsClampedToOneThroughTen() {
        for (asked, sent) in [(50, 10), (10, 10), (4, 4), (0, 1), (-3, 1)] {
            let h = H(.source, ["slice.status": [ready], "slice.recentTracks": [Y.items(op: "slice.recentTracks", [])]])
            XCTAssertNil(run(.recent, h, limit: asked).error)
            XCTAssertEqual(h.seen.bodies("slice.recentTracks").first?["limit"] as? Int, sent, "limit \(asked)")
        }
    }

    func testBridgeRecentJSONIsTheShippedItemsShape() throws {
        let h = H(.source, ["slice.status": [ready], "slice.recentTracks": [Y.recent]])
        XCTAssertNil(run(.recent, h, json: true).error)
        XCTAssertEqual(h.io.out.count, 1)
        let doc = try XCTUnwrap(cliJSON(h.io.out.first))
        let items = try XCTUnwrap(doc["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 6, "every item, in Bridge's order")
        XCTAssertEqual(items.map { $0["type"] as? String },
                       ["songs", "library-songs", "library-songs", "library-playlists", "albums", "songs"])
        XCTAssertEqual(Set(items[3].keys), ["type", "name", "artist", "album"], "as shipped")
        XCTAssertEqual(items[3]["artist"] as? String, "", "as shipped: present, empty")
        XCTAssertEqual(try h.cache.readSongs().count, 3, "JSON publishes the same rows")
    }

    func testEmptyHistoryPrintsTheShippedWordsAndPublishesAnEmptyList() throws {
        for asJSON in [false, true] {
            let h = H(.source, ["slice.status": [ready], "slice.recentTracks": [Y.items(op: "slice.recentTracks", [])]])
            try h.cache.writeSongs([.row(1, .catalog)])
            XCTAssertNil(run(.recent, h, json: asJSON).error)
            XCTAssertEqual(h.io.out, [asJSON ? "{\"recent\":[]}" : "No recent history."])
            XCTAssertEqual(try h.cache.readSongs(), [], "a later play 1 cannot reach an older listing's row")
        }
    }

    /// `play N` after `recent` queues the row's catalogue id as `ids`, never
    /// as a library id.
    func testPlayTwoAfterRecentQueuesRowTwosCatalogueID() throws {
        let h = H(.source, ["slice.status": [ready, ready, playing],
                            "slice.recentTracks": [Y.recent],
                            "slice.queue": [R.queued()]])
        XCTAssertNil(run(.recent, h).error)
        let (error, calls) = { () -> (Error?, [ExternalCall]) in
            var thrown: Error?
            let calls = withTripwire {
                do {
                    try runPlay(args: ["2"], playlist: nil, album: nil, song: nil, artist: nil, json: false, env: h.env,
                                musicAppDeps: PlayMusicAppDeps(readSongs: { XCTFail(); return [] },
                                                               resolveIndexed: { _, _ in XCTFail() }))
                } catch { thrown = error }
            }.calls
            return (thrown, calls)
        }()
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["ids"] as? [String], ["202272624"])
        XCTAssertNil(queue["library_ids"], "a history catalogue row never queues as a library id")
    }

    func testAFailedPublicationPrintsNoRowsAndExitsOne() throws {
        let h = H(.source, ["slice.status": [ready], "slice.recentTracks": [Y.recent]])
        XCTAssertTrue(FileManager.default.createFile(atPath: h.cache.directory, contents: Data("x".utf8)))
        let (error, _) = run(.recent, h)
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out.count, 1)
        XCTAssertTrue(h.io.out[0].hasPrefix("Couldn't save these results, so music play N would not find them: "), h.io.out[0])
    }

    func testBridgeRefusalPrintsBridgesWordsAndPublishesNothing() throws {
        let h = H(.source, ["slice.status": [ready], "slice.recentTracks": [CLIBridgeReplies.refused("history unavailable")]])
        try h.cache.writeSongs([.row(1, .catalog)])
        let (error, calls) = run(.recent, h)
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(calls, [])
        // D2: a new read's failure is `MusicProviderError` through `translate`,
        // printed as its `errorDescription`: Bridge's own detail.
        XCTAssertEqual(h.io.out, ["history unavailable"])
        XCTAssertEqual(try h.cache.readSongs(), [.row(1, .catalog)])
    }

    func testAnOlderBridgeSaysUpdateBridge() {
        let unknown = #"{"ok":false,"op":"slice.heavyRotation","error":{"kind":"unknown_op","detail":"no such op"}}"#
        let h = H(.source, ["slice.status": [ready], "slice.heavyRotation": [unknown]])
        let (error, _) = run(.rotation, h)
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["This Bridge build can't show heavy rotation — update Bridge"])
    }

    func testWarmingIsRetriedOnTheCommandsOneBudget() {
        let h = H(.source, ["slice.status": [ready],
                            "slice.recentTracks": [CLIBridgeReplies.warming(retryAfter: 2), Y.recent]])
        XCTAssertNil(run(.recent, h).error)
        XCTAssertEqual(h.wire.sent("slice.recentTracks").count, 2)
        XCTAssertEqual(h.io.err, [cliBridgeWarmingProgress])
        XCTAssertEqual(h.io.out.first, "1. Lotus Flower — Radiohead [The King of Limbs]")
    }

    // MARK: - rotation, Bridge

    func testBridgeRotationReadsHeavyRotationAndPublishesNoPlaylistRow() throws {
        let h = H(.source, ["slice.status": [ready], "slice.heavyRotation": [Y.rotation]])
        try h.cache.writeSongs([.row(1, .catalog)])
        let (error, calls) = run(.rotation, h, limit: 3)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.heavyRotation"])
        XCTAssertEqual(h.seen.bodies("slice.heavyRotation").first?["limit"] as? Int, 3)
        XCTAssertEqual(h.seen.locked("slice.heavyRotation"), [false])
        XCTAssertEqual(h.io.out, ["   House (playlist)"])
        XCTAssertEqual(try h.cache.readSongs(), [], "a playlist is listed, never cached as playable")
    }

    func testEmptyRotationPrintsTheShippedLabel() {
        for asJSON in [false, true] {
            let h = H(.source, ["slice.status": [ready], "slice.heavyRotation": [Y.items(op: "slice.heavyRotation", [])]])
            XCTAssertNil(run(.rotation, h, json: asJSON).error)
            XCTAssertEqual(h.io.out, [asJSON ? "{\"heavy-rotation\":[]}" : "No heavy rotation history."])
        }
    }

    // MARK: - Music.app

    func testMusicAppRunsTheShippedBodiesAndSendsNothingToBridge() {
        for op in [Op.recent, .rotation] {
            let h = H(.musicApp)
            var runs = 0
            var held: [Bool] = []
            let (error, calls) = run(op, h, musicApp: {
                runs += 1
                held.append(!OutputLockTestSupport.isFree(h.lockPath))
            })
            XCTAssertNil(error, "\(op)")
            XCTAssertEqual(runs, 1, "\(op)")
            XCTAssertEqual(held, [false], "\(op): a read takes no lock")
            XCTAssertEqual(h.wire.requestCount, 0, "\(op)")
            XCTAssertEqual(calls, [], "\(op)")
        }
    }

    /// The shipped body's own errors (its auth refusal is an `ExitCode` after
    /// it printed) pass through untouched, with nothing added.
    func testMusicAppBodyErrorsPassThroughUntouched() {
        let h = H(.musicApp)
        var thrown: Error?
        let calls = withTripwire {
            do {
                try runRecent(limit: 10, json: false, env: h.env, musicApp: { throw ExitCode.failure })
            } catch { thrown = error }
        }.calls
        XCTAssertEqual(thrown as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, [], "the dispatcher adds no line of its own")
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.wire.requestCount, 0)
    }
}
