// tools/music/Tests/MusicTests/CLIBridgePlayCommandTests.swift
//
// Slice 3 score, S7: `music play` executed through its real command path,
// `runPlay(…, env:, musicAppDeps:)`, in both modes. The Bridge wire is scripted
// and records every request with whether the output lock was held when it
// arrived; the store, lock and cache are temp; the external-call tripwire is
// armed throughout, so "0 AppleScript or REST calls" is a count. Nothing sleeps.
import ArgumentParser
import XCTest
@testable import music

/// Every request Bridge received, with the output lock's state at that moment.
final class CLIBridgeSeenRequests {
    private let lock = NSLock()
    private var entries: [(body: [String: Any], locked: Bool)] = []
    func add(_ body: [String: Any], _ locked: Bool) { lock.lock(); entries.append((body, locked)); lock.unlock() }
    var ops: [String] { lock.lock(); defer { lock.unlock() }; return entries.map { $0.body["op"] as? String ?? "" } }
    func locked(_ op: String) -> [Bool] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { ($0.body["op"] as? String) == op }.map(\.locked)
    }
    func bodies(_ op: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { ($0.body["op"] as? String) == op }.map(\.body)
    }
}

/// A CLI-surface env (production's surface) on a scripted wire, in a temp
/// directory of its own, whose transport records the lock state per request.
struct CLIBridgeCommandHarness {
    let env: CLIBridgeEnv
    let io: CLIBridgeTestIO
    let wire: BridgeLibraryReadsWire
    let seen: CLIBridgeSeenRequests
    let store: PlaybackModeStore
    var lockPath: String { env.routing.outputLock!.path }
    var cache: ResultCache { env.cache }

