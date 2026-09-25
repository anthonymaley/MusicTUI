// tools/music/Tests/MusicTests/CLIBridgeCataloguePlayTests.swift
//
// Slice 3 Part 2, P6 (D6, D7): catalogue playback with Bridge selected, through
// the real command paths. `play N` on a `.bridgeCatalog` row and `play <song
// link>` send ONE `slice.queue {"ids"}` (never `library_ids`) under the output
// lock; everything else a catalogue row could reach refuses before any request
// or token read: the other output's `play N`, add and playlist writes, album
// links and free words. Temp store, lock and cache; tripwire armed; no sleeps.
import ArgumentParser
import XCTest
@testable import music

final class CLIBridgeCataloguePlayTests: XCTestCase {

    private typealias H = CLIBridgeCommandHarness
    private typealias R = CLIBridgeLibraryReplies
    private typealias C = CLIBridgeCatalogueReplies

    private let ready = CLIBridgeReplies.status()
    private let playing = R.status("playing", title: "Teardrop", artist: "Massive Attack")
    private var playingLines: [String] {
        bridgeNowLines((try? SourceAppControl(path: "/nonexistent", transport: { [playing] _, _ in playing }).status())!)
    }

    private var neverMusicApp: PlayMusicAppDeps {
        PlayMusicAppDeps(readSongs: { XCTFail("Music.app read the cache"); return [] },
                         resolveIndexed: { _, _ in XCTFail("Music.app re-resolved") })
    }

