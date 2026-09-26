// tools/music/Tests/MusicTests/CLIBridgeListingsTests.swift
//
// Slice 3 Part 2, P8: `music discover`, `playlist list`, `playlist tracks`,
// `similar <title>`, `suggest --from` and `new-releases --artist`, executed
// through their real command paths (`runDiscover`, `runPlaylistList`,
// `runPlaylistTracks`, `runSimilar`, `refuseInBridge`) in both modes. The
// Bridge wire is scripted and records each request with whether the output
// lock was held; the mode store, lock and cache are temp; the external-call
// tripwire is armed; nothing sleeps. No real Music.app, network, Bridge or
// ~/.config/music.
import ArgumentParser
import XCTest
@testable import music

/// Discover replies a scripted Bridge sends (the measured `slice.recommendations` shape).
enum CLIBridgeListingsReplies {
    static let rails = """
    {"ok":true,"op":"slice.recommendations","rails":[
      {"title":"Recently Played","items":[
        {"id":"ra.978194965","kind":"station","name":"Apple Music 1","artwork_url":"https://a/1.jpg"},
        {"id":"1440857781","kind":"album","name":"Aja","subtitle":"Steely Dan"},
        {"id":"pl.u-abc","kind":"playlist","name":"Boom Bap","subtitle":"Apple Music Hip-Hop"}
      ]},
      {"title":"Made for You","items":[
        {"id":"pl.u-def","kind":"playlist","name":"Chill Mix","subtitle":"Apple Music"}
      ]}
    ]}
    """

    static func playlists(_ names: [(id: String, name: String)]) -> String {
        CLIBridgeLibraryReplies.page(op: "slice.libraryPlaylists", kind: "playlist", names.map { ($0.id, $0.name, "", "") })
    }

    static func tracks(_ items: [(id: String, title: String, artist: String, album: String)]) -> String {
        CLIBridgeLibraryReplies.page(op: "slice.libraryPlaylistTracks", kind: "song", items, skippedVideos: 0)
    }

    static func songs(_ songs: [(id: String, title: String, artist: String)]) -> String {
        CLIBridgeCatalogueReplies.search(songs.map { ("song", $0.id, $0.title, $0.artist, nil) })
    }
}

final class CLIBridgeListingsTests: XCTestCase {

    private typealias H = CLIBridgeCommandHarness
    private typealias L = CLIBridgeListingsReplies
    private typealias R = CLIBridgeLibraryReplies

    private let ready = CLIBridgeReplies.status()
    private let playing = CLIBridgeLibraryReplies.status("playing", title: "Two", artist: "X")