    init(_ mode: PlaybackMode, _ replies: [String: [String]] = [:],
         directory: String? = nil, out: ((String) -> Void)? = nil) {
        let dir = directory ?? (NSTemporaryDirectory() + "music-test-s7-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = PlaybackModeStore(path: dir + "/mode.json")
        precondition(store.set(mode))
        precondition(isUnderTemporaryDirectory(store.lockPath))
        let wire = BridgeLibraryReadsWire(replies)
        let seen = CLIBridgeSeenRequests()
        let lockPath = store.lockPath
        let routing = RoutingCoordinator(
            store: store, surface: .cli,
            makeSource: {
                SourceAppClient(path: "/nonexistent/s7-test.sock", transport: { path, line in
                    let body = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
                    seen.add(body, !OutputLockTestSupport.isFree(lockPath))
                    return try wire.transport(path, line)
                })
            },
            outputLock: OutputLock(path: lockPath))
        let io = CLIBridgeTestIO()
        let cache = ResultCache(directory: dir + "/cache")
        precondition(isUnderTemporaryDirectory(cache.directory))
        env = CLIBridgeEnv(routing: routing, modeStore: store, cache: cache,
                           out: { line in out?(line); io.writeOut(line) }, err: io.writeErr, sleep: io.sleep)
        self.io = io
        self.wire = wire
        self.seen = seen
        self.store = store
    }

    /// The directory holding this harness's mode.json, lock and cache.
    var directory: String { (lockPath as NSString).deletingLastPathComponent }
}

/// Library replies a scripted Bridge sends (the S4 fixtures' shapes).
enum CLIBridgeLibraryReplies {
    static func page(op: String, kind: String, _ items: [(id: String, title: String, artist: String, album: String)],
                     skippedVideos: Int? = nil) -> String {
        let itemsJSON = items.map {
            "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"artist\":\"\($0.artist)\",\"album\":\"\($0.album)\",\"track_count\":1,\"kind\":\"\(kind)\"}"
        }.joined(separator: ",")
        let videos = skippedVideos.map { ",\"skipped_videos\":\($0)" } ?? ""
        return "{\"ok\":true,\"op\":\"\(op)\",\"generation\":1,\"total\":\(items.count),\"items\":[\(itemsJSON)],\"next_cursor\":null\(videos)}"
    }
    static func list(op: String, _ items: [(id: String, title: String, artist: String)]) -> String {
        let itemsJSON = items.map {
            "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\",\"artist\":\"\($0.artist)\",\"album\":\"\",\"kind\":\"song\"}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"\(op)\",\"generation\":1,\"items\":[\(itemsJSON)]}"
    }
    static func songs(_ items: [(id: String, title: String, artist: String, album: String)]) -> String {
        page(op: "slice.librarySongs", kind: "song", items)
    }
    static func queued(skipped: Int = 0) -> String { #"{"ok":true,"skipped_unavailable":\#(skipped)}"# }
    static func status(_ playback: String, title: String? = nil, artist: String? = nil) -> String {
        var fields = [#""playback":"\#(playback)""#, #""authorization":"authorized""#,
                      #""contract":\#(sourceContractVersion)"#]
        if let title { fields.append(#""title":"\#(title)""#) }
        if let artist { fields.append(#""artist":"\#(artist)""#) }
        return #"{"ok":true,"status":{"# + fields.joined(separator: ",") + "}}"
    }
}

func cliJSON(_ line: String?) -> [String: Any]? {
    guard let line else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
}

final class CLIBridgePlayCommandTests: XCTestCase {

    private typealias H = CLIBridgeCommandHarness
    private typealias R = CLIBridgeLibraryReplies

    private let ready = CLIBridgeReplies.status()

    /// The status Bridge reports after a play, and its rendering.
    private let playing = R.status("playing", title: "Teardrop", artist: "Massive Attack")
    private var playingLines: [String] {
        bridgeNowLines((try? SourceAppControl(path: "/nonexistent", transport: { [playing] _, _ in playing }).status())!)
    }

    /// Music.app deps that fail the test if the Music.app body is reached.
    private var neverMusicApp: PlayMusicAppDeps {
        PlayMusicAppDeps(readSongs: { XCTFail("Music.app read the cache"); return [] },
                         resolveIndexed: { _, _ in XCTFail("Music.app re-resolved") })
    }

    @discardableResult
    private func play(_ h: H, args: [String] = [], playlist: String? = nil, album: String? = nil,
                      song: String? = nil, artist: String? = nil, json: Bool = false,
                      deps: PlayMusicAppDeps? = nil) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        var calls: [ExternalCall] = []
        do {
            calls = try withTripwire {
                do {
                    try runPlay(args: args, playlist: playlist, album: album, song: song, artist: artist,
                                json: json, env: h.env, musicAppDeps: deps ?? neverMusicApp)
                } catch {
                    thrown = error
                }
            }.calls
        } catch {
            XCTFail("withTripwire threw \(error)")
        }
        return (thrown, calls)
    }

    // MARK: - The classifier follows Play.run's branch order

    func testClassifierFollowsPlayRunsBranchOrder() {
        let url = "https://music.apple.com/us/album/x/1?i=42"
        let cases: [(args: [String], playlist: String?, album: String?, song: String?, artist: String?, MusicTUIAction)] = [
            ([], "P", nil, nil, nil, .cliPlayPlaylist),
            (["shuffle"], "P", "A", "S", "R", .cliPlayPlaylist),     // --playlist wins over everything
            ([], nil, "A", nil, nil, .cliPlayAlbum),
            (["2"], nil, "A", "S", "R", .cliPlayAlbum),               // --album before --song
            ([], nil, nil, "S", "R", .cliPlaySong),
            ([url], nil, nil, "S", nil, .cliPlaySong),                // --song before a URL
            ([], nil, nil, nil, "R", .cliPlayArtist),                 // --artist alone
            (["Teardrop"], nil, nil, nil, "R", .cliPlayArtist),       // loose words: the artist refusal, both modes
            ([url], nil, nil, nil, nil, .cliPlayCatalogSong),
            (["3"], nil, nil, nil, nil, .cliPlayIndex),
            (["3", "4"], nil, nil, nil, nil, .cliPlayQuery),
            (["Kid", "A"], nil, nil, nil, nil, .cliPlayQuery),
            (["shuffle"], nil, nil, nil, nil, .cliPlayQuery),
            ([], nil, nil, nil, nil, .cliPlayResume),
        ]
        for c in cases {
            XCTAssertEqual(playAction(args: c.args, playlist: c.playlist, album: c.album, song: c.song, artist: c.artist),
                           c.5, "\(c)")
        }
    }

    // MARK: - D4 forms on Bridge

    func testPlaylistQueuesInOrderAndReportsVideosAndUnavailable() throws {
        let h = H(.source, [
            "slice.status": [ready, playing],
            "slice.libraryPlaylists": [R.page(op: "slice.libraryPlaylists", kind: "playlist",
                                              [("p1", "Road Trip", "", ""), ("p2", "musictui-temp Road Trip", "", "")])],
            "slice.libraryPlaylistTracks": [R.page(op: "slice.libraryPlaylistTracks", kind: "song",
                                                   [("t1", "One", "X", ""), ("t2", "Two", "X", ""), ("t3", "Three", "X", "")],
                                                   skippedVideos: 2)],
            "slice.queue": [R.queued(skipped: 1)],
        ])
        let (error, calls) = play(h, playlist: "Road Trip")
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.libraryPlaylists", "slice.libraryPlaylistTracks",
                                    "slice.queue", "slice.status"])
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["library_ids"] as? [String], ["t1", "t2", "t3"])
        XCTAssertEqual(queue["start_required"] as? Bool, false)
        XCTAssertEqual(h.seen.locked("slice.queue"), [true], "the mutation holds the output lock")
        XCTAssertEqual(h.seen.locked("slice.libraryPlaylistTracks"), [false], "library walks stay outside the lock")
        XCTAssertEqual(h.seen.locked("slice.status"), [false, false], "the observation is outside the lock")
        XCTAssertEqual(h.io.out, ["Playing 2 of 5 from 'Road Trip' on Bridge: 2 videos skipped. 1 song isn't available to Bridge."]
                       + playingLines)
        XCTAssertTrue(OutputLockTestSupport.isFree(h.lockPath))
    }

    func testPlaylistJSONIsOneDocumentWithTheCombinedCounts() throws {
        let h = H(.source, [
            "slice.status": [ready, playing],
            "slice.libraryPlaylists": [R.page(op: "slice.libraryPlaylists", kind: "playlist", [("p1", "Road Trip", "", "")])],
            "slice.libraryPlaylistTracks": [R.page(op: "slice.libraryPlaylistTracks", kind: "song",
                                                   (1...40).map { ("t\($0)", "S\($0)", "X", "") }, skippedVideos: 2)],
            "slice.queue": [R.queued(skipped: 1)],
        ])
        let (error, calls) = play(h, playlist: "Road Trip", json: true)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.io.out.count, 1, "one JSON document")
        let doc = try XCTUnwrap(cliJSON(h.io.out.first))
        XCTAssertEqual(doc["output"] as? String, "bridge")
        XCTAssertEqual(doc["state"] as? String, "playing")
        XCTAssertEqual(doc["track"] as? String, "Teardrop")
        XCTAssertEqual(doc["sent"] as? Int, 40)
        XCTAssertEqual(doc["queued"] as? Int, 39)
        XCTAssertEqual(doc["skipped_unavailable"] as? Int, 1)
        XCTAssertEqual(doc["skipped_videos"] as? Int, 2)
        XCTAssertEqual(doc["playlist_members"] as? Int, 42)
        for forbidden in ["album", "duration", "position", "speakers", "live"] {
            XCTAssertNil(doc[forbidden], forbidden)
        }
    }

    func testPlaylistWithTrailingShuffleSendsEveryIdShuffledBuiltBeforeTheMutation() throws {
        let ids = (1...12).map { "t\($0)" }
        let h = H(.source, [
            "slice.status": [ready, playing],
            "slice.libraryPlaylists": [R.page(op: "slice.libraryPlaylists", kind: "playlist", [("p1", "Road Trip", "", "")])],
            "slice.libraryPlaylistTracks": [R.page(op: "slice.libraryPlaylistTracks", kind: "song",
                                                   ids.map { ($0, $0, "X", "") }, skippedVideos: 0)],
            "slice.queue": [R.queued()],
        ])
        XCTAssertNil(play(h, args: ["Shuffle"], playlist: "Road Trip").error)
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        let sent = try XCTUnwrap(queue["library_ids"] as? [String])
        XCTAssertEqual(sent.sorted(), ids.sorted())
        XCTAssertEqual(queue["start_required"] as? Bool, false)
        XCTAssertEqual(h.wire.sent("slice.queue").count, 1)
    }

    func testAlbumWithArtistQueuesTheFilteredAlbumInOrder() throws {
        let h = H(.source, [
            "slice.status": [ready, playing],
            "slice.libraryAlbums": [R.page(op: "slice.libraryAlbums", kind: "album",
                                           [("a1", "Mezzanine", "Massive Attack", ""), ("a2", "Mezzanine", "Someone Else", "")])],
            "slice.libraryAlbumTracks": [R.list(op: "slice.libraryAlbumTracks",
                                                [("s1", "Angel", "Massive Attack"), ("s2", "Risingson", "Massive Attack")])],
            "slice.queue": [R.queued()],
        ])
        let (error, calls) = play(h, album: "Mezzanine", artist: "massive")
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["library_ids"] as? [String], ["s1", "s2"])
        XCTAssertEqual(queue["start_required"] as? Bool, false)
        XCTAssertEqual((h.seen.bodies("slice.libraryAlbumTracks").first?["id"] as? String), "a1")
        XCTAssertEqual(h.io.out, ["Playing 'Mezzanine' on Bridge \u{2014} 2 tracks."] + playingLines)
    }

    func testArtistQueuesBridgesOrder() throws {
        let h = H(.source, [
            "slice.status": [ready, playing],
            "slice.libraryArtists": [R.page(op: "slice.libraryArtists", kind: "artist", [("r1", "Massive Attack", "", "")])],
            "slice.libraryArtistSongs": [R.list(op: "slice.libraryArtistSongs",
                                                [("s9", "Teardrop", "Massive Attack"), ("s3", "Angel", "Massive Attack")])],
            "slice.queue": [R.queued(skipped: 1)],
        ])
        XCTAssertNil(play(h, artist: "Massive Attack", json: true).error)
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["library_ids"] as? [String], ["s9", "s3"])
        XCTAssertEqual(queue["start_required"] as? Bool, false)
        let doc = try XCTUnwrap(cliJSON(h.io.out.first))
        XCTAssertEqual(h.io.out.count, 1)
        XCTAssertEqual(doc["sent"] as? Int, 2)
        XCTAssertEqual(doc["queued"] as? Int, 1)
        XCTAssertNil(doc["skipped_videos"], "playlists only")
    }