    @discardableResult
    private func play(_ h: H, _ args: [String], json: Bool = false,
                      deps: PlayMusicAppDeps? = nil) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let calls = withTripwire {
            do {
                try runPlay(args: args, playlist: nil, album: nil, song: nil, artist: nil, json: json,
                            env: h.env, musicAppDeps: deps ?? neverMusicApp)
            } catch { thrown = error }
        }.calls
        return (thrown, calls)
    }

    private func catalogueSearch(_ h: H) {
        var thrown: Error?
        do {
            try runSearch(query: ["massive"], artist: nil, album: nil, types: "songs,albums", library: false,
                          limit: 10, json: false, env: h.env,
                          musicApp: { _, _, _, _, _, _, _ in XCTFail("Music.app search ran") })
        } catch { thrown = error }
        XCTAssertNil(thrown)
    }

    // MARK: - play N after a Bridge catalogue search

    func testSearchThenPlayTwoQueuesRowTwosIdAsACatalogueId() throws {
        let h = H(.source, [
            "slice.status": [ready, ready, playing],
            "slice.search": [C.mixed],
            "slice.queue": [R.queued()],
        ])
        catalogueSearch(h)
        let before = h.io.out.count
        let (error, calls) = play(h, ["2"])
        XCTAssertNil(error)
        XCTAssertEqual(calls, [], "no AppleScript, no REST")
        let queues = h.seen.bodies("slice.queue")
        XCTAssertEqual(queues.count, 1)
        let queue = try XCTUnwrap(queues.first)
        XCTAssertEqual(queue["ids"] as? [String], ["1440857999"], "row 2 is Teardrop; the album is not a row")
        XCTAssertNil(queue["library_ids"], "never a library id")
        XCTAssertEqual(Set(queue.keys), ["op", "ids"])
        XCTAssertEqual(h.seen.locked("slice.queue"), [true], "the mutation holds the output lock")
        XCTAssertEqual(Array(h.io.out.dropFirst(before)), ["Playing 'Teardrop' on Bridge."] + playingLines)
        XCTAssertTrue(OutputLockTestSupport.isFree(h.lockPath))
    }

    func testPlayNJSONCarriesSentQueuedAndSkipped() throws {
        let h = H(.source, ["slice.status": [ready, playing], "slice.queue": [R.queued()]])
        try h.cache.writeSongs([SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "",
                                           catalogId: "", origin: .bridgeCatalog, bridgeID: "1440857781")])
        XCTAssertNil(play(h, ["1"], json: true).error)
        let doc = try XCTUnwrap(cliJSON(h.io.out.last))
        XCTAssertEqual(doc["sent"] as? Int, 1)
        XCTAssertEqual(doc["queued"] as? Int, 1)
        XCTAssertEqual(doc["skipped_unavailable"] as? Int, 0)
        XCTAssertEqual(doc["output"] as? String, "bridge")
    }

    // MARK: - Song links

    func testASongLinkQueuesItsIdAsACatalogueId() throws {
        let h = H(.source, ["slice.status": [ready, playing], "slice.queue": [R.queued()]])
        let (error, calls) = play(h, ["https://music.apple.com/us/album/mezzanine/1440857000?i=1440857781"])
        XCTAssertNil(error)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(h.seen.ops, ["slice.status", "slice.queue", "slice.status"])
        let queue = try XCTUnwrap(h.seen.bodies("slice.queue").first)
        XCTAssertEqual(queue["ids"] as? [String], ["1440857781"], "the song id from ?i=, never the album id")
        XCTAssertNil(queue["library_ids"])
        XCTAssertEqual(h.seen.locked("slice.queue"), [true])
        XCTAssertEqual(h.io.out, ["Playing Apple Music song 1440857781 on Bridge."] + playingLines)
    }

    func testAnAlbumLinkAndFreeWordsRefuseWithNoRequestAtAll() {
        for args in [["https://music.apple.com/us/album/mezzanine/1440857000"], ["Kid", "A"], ["Teardrop"]] {
            let h = H(.source)
            let (error, calls) = play(h, args)
            XCTAssertEqual(error as? ExitCode, .failure, "\(args)")
            XCTAssertEqual(h.io.out, [cliBridgeNotServedReason(.cliPlayQuery)], "\(args)")
            XCTAssertEqual(h.wire.requestCount, 0, "\(args)")
            XCTAssertEqual(calls, [])
        }
    }

    // MARK: - Rows Bridge did not produce (D6)

    /// The shipped `.catalog` writer (Music.app catalogue search) then Bridge
    /// `play 1`: refused, no queue, even though the id is a catalogue id.
    func testAShippedCatalogueRowIsRefusedOnBridge() throws {
        let h = H(.source, ["slice.status": [ready]])
        try h.cache.writeSongs(searchCacheRows([CatalogSong(id: "1440857781", title: "Angel", artist: "Massive Attack",
                                                            album: "Mezzanine")], origin: .catalog))
        let (error, calls) = play(h, ["1"])
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(h.io.out, ["Result 1 came from a Music.app or catalogue listing, so Bridge can't play it by its own id. With Bridge selected, run: music search \"Angel\"  then  music play N"])
        XCTAssertEqual(h.wire.sent("slice.queue").count, 0)
        XCTAssertEqual(calls, [])
    }

    // MARK: - Cross-output

    /// Bridge rows, then Output switches to Music.app: `play 1` is refused
    /// before the resolver, AppleScript, REST or Bridge.
    func testBridgeCatalogueRowsAfterASwitchAreRefusedByMusicApp() throws {
        let h = H(.source, ["slice.status": [ready], "slice.search": [C.mixed]])
        catalogueSearch(h)
        XCTAssertEqual(try h.cache.readSongs().map(\.origin), [.bridgeCatalog, .bridgeCatalog])
        let requestsBefore = h.wire.requestCount

        let switched = H(.musicApp, directory: h.directory)
        var resolves = 0
        let (error, calls) = play(switched, ["1"],
                                  deps: PlayMusicAppDeps(readSongs: { try switched.cache.readSongs() },
                                                         resolveIndexed: { _, _ in resolves += 1 }))
        XCTAssertEqual(error as? ExitCode, .failure)
        XCTAssertEqual(resolves, 0, "never re-resolved by title")
        XCTAssertEqual(calls, [], "no AppleScript, no REST")
        XCTAssertEqual(switched.wire.requestCount, 0)
        XCTAssertEqual(h.wire.requestCount, requestsBefore)
    }

    // MARK: - add and playlist writes (Q3 default: refused; P6A is out)

    private let refusal = "Result(s) 1 came from Bridge. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app."

    private func writeCatalogueRow(_ b: BoundaryHarness) throws {
        try b.cache.writeSongs([SongResult(index: 1, title: "Angel", artist: "Massive Attack", album: "Mezzanine",
                                           catalogId: "", origin: .bridgeCatalog, bridgeID: "1440857781")])
        b.tokens = ("dev", "user")
    }

    func testAddOfABridgeCatalogueRowRefusesBeforeAnyTokenRead() throws {
        for args in [["1"], ["1", "--to", "Mix"]] {
            let b = BoundaryHarness()
            try writeCatalogueRow(b)
            let add = try Add.parse(args)
            let deps = b.deps
            let (captured, calls) = withTripwire { captureStdout { try add.execute(deps: deps) } }
            XCTAssertEqual(captured.output, refusal + "\n", "\(args)")
            XCTAssertEqual(captured.error as? ExitCode, .failure, "\(args)")
            XCTAssertEqual(b.authReads, 0, "\(args)")
            XCTAssertEqual(calls, [], "\(args)")
        }
    }

    func testPlaylistCreateAndAddOfABridgeCatalogueRowRefuseBeforeAnyTokenRead() throws {
        let b1 = BoundaryHarness()
        try writeCatalogueRow(b1)
        let create = try PlaylistCreate.parse(["X", "1"])
        let createDeps = b1.deps
        let (created, createCalls) = withTripwire { captureStdout { try create.execute(deps: createDeps) } }
        XCTAssertEqual(created.output, refusal + "\n")
        XCTAssertEqual(created.error as? ExitCode, .failure)
        XCTAssertEqual(b1.authReads, 0)
        XCTAssertEqual(createCalls, [])

        let b2 = BoundaryHarness()
        try writeCatalogueRow(b2)
        let add = try PlaylistAdd.parse(["X", "1"])
        let addDeps = b2.deps
        let (added, addCalls) = withTripwire { captureStdout { try add.execute(deps: addDeps) } }
        XCTAssertEqual(added.output, refusal + "\n")
        XCTAssertEqual(added.error as? ExitCode, .failure)
        XCTAssertEqual(b2.authReads, 0)
        XCTAssertEqual(addCalls, [])
    }
}