    /// Runs `body` with the tripwire armed; returns its error and every
    /// AppleScript/REST call that reached a funnel.
    private func tripwired(_ body: () throws -> Void) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let calls = withTripwire { do { try body() } catch { thrown = error } }.calls
        return (thrown, calls)
    }

    private func decodedRails() throws -> [DiscoverRail] {
        try SourceAppControl(path: "/nonexistent", transport: { _, _ in L.rails }).recommendations(limit: 30)
    }

    // MARK: - discover

    private func discover(_ h: H, limit: Int = 8, perRail: Int = 6, recent: Bool = false, json: Bool = false,
                          all: Bool = false, musicApp: (() -> Void)? = nil) -> (error: Error?, calls: [ExternalCall]) {
        tripwired {
            try runDiscover(limit: limit, perRail: perRail, recent: recent, json: json, all: all, env: h.env,
                            musicApp: { if let musicApp { musicApp() } else { XCTFail("Music.app ran") } })
        }
    }

    func testBridgeDiscoverReadsRecommendationsAtTheTuisLimitAndPrintsTheCuratedRails() throws {
        let h = H(.source, ["slice.status": [ready], "slice.recommendations": [L.rails]])
        let (error, calls) = discover(h)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [], "no token read reaches REST, no AppleScript")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.recommendations"])
        let body = try XCTUnwrap(h.seen.bodies("slice.recommendations").first)
        XCTAssertEqual(body["limit"] as? Int, 30, "the TUI's own rail limit (DiscoverScene)")
        XCTAssertEqual(h.seen.locked("slice.recommendations"), [false], "a read takes no output lock")
        XCTAssertEqual(h.io.out, bridgeDiscoverLines(resolvedDiscoverRails(try decodedRails())))
        XCTAssertEqual(h.io.out.first, "\nRecently Played")
        XCTAssertEqual(h.io.out[1], "  ▶ Apple Music 1  [station]")
    }

    /// Curation is the TUI's five-slot policy: six rails from Bridge show as
    /// five unless `--all`, which shows every rail in Bridge's order.
    func testDiscoverCuratesToTheTuisFiveSlotsUnlessAll() throws {
        let six = #"{"ok":true,"op":"slice.recommendations","rails":["#
            + (1...6).map { #"{"title":"Rail \#($0)","items":[{"id":"pl.\#($0)","kind":"playlist","name":"P\#($0)"}]}"# }
                .joined(separator: ",") + "]}"
        let curated = H(.source, ["slice.status": [ready], "slice.recommendations": [six]])
        XCTAssertNil(discover(curated).error)
        XCTAssertEqual(curated.io.out.filter { $0.hasPrefix("\n") }, (1...5).map { "\nRail \($0)" })
        let all = H(.source, ["slice.status": [ready], "slice.recommendations": [six]])
        XCTAssertNil(discover(all, all: true).error)
        XCTAssertEqual(all.io.out.filter { $0.hasPrefix("\n") }, (1...6).map { "\nRail \($0)" })
    }

    func testDiscoverLimitsRailsAndItemsAndAllSkipsCuration() throws {
        let h = H(.source, ["slice.status": [ready], "slice.recommendations": [L.rails]])
        XCTAssertNil(discover(h, limit: 1, perRail: 2, all: true).error)
        XCTAssertEqual(h.io.out, ["\nRecently Played",
                                  "  ▶ Apple Music 1  [station]",
                                  "    Aja — Steely Dan  [album]"])
    }

    func testDiscoverJSONOmitsRecentlyPlayedAndURL() throws {
        let h = H(.source, ["slice.status": [ready], "slice.recommendations": [L.rails]])
        XCTAssertNil(discover(h, limit: 2, perRail: 1, json: true, all: true).error)
        XCTAssertEqual(h.io.out.count, 1)
        let rails = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(h.io.out[0].utf8))) as? [[String: Any]])
        XCTAssertEqual(rails.map { $0["title"] as? String }, ["Recently Played", "Made for You"])
        XCTAssertEqual(Set(rails[0].keys), ["title", "items"], "no recentlyPlayed, never false")
        let item = try XCTUnwrap((rails[0]["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["id"] as? String, "ra.978194965")
        XCTAssertNil(item["url"], "Bridge sends no url")
        XCTAssertEqual((rails[0]["items"] as? [Any])?.count, 1, "--per-rail")
    }

    func testDiscoverRecentRefusesOnBridgeBeforeAnyBridgeRead() {
        for asJSON in [false, true] {
            let h = H(.source, ["slice.status": [ready]])
            let (error, calls) = discover(h, recent: true, json: asJSON)
            XCTAssertEqual(error as? ExitCode, .failure)
            XCTAssertEqual(calls, [])
            XCTAssertEqual(h.seen.ops, ["slice.status"], "readiness only; no slice.recommendations")
            let expected = "Bridge doesn't serve the recently played row. Switch Output to Music.app to use music discover --recent."
            XCTAssertEqual(h.io.out, [cliFailureText(expected, json: asJSON)])
        }
    }

    func testDiscoverFailurePrintsBridgesWords() {
        let h = H(.source, ["slice.status": [ready], "slice.recommendations": [CLIBridgeReplies.refused("feed unavailable")]])
        let (error, _) = discover(h)
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["Bridge refused: feed unavailable"])
    }

    func testMusicAppDiscoverRunsTheShippedBodyAndSendsNothingToBridge() {
        for recent in [false, true] {
            let h = H(.musicApp)
            var runs = 0
            let (error, calls) = discover(h, recent: recent, musicApp: { runs += 1 })
            XCTAssertNil(error)
            XCTAssertEqual(runs, 1)
            XCTAssertEqual(h.wire.requestCount, 0)
            XCTAssertEqual(calls, [])
        }
    }

    // MARK: - playlist list

    private func playlistList(_ h: H, json: Bool = false, musicApp: (() -> Void)? = nil) -> (error: Error?, calls: [ExternalCall]) {
        tripwired {
            try runPlaylistList(json: json, env: h.env,
                                musicApp: { _ in if let musicApp { musicApp() } else { XCTFail("Music.app ran") } })
        }
    }

    func testBridgePlaylistListWalksBridgesLibraryAndHidesTempPlaylists() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.libraryPlaylists": [L.playlists([("p1", "Road Trip"), ("p2", "__temp__ Road Trip"),
                                                                    ("p3", "Top 25 Most Played")])]])
        let (error, calls) = playlistList(h)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.libraryPlaylists"])
        XCTAssertEqual(h.seen.locked("slice.libraryPlaylists"), [false])
        XCTAssertEqual(h.io.out, ["Road Trip", "Top 25 Most Played"])
    }

    func testBridgePlaylistListJSONCarriesBridgeIDsNeverID() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.libraryPlaylists": [L.playlists([("p1", "Road Trip"), ("p2", "__discover__ X")])]])
        XCTAssertNil(playlistList(h, json: true).error)
        let doc = try XCTUnwrap(cliJSON(h.io.out.first))
        let rows = try XCTUnwrap(doc["playlists"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"] as? String, "Road Trip")
        XCTAssertEqual(rows[0]["bridge_id"] as? String, "p1")
        XCTAssertNil(rows[0]["id"])
    }

    func testMusicAppPlaylistListRunsTheShippedBodyAndSendsNothingToBridge() {
        let h = H(.musicApp)
        var runs = 0
        let (error, calls) = playlistList(h, musicApp: { runs += 1 })
        XCTAssertNil(error)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(h.wire.requestCount, 0)
        XCTAssertEqual(calls, [])
    }

    // MARK: - playlist tracks

    private func playlistTracks(_ h: H, _ name: String, json: Bool = false,
                                musicApp: ((String) -> Void)? = nil) -> (error: Error?, calls: [ExternalCall]) {
        tripwired {
            try runPlaylistTracks(name: name, json: json, env: h.env,
                                  musicApp: { n, _ in if let musicApp { musicApp(n) } else { XCTFail("Music.app ran") } })
        }
    }

    private let roadTrip = [("t1", "One", "X", "First"), ("t2", "Two", "X", ""), ("t3", "Three", "Y", "Third")]

    func testBridgePlaylistTracksPublishesBridgeLibraryRowsBeforePrinting() throws {
        var cachedAtFirstPrint: [SongResult]?
        var cacheForPrint: ResultCache?
        let h = H(.source, ["slice.status": [ready],
                            "slice.libraryPlaylists": [L.playlists([("p1", "Road Trip"), ("p2", "Road Trip Extended")])],
                            "slice.libraryPlaylistTracks": [L.tracks(roadTrip)]],
                  out: { _ in if cachedAtFirstPrint == nil { cachedAtFirstPrint = (try? cacheForPrint?.readSongs()) ?? [] } })
        cacheForPrint = h.cache
        let (error, calls) = playlistTracks(h, "road trip")
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.libraryPlaylists", "slice.libraryPlaylistTracks"])
        XCTAssertEqual(h.seen.bodies("slice.libraryPlaylistTracks").first?["id"] as? String, "p1",
                       "an exact name beats a substring match")
        let published = try h.cache.readSongs()
        XCTAssertEqual(published.map(\.origin), [.bridgeLibrary, .bridgeLibrary, .bridgeLibrary])
        XCTAssertEqual(published.map(\.bridgeID), ["t1", "t2", "t3"])
        XCTAssertEqual(published.map(\.catalogId), ["", "", ""])
        XCTAssertEqual(cachedAtFirstPrint, published, "published before the first line was printed")
        XCTAssertEqual(h.io.out, ["1. One — X [First]", "2. Two — X []", "3. Three — Y [Third]"])
    }

    func testPlayThreeAfterPlaylistTracksQueuesRowThreesBridgeLibraryID() throws {
        let h = H(.source, ["slice.status": [ready, ready, playing],
                            "slice.libraryPlaylists": [L.playlists([("p1", "Road Trip")])],
                            "slice.libraryPlaylistTracks": [L.tracks(roadTrip)],
                            "slice.queue": [R.queued()]])
        XCTAssertNil(playlistTracks(h, "Road Trip").error)
        let (error, calls) = tripwired {
            try runPlay(args: ["3"], playlist: nil, album: nil, song: nil, artist: nil, json: false, env: h.env,
                        musicAppDeps: PlayMusicAppDeps(readSongs: { XCTFail(); return [] },
                                                       resolveIndexed: { _, _ in XCTFail() }))
        }
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["library_ids"] as? [String], ["t3"])
        XCTAssertNil(queue["ids"], "a library row never queues as a catalogue id")
    }

    func testBridgePlaylistTracksJSON() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.libraryPlaylists": [L.playlists([("p1", "Road Trip")])],
                            "slice.libraryPlaylistTracks": [L.tracks(roadTrip)]])
        XCTAssertNil(playlistTracks(h, "road trip", json: true).error)
        let doc = try XCTUnwrap(cliJSON(h.io.out.first))
        XCTAssertEqual(doc["playlist"] as? String, "Road Trip", "the matched playlist's own name")
        let tracks = try XCTUnwrap(doc["tracks"] as? [[String: Any]])
        XCTAssertEqual(tracks.map { $0["bridge_id"] as? String }, ["t1", "t2", "t3"])
        XCTAssertEqual(tracks.map { $0["number"] as? Int }, [1, 2, 3])
        XCTAssertNil(tracks[0]["id"])
    }

    func testAnAmbiguousPlaylistNameRefusesWithAListAndReadsNoTracks() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.libraryPlaylists": [L.playlists([("p1", "Road Trip 1"), ("p2", "Road Trip 2")])]])
        try h.cache.writeSongs([.row(1, .catalog)])
        let (error, calls) = playlistTracks(h, "road trip")
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.libraryPlaylists"], "0 track reads")
        XCTAssertEqual(h.io.out, ["'road trip' matches 2 playlists in your Bridge library: Road Trip 1; Road Trip 2. Use the exact name."])
        XCTAssertEqual(try h.cache.readSongs(), [.row(1, .catalog)], "a refusal publishes nothing")
    }

    func testAPlaylistNamedOnlyByATempPlaylistIsNotFound() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.libraryPlaylists": [L.playlists([("p1", "__temp__ Road Trip")])]])
        let (error, _) = playlistTracks(h, "Road Trip")
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["No playlist named 'Road Trip' in your Bridge library."])
        XCTAssertEqual(h.wire.sent("slice.libraryPlaylistTracks").count, 0)
    }

    /// The refusals are S4's, verbatim: the same rows refused by
    /// `resolveBridgePlaylistSelection` (music play --playlist) and by
    /// `playlist tracks` read identically. Guards the copy against drift.
    func testPlaylistTracksRefusalsAreS4sWords() throws {
        let lists: [[(id: String, name: String)]] = [
            [("p1", "Road Trip 1"), ("p2", "Road Trip 2")],
            (1...7).map { ("p\($0)", "Road Trip \($0)") },
            [("p1", "Jazz")],
        ]
        for list in lists {
            let reply = L.playlists(list)
            let provider = BridgeMusicProvider(control: SourceAppControl(path: "/nonexistent", transport: { _, _ in reply }))
            guard case .refused(let s4) = try resolveBridgePlaylistSelection(provider: provider, name: "road trip", shuffle: false,
                                                                               sleep: { _ in XCTFail("slept") }) else {
                return XCTFail("S4 should refuse")
            }
            let h = H(.source, ["slice.status": [ready], "slice.libraryPlaylists": [reply]])
            XCTAssertEqual(playlistTracks(h, "road trip").error as? ExitCode, .failure)
            XCTAssertEqual(h.io.out, [s4])
        }
    }

    func testAFailedPublicationPrintsNoTracksAndExitsOne() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.libraryPlaylists": [L.playlists([("p1", "Road Trip")])],
                            "slice.libraryPlaylistTracks": [L.tracks(roadTrip)]])
        XCTAssertTrue(FileManager.default.createFile(atPath: h.cache.directory, contents: Data("x".utf8)))
        let (error, _) = playlistTracks(h, "Road Trip")
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out.count, 1)
        XCTAssertTrue(h.io.out[0].hasPrefix("Couldn't save these results, so music play N would not find them: "), h.io.out[0])
    }

    /// One command, one warm-up budget: 30 s of warming on the playlist walk,
    /// then a tracks walk that stays warming, waits 60 s in total, never 30 + 60.
    func testThePlaylistAndTracksWalksSpendOneWarmUpBudget() {
        let warming = CLIBridgeReplies.warming(retryAfter: 5)
        let h = H(.source, ["slice.status": [ready],
                            "slice.libraryPlaylists": Array(repeating: warming, count: 6) + [L.playlists([("p1", "Road Trip")])],
                            "slice.libraryPlaylistTracks": Array(repeating: warming, count: 20)])
        let (error, _) = playlistTracks(h, "Road Trip")
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.sleeps.reduce(0, +), LibraryWarmUp.maxTotalWait, accuracy: 0.0001)
        XCTAssertEqual(h.wire.sent("slice.libraryPlaylistTracks").count, 7, "six more waits fit the one budget, then it gives up")
        XCTAssertEqual(h.io.out, [LibraryWarmUp.gaveUp])
        XCTAssertEqual(h.io.err.filter { $0 == cliBridgeWarmingProgress }.count, 12)
    }

    func testMusicAppPlaylistTracksRunsTheShippedBodyWithTheNameAndSendsNothingToBridge() {
        let h = H(.musicApp)
        var names: [String] = []
        let (error, calls) = playlistTracks(h, "Road Trip", musicApp: { names.append($0) })
        XCTAssertNil(error)
        XCTAssertEqual(names, ["Road Trip"])
        XCTAssertEqual(h.wire.requestCount, 0)
        XCTAssertEqual(calls, [])
    }

    // MARK: - similar <title>

    private func similar(_ h: H, _ query: [String], artist: String? = nil, limit: Int = 3, json: Bool = false,
                         musicApp: (() -> Void)? = nil) -> (error: Error?, calls: [ExternalCall]) {
        tripwired {
            try runSimilar(query: query, artist: artist, limit: limit, json: json, env: h.env,
                           musicApp: { if let musicApp { musicApp() } else { XCTFail("Music.app ran") } })
        }
    }

    /// The shipped algorithm on Bridge's catalogue search: the seed, then the
    /// seed's artist (limit + 5, seed removed), then, when short, the seed's
    /// title (limit, de-duplicated by id). Albums are never candidates.
    func testBridgeSimilarRunsTheShippedAlgorithmOnBridgeSearch() throws {
        let seed = L.songs([("s0", "Teardrop", "Massive Attack")])
        let byArtist = CLIBridgeCatalogueReplies.search([
            ("song", "s0", "Teardrop", "Massive Attack", nil),
            ("song", "s1", "Angel", "Massive Attack", "Mezzanine"),
            ("album", "a1", "Mezzanine", "Massive Attack", nil),
        ])
        let byTitle = L.songs([("s1", "Angel", "Massive Attack"), ("s2", "Teardrop", "Elizabeth Fraser"),
                               ("s0", "Teardrop", "Massive Attack"), ("s3", "Teardrop (Live)", "Massive Attack")])
        let h = H(.source, ["slice.status": [ready], "slice.search": [seed, byArtist, byTitle]])
        let (error, calls) = similar(h, ["teardrop"], artist: "massive attack", limit: 3)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [], "no token read reaches REST, no AppleScript")
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.search", "slice.search", "slice.search"])
        let bodies = h.seen.bodies("slice.search")
        XCTAssertEqual(bodies.map { $0["term"] as? String }, ["teardrop massive attack", "Massive Attack", "Teardrop"])
        XCTAssertEqual(bodies.map { $0["limit"] as? Int }, [1, 8, 3])
        XCTAssertEqual(h.seen.locked("slice.search"), [false, false, false])
        XCTAssertEqual(h.io.out, ["Similar to: Teardrop — Massive Attack",
                                  "1. Angel — Massive Attack [Mezzanine]",
                                  "2. Teardrop — Elizabeth Fraser",
                                  "3. Teardrop (Live) — Massive Attack"])
        XCTAssertEqual(try h.cache.readSongs(), [
            SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine", catalogId: "",
                       origin: .bridgeCatalog, bridgeID: "s1"),
            SongResult(index: 2, title: "Teardrop", artist: "Elizabeth Fraser", album: "", catalogId: "",
                       origin: .bridgeCatalog, bridgeID: "s2"),
            SongResult(index: 3, title: "Teardrop (Live)", artist: "Massive Attack", album: "", catalogId: "",
                       origin: .bridgeCatalog, bridgeID: "s3"),
        ])
    }

    func testBridgeSimilarSkipsTheTitleSearchWhenTheArtistFillsTheLimit() throws {
        let h = H(.source, ["slice.status": [ready],
                            "slice.search": [L.songs([("s0", "Teardrop", "Massive Attack")]),
                                             L.songs([("s1", "Angel", "Massive Attack"), ("s2", "Unfinished", "Massive Attack")])]])
        XCTAssertNil(similar(h, ["teardrop"], limit: 2, json: true).error)
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.search", "slice.search"])
        let rows = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(h.io.out[0].utf8))) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["s1", "s2"])
        XCTAssertNil(rows[0]["album"], "absent, never \"\"")
    }

    func testBridgeSimilarWithNoSeedSaysCouldNotFindAndPublishesNothing() throws {
        let h = H(.source, ["slice.status": [ready], "slice.search": [L.songs([])]])
        try h.cache.writeSongs([.row(1, .catalog)])
        let (error, calls) = similar(h, ["zzz"])
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, ["Could not find 'zzz'"])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.search"])
        XCTAssertEqual(try h.cache.readSongs(), [.row(1, .catalog)])
    }

    func testSimilarToTheCurrentTrackStillRefusesOnBridgeWithNoRequest() {
        let h = H(.source)
        let (error, calls) = similar(h, [])
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out, [currentTrackIsStaleInBridge])
        XCTAssertEqual(h.wire.requestCount, 0)
    }

    func testMusicAppSimilarRunsTheShippedBodyForBothVariantsAndSendsNothingToBridge() {
        for query in [["teardrop"], []] {
            let h = H(.musicApp)
            var runs = 0
            let (error, calls) = similar(h, query, musicApp: { runs += 1 })
            XCTAssertNil(error)
            XCTAssertEqual(runs, 1)
            XCTAssertEqual(h.wire.requestCount, 0)
            XCTAssertEqual(calls, [])
        }
    }

    // MARK: - suggest, new-releases (Q1 default: refused)

    static let suggestRefusal =
        "Bridge output is selected, and music suggest needs Apple Music account reads Bridge doesn't serve. Switch Output to Music.app to use it."
    static let newReleasesRefusal =
        "Bridge output is selected, and music new-releases needs a catalogue artist lookup Bridge doesn't serve. Switch Output to Music.app to use it."

    func testSuggestAndNewReleasesRefuseOnBridgeBeforeAnyRequest() {
        let cases: [(MusicTUIAction, String)] = [
            (suggestAction(from: "Top 25 Most Played"), Self.suggestRefusal),
            (newReleasesAction(artist: "Air", likeCurrent: false), Self.newReleasesRefusal),
            (newReleasesAction(artist: "Air", likeCurrent: true), Self.newReleasesRefusal),
            (newReleasesAction(artist: nil, likeCurrent: false), Self.newReleasesRefusal),
        ]
        for (action, sentence) in cases {
            for asJSON in [false, true] {
                var thrown: Error?
                let (captured, calls) = withTripwire {
                    captureStdout { do { try refuseInBridge(action, json: asJSON, mode: .source) } catch { thrown = error; throw error } }
                }
                XCTAssertEqual(thrown as? ExitCode, .failure, "\(action)")
                XCTAssertEqual(calls, [], "\(action)")
                XCTAssertEqual(captured.output, cliFailureText(sentence, json: asJSON) + "\n", "\(action)")
            }
            XCTAssertNil(cliBridgeRefusal(action, mode: .musicApp), "\(action) ships unchanged with Music.app")
        }
    }

    func testTheCurrentTrackVariantsKeepTheirOwnReason() {
        for action in [suggestAction(from: nil), newReleasesAction(artist: nil, likeCurrent: true), similarAction(query: [])] {
            XCTAssertEqual(cliBridgeRefusal(action, mode: .source), currentTrackIsStaleInBridge, "\(action)")
        }
    }
}