    func testSongQueuesOneIdWithStartRequired() throws {
        let h = H(.source, [
            "slice.status": [ready, playing],
            "slice.librarySongs": [R.songs([("s1", "Teardrop", "Massive Attack", "Mezzanine"),
                                            ("s2", "Teardrop", "Newton Faulkner", "Hand Built")])],
            "slice.queue": [R.queued()],
        ])
        let (error, calls) = play(h, song: "Teardrop", artist: "Massive")
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["library_ids"] as? [String], ["s1"])
        XCTAssertEqual(queue["start_required"] as? Bool, true)
        XCTAssertEqual(h.io.out, ["Playing 'Teardrop' on Bridge."] + playingLines)
    }

    func testResumeSendsSlicePlayUnderTheLockThenTheNowText() {
        let h = H(.source, ["slice.status": [ready, playing], "slice.play": [CLIBridgeReplies.ok]])
        let (error, calls) = play(h)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.play", "slice.status"])
        XCTAssertEqual(h.seen.locked("slice.play"), [true])
        XCTAssertEqual(h.io.out, playingLines, "resume has no result line")
    }

    func testPlayIndexQueuesTheCachedBridgeRowsId() throws {
        let h = H(.source, ["slice.status": [ready, playing], "slice.queue": [R.queued()]])
        try h.cache.writeSongs([.row(1, .bridgeLibrary, bridgeID: "b-1"), .row(2, .bridgeLibrary, bridgeID: "b-2")])
        let (error, calls) = play(h, args: ["2"], json: true)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["library_ids"] as? [String], ["b-2"])
        XCTAssertEqual(queue["start_required"] as? Bool, true)
        XCTAssertEqual(h.io.out.count, 1)
        XCTAssertEqual(cliJSON(h.io.out.first)?["sent"] as? Int, 1)
    }

    // MARK: - Nothing queued

    func testAmbiguousAndNotFoundQueueNothing() {
        let songs = R.songs([("s1", "Angel", "Massive Attack", "Mezzanine"), ("s2", "Angel", "Shaggy", "Hot Shot")])
        let cases: [(song: String, expected: String)] = [
            ("Angel", "'Angel' matches 2 songs in your Bridge library: Angel \u{2014} Massive Attack; Angel \u{2014} Shaggy. Use the exact name, or add --artist. Or: music search --library \"Angel\"  then  music play N"),
            ("Nope", "No song matching 'Nope' in your Bridge library. From the CLI, Bridge plays your library only; nothing was added or played."),
        ]
        for c in cases {
            let h = H(.source, ["slice.status": [ready], "slice.librarySongs": [songs]])
            let (error, calls) = play(h, song: c.song)
            XCTAssertEqual(error as? ExitCode, .failure, c.song)
            XCTAssertEqual(h.io.out, [c.expected], c.song)
            XCTAssertEqual(h.wire.sent("slice.queue").count, 0, c.song)
            XCTAssertEqual(calls, [])
        }
    }

    func testOverAHundredIsRefusedInBridgesWords() {
        let tooLarge = #"{"ok":false,"error":{"kind":"too_large","detail":"That's 140 songs; Bridge queues at most 100 at once."}}"#
        let h = H(.source, [
            "slice.status": [ready],
            "slice.libraryArtists": [R.page(op: "slice.libraryArtists", kind: "artist", [("r1", "Bach", "", "")])],
            "slice.libraryArtistSongs": [R.list(op: "slice.libraryArtistSongs", (1...140).map { ("s\($0)", "S\($0)", "Bach") })],
            "slice.queue": [tooLarge],
        ])
        let (error, _) = play(h, artist: "Bach")
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["Bridge refused: That's 140 songs; Bridge queues at most 100 at once."])
        XCTAssertEqual(h.wire.sent("slice.queue").count, 1, "a refused mutation is never re-sent")
    }

    // MARK: - Warming and observation

    func testLibraryReadsAndTheQueueSpendOneWarmUpBudget() {
        // 30 s of warming on the read (six 5 s waits), then a queue that stays
        // warming: with ONE budget the total wait is 60 s, never 30 + 60.
        let h = H(.source, [
            "slice.status": [ready],
            "slice.librarySongs": Array(repeating: CLIBridgeReplies.warming(retryAfter: 5), count: 6)
                + [R.songs([("s1", "Teardrop", "Massive Attack", "Mezzanine")])],
            "slice.queue": Array(repeating: CLIBridgeReplies.warming(retryAfter: 5), count: 20),
        ])
        let (error, _) = play(h, song: "Teardrop")
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.sleeps.reduce(0, +), LibraryWarmUp.maxTotalWait, accuracy: 0.0001)
        XCTAssertEqual(h.wire.sent("slice.queue").count, 7, "six more waits fit the one budget, then it gives up")
        XCTAssertEqual(h.io.out, [LibraryWarmUp.gaveUp])
        XCTAssertEqual(h.seen.locked("slice.queue"), Array(repeating: true, count: 7),
                       "each attempt re-acquires the lock")
    }

    func testAPreMutationWarmingIsRetriedOnceAndSucceeds() throws {
        let h = H(.source, [
            "slice.status": [ready, playing],
            "slice.librarySongs": [R.songs([("s1", "Teardrop", "Massive Attack", "Mezzanine")])],
            "slice.queue": [CLIBridgeReplies.warming(retryAfter: 1), R.queued()],
        ])
        XCTAssertNil(play(h, song: "Teardrop").error)
        XCTAssertEqual(h.wire.sent("slice.queue").count, 2)
        XCTAssertEqual(h.io.sleeps, [1])
        XCTAssertEqual(h.io.err, [cliBridgeWarmingProgress])
    }

    func testQueueAcceptedThenStatusFailingSucceedsWithoutResending() throws {
        for asJSON in [false, true] {
            let h = H(.source, [
                "slice.status": [ready, #"{"ok":true,"status":{}}"#],
                "slice.librarySongs": [R.songs([("s1", "Teardrop", "Massive Attack", "Mezzanine")])],
                "slice.queue": [R.queued()],
            ])
            let (error, calls) = play(h, song: "Teardrop", json: asJSON)
            XCTAssertNil(error, "the mutation's reply decides success")
            XCTAssertEqual(calls, [])
            XCTAssertEqual(h.wire.sent("slice.queue").count, 1)
            let message = SourceAppError.unreadable.message
            if asJSON {
                XCTAssertEqual(h.io.out.count, 1)
                let doc = try XCTUnwrap(cliJSON(h.io.out.first))
                XCTAssertEqual(doc["status_error"] as? String, message)
                XCTAssertEqual(doc["sent"] as? Int, 1)
            } else {
                XCTAssertEqual(h.io.out, ["Playing 'Teardrop' on Bridge."])
                XCTAssertEqual(h.io.err, ["Bridge accepted the request, but its status couldn't be read: \(message)"])
            }
        }
    }

    // MARK: - Unsupported forms refuse with 0 requests past readiness

    func testUnsupportedFormsRefuseAfterReadinessWithNothingFurther() {
        let artistLoose = artistWithLooseWordsRefusal(artist: "Massive Attack", args: ["Teardrop"],
                                                      song: nil, album: nil, playlist: nil)!
        let nameOne = "Name one of --playlist, --album, --song or --artist."
        let cases: [(label: String, args: [String], playlist: String?, album: String?, song: String?, artist: String?, expected: String)] = [
            ("artist + words", ["Teardrop"], nil, nil, nil, "Massive Attack", artistLoose),
            ("artist + shuffle", ["shuffle"], nil, nil, nil, "Massive Attack",
             artistWithLooseWordsRefusal(artist: "Massive Attack", args: ["shuffle"], song: nil, album: nil, playlist: nil)!),
            ("playlist + album", [], "P", "A", nil, nil, nameOne),
            ("playlist + artist", [], "P", nil, nil, "R", nameOne),
            ("album + song", [], nil, "A", "S", nil, nameOne),
            ("album + song + artist", [], nil, "A", "S", "R", nameOne),
            ("playlist + words", ["x"], "P", nil, nil, nil, "--playlist can't be combined with other words on Bridge."),
            ("playlist + shuffle + words", ["shuffle", "x"], "P", nil, nil, nil, "--playlist can't be combined with other words on Bridge."),
            ("album + artist + words", ["x"], nil, "A", nil, "R", "--album can't be combined with other words on Bridge."),
            ("song + shuffle", ["shuffle"], nil, nil, "S", nil, "--song can't be combined with other words on Bridge."),
            ("song + artist + words", ["x"], nil, nil, "S", "R", "--song can't be combined with other words on Bridge."),
            ("blank album", [], nil, " ", nil, nil, "Album name can't be empty."),
            ("blank playlist", [], "", nil, nil, nil, "Playlist name can't be empty."),
            ("blank song", [], nil, nil, "  ", nil, "Song name can't be empty."),
            ("blank artist", [], nil, nil, nil, "", "Artist name can't be empty."),
        ]
        for c in cases {
            for asJSON in [false, true] {
                let h = H(.source, ["slice.status": [ready]])
                let (error, calls) = play(h, args: c.args, playlist: c.playlist, album: c.album, song: c.song,
                                          artist: c.artist, json: asJSON)
                XCTAssertEqual(error as? ExitCode, .failure, c.label)
                XCTAssertEqual(h.io.out.count, 1, c.label)
                if asJSON {
                    // Parsed, not compared as bytes: JSONSerialization's key
                    // order is not stable between two dictionaries.
                    XCTAssertEqual(cliJSON(h.io.out.first)?["error"] as? String, c.expected, c.label)
                    XCTAssertEqual(cliJSON(h.io.out.first)?["ok"] as? Bool, false, c.label)
                } else {
                    XCTAssertEqual(h.io.out, [c.expected], c.label)
                }
                XCTAssertEqual(h.seen.ops, ["slice.status"], "\(c.label): readiness only")
                XCTAssertEqual(calls, [], c.label)
            }
        }
    }

    func testAURLAndFreeWordsAreRefusedByTheMatrixWithNoRequestAtAll() {
        let cases: [(args: [String], action: MusicTUIAction)] = [
            (["https://music.apple.com/us/album/x/1?i=42"], .cliPlayCatalogSong),
            (["Kid", "A"], .cliPlayQuery),
            (["Teardrop"], .cliPlayQuery),
        ]
        for c in cases {
            let h = H(.source)
            let (error, calls) = play(h, args: c.args)
            XCTAssertEqual(error as? ExitCode, .failure)
            XCTAssertEqual(h.io.out, [cliBridgeNotServedReason(c.action)], "\(c.args)")
            XCTAssertEqual(h.wire.requestCount, 0, "\(c.args)")
            XCTAssertEqual(calls, [])
        }
    }

    // MARK: - play N with a cache Bridge did not write

    func testBridgePlayIndexRefusesMusicAppAndLegacyRowsWithNoQueue() throws {
        let legacy = #"[{"index":1,"title":"Teardrop","artist":"Massive Attack","album":"Mezzanine","catalogId":"i.abc"}]"#
        let written: [(label: String, write: (ResultCache) throws -> Void)] = [
            ("catalogue", { try $0.writeSongs([.row(1, .catalog)]) }),
            ("library", { try $0.writeSongs([.row(1, .library)]) }),
            ("legacy", { cache in
                try FileManager.default.createDirectory(atPath: cache.directory, withIntermediateDirectories: true)
                try Data(legacy.utf8).write(to: URL(fileURLWithPath: cache.directory + "/last-songs.json"))
            }),
        ]
        for w in written {
            let h = H(.source, ["slice.status": [ready]])
            try w.write(h.cache)
            let row = try h.cache.lookupSong(index: 1)
            guard case .refuse(let why) = bridgeRef(forCachedRow: row, index: 1) else { return XCTFail(w.label) }
            let (error, calls) = play(h, args: ["1"])
            XCTAssertEqual(error as? ExitCode, .failure, w.label)
            XCTAssertEqual(h.io.out, [why], w.label)
            XCTAssertEqual(h.wire.sent("slice.queue").count, 0, w.label)
            XCTAssertEqual(calls, [], w.label)
        }
    }

    func testBridgePlayIndexWithNoBridgeIdOrOutOfRangeRefuses() throws {
        let h = H(.source, ["slice.status": [ready]])
        try h.cache.writeSongs([.row(1, .bridgeLibrary, bridgeID: nil)])
        XCTAssertEqual(play(h, args: ["1"]).error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["Result 1 has no Bridge id; run the search again."])

        let h2 = H(.source, ["slice.status": [ready]])
        try h2.cache.writeSongs([.row(1, .bridgeLibrary, bridgeID: "b-1")])
        XCTAssertEqual(play(h2, args: ["3"]).error as? ExitCode, .failure)
        XCTAssertEqual(h2.io.out, ["Index 3 is out of range."])
        XCTAssertEqual(h2.wire.sent("slice.queue").count + h.wire.sent("slice.queue").count, 0)
    }

    // MARK: - Music.app mode: the production body

    /// The Music.app branch is always the production `playViaMusicApp`: Bridge
    /// hears nothing, and its first external effect is the shipped AppleScript,
    /// stopped and counted by the tripwire.
    func testMusicAppModeRunsTheProductionBody() {
        let cases: [(label: String, args: [String], playlist: String?, expect: String)] = [
            ("resume", [], nil, "play"),
            ("playlist", [], "Road Trip", "play playlist \"Road Trip\""),
        ]
        for c in cases {
            let h = H(.musicApp)
            var printed: (output: String, error: Error?) = ("", nil)
            var calls: [ExternalCall] = []
            printed = captureStdout {
                let result = play(h, args: c.args, playlist: c.playlist, deps: .live)
                calls = result.calls
                if let error = result.error { throw error }
            }
            XCTAssertTrue(printed.error is ExternalCallBlocked, "\(c.label): \(String(describing: printed.error))")
            XCTAssertEqual(calls.count, 1, c.label)
            guard case .appleScript(let script)? = calls.first else { return XCTFail(c.label) }
            XCTAssertTrue(script.contains(c.expect), "\(c.label): \(script)")
            XCTAssertEqual(h.wire.requestCount, 0, c.label)
        }
    }

    func testMusicAppModeHoldsTheLockForTheWholeBody() {
        let h = H(.musicApp)
        var held: [Bool] = []
        let deps = PlayMusicAppDeps(readSongs: { held.append(!OutputLockTestSupport.isFree(h.lockPath)); return [.row(1, .catalog)] },
                                    resolveIndexed: { _, _ in held.append(!OutputLockTestSupport.isFree(h.lockPath)) })
        let printed = captureStdout {
            let result = play(h, args: ["1"], deps: deps)
            XCTAssertEqual(result.calls.count, 1, "the shipped now-playing read after the re-resolve")
            if let error = result.error { throw error }
        }
        XCTAssertNil(printed.error)
        XCTAssertEqual(held, [true, true])
        XCTAssertTrue(OutputLockTestSupport.isFree(h.lockPath))
    }

    /// Not over-broad: a catalogue row in Music.app mode reaches the shipped
    /// re-resolve exactly once, with that row.
    func testMusicAppPlayIndexReResolvesACatalogueRow() {
        let h = H(.musicApp)
        var resolved: [(SongResult, Int)] = []
        let deps = PlayMusicAppDeps(readSongs: { [.row(1, .catalog), .row(2, .library)] },
                                    resolveIndexed: { resolved.append(($0, $1)) })
        _ = captureStdout { _ = play(h, args: ["2"], deps: deps) }
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.0, .row(2, .library))
        XCTAssertEqual(resolved.first?.1, 2)
        XCTAssertEqual(h.wire.requestCount, 0)
    }

    // MARK: - Cross-output (R2)

    /// Bridge `search --library` publishes Bridge rows; Output switches to
    /// Music.app; Music.app `play 2` refuses in S3's words with the resolver,
    /// the tripwire and the wire all at 0.
    func testBridgeRowsNeverReachMusicAppsReResolve() throws {
        let bridge = H(.source, [
            "slice.status": [ready],
            "slice.librarySongs": [R.songs([("s1", "Angel", "Massive Attack", "Mezzanine"),
                                            ("s2", "Teardrop", "Massive Attack", "Mezzanine")])],
        ])
        try withTripwire { try runSearch(query: ["Massive"], artist: nil, album: nil, types: "songs", library: true,
                                          limit: 10, json: false, env: bridge.env) }
        XCTAssertEqual(try bridge.cache.readSongs().map(\.origin), [.bridgeLibrary, .bridgeLibrary])

        XCTAssertTrue(bridge.store.set(.musicApp))
        let musicApp = H(.musicApp, directory: bridge.directory)
        XCTAssertEqual(musicApp.cache.directory, bridge.cache.directory)
        var resolverCalls = 0
        let deps = PlayMusicAppDeps(readSongs: { try musicApp.cache.readSongs() },
                                    resolveIndexed: { _, _ in resolverCalls += 1 })
        var result: (error: Error?, calls: [ExternalCall]) = (nil, [])
        let printed = captureStdout { result = play(musicApp, args: ["2"], deps: deps) }
        XCTAssertEqual(result.error as? ExitCode, .failure)
        let row = try musicApp.cache.lookupSong(index: 2)
        guard case .refuse(let why) = musicAppIndexRoute(forCachedRow: row, index: 2) else { return XCTFail() }
        XCTAssertEqual(printed.output, why + "\n")
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(result.calls, [], "no AppleScript, no REST")
        XCTAssertEqual(musicApp.wire.requestCount, 0)
    }
}
