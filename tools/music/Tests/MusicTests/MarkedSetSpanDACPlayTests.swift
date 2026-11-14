// tools/music/Tests/MusicTests/MarkedSetSpanDACPlayTests.swift
import XCTest
@testable import music

/// Combined play, the SpanDAC route: `p` / `s` with marks made on SpanDAC data
/// read each marked item's songs from SpanDAC on this Mac, in mark order, and
/// play them as ONE queue through the same output branches a single SpanDAC
/// album or playlist play uses: `slice.queue {library_ids}` on a SpanDAC
/// output, the persistent-ID hand-off on the MusicTUI output.
///
/// Every coordinator is the production one over a temp mode.json and
/// data.json (never `~/.config/music`), with fake wires for the DATA client
/// (SpanDAC on this Mac) and every OUTPUT client, so a test can say which side
/// each request reached. The hand-off's identity reads are a fake library and
/// its player a recorder. The AppleScript backend is `AppleScriptCallCounter`'s
/// inert script. Nothing reaches the real SpanDAC socket, Music, osascript, the
/// keychain or `~/.config/music`, and nothing waits on a fixed sleep: every
/// play is waited on with `ActionRunner.waitUntilIdle()`.
final class MarkedSetSpanDACPlayTests: XCTestCase {

    private let frame = shellLayout(width: 120, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    // MARK: - Fixtures

    private let inRainbows = MarkedItem.album(title: "In Rainbows", artist: "Radiohead", id: "al1")
    private let chill = MarkedItem.playlist(id: "pl1", name: "Chill")
    private let amnesiac = MarkedItem.album(title: "Amnesiac", artist: "Radiohead", id: "al2")
    private var mixed: [MarkedItem] { [inRainbows, chill, amnesiac] }
    private let mixedName = "2 albums and 1 playlist"

    /// The read ops a marked play may send, and the play op itself. Nothing
    /// else, on either wire: no write op exists in this set.
    private let readAndPlayOps: Set<String> = ["slice.libraryAlbums", "slice.libraryAlbumTracks",
                                               "slice.libraryPlaylistTracks", "slice.listRev", "slice.queue",
                                               "slice.status"]

    /// The bracket read on either side of the item reads: the first page of
    /// `slice.libraryAlbums`, which carries the SpanDAC process (`library_instance`)
    /// and the core generation the item reads answer.
    private func bracket(instance: String? = "I1", generation: Int = 3) -> String {
        let i = instance.map { ",\"library_instance\":\"\($0)\"" } ?? ""
        return "{\"ok\":true,\"op\":\"slice.libraryAlbums\",\"generation\":\(generation)\(i),\"total\":2,"
            + "\"items\":[{\"id\":\"al1\",\"title\":\"In Rainbows\",\"artist\":\"Radiohead\",\"track_count\":2,"
            + "\"kind\":\"album\"}],\"next_cursor\":\"c2\"}"
    }

    private func song(_ id: String, alias: String? = nil) -> String {
        let a = alias.map { ",\"alias\":\"\($0)\"" } ?? ""
        return "{\"id\":\"\(id)\",\"title\":\"T\(id)\",\"artist\":\"Radiohead\",\"album\":\"A\",\"kind\":\"song\"\(a)}"
    }
    private func albumTracks(_ ids: [String], aliases: [String: String] = [:]) -> String {
        let items = ids.map { song($0, alias: aliases[$0]) }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":3,\"items\":[\(items)]}"
    }
    /// `listRev`: the playlist's `list_rev`, the same on every page of one read
    /// ("pr1" unless a test moves it); nil is a SpanDAC that sends none.
    private func playlistTracks(_ ids: [String], skippedVideos: Int = 0, skippedNotInLibrary: Int = 0,
                                aliases: [String: String] = [:], listRev: String? = "pr1") -> String {
        let items = ids.map { song($0, alias: aliases[$0]) }.joined(separator: ",")
        let rev = listRev.map { ",\"list_rev\":\"\($0)\"" } ?? ""
        // Sent only when more than 0, as SpanDAC sends it (2026-11-07).
        let missing = skippedNotInLibrary > 0 ? ",\"skipped_not_in_library\":\(skippedNotInLibrary)" : ""
        return "{\"ok\":true,\"op\":\"slice.libraryPlaylistTracks\",\"generation\":3,\"total\":\(ids.count),"
            + "\"items\":[\(items)],\"next_cursor\":null,\"skipped_videos\":\(skippedVideos)\(missing)\(rev)}"
    }
    /// `slice.listRev`'s answer for a playlist: its revision, no rows.
    private func revision(_ rev: String = "pr1", count: Int = 2) -> String {
        "{\"ok\":true,\"op\":\"slice.listRev\",\"kind\":\"playlist\",\"list_rev\":\"\(rev)\",\"count\":\(count)}"
    }
    private let queuedStatus = """
    {"ok":true,"op":"slice.status","status":{"playback":"playing","title":"T","artist":"A",
     "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}}}
    """
    private func queued(skippedUnavailable: Int = 0, token: String? = nil) -> String {
        let t = token.map { ",\"queue_token\":\"\($0)\"" } ?? ""
        return """
        {"ok":true,"op":"slice.queue","skipped_unavailable":\(skippedUnavailable)\(t),
         "status":{"playback":"playing","title":"T","artist":"A",
         "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}\(t)}}
        """
    }

    /// The mixed set's SpanDAC reads: In Rainbows (t1, t2), Chill (p1, p2), Amnesiac (t3).
    private func scriptMixedReads(_ r: Rig, aliases: [String: String] = [:]) {
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"], aliases: aliases),
                                                   albumTracks(["t3"], aliases: aliases)])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"], aliases: aliases)])
    }

    // MARK: - Rig

    private enum DataFile { case accepted, missing }

    private struct Rig {
        let routing: RoutingCoordinator
        let data: BridgeLibraryReadsWire
        let output: BridgeLibraryReadsWire
        let counter: AppleScriptCallCounter
        let status: StatusStore
        let actions: ActionRunner
        let library: FakePersistentIDLibrary
        let player: RecordingHandoffQueuePlayer
        let handoff: PersistentIDHandoff

        var spanDAC: MarkedSetSpanDAC {
            let routing = self.routing
            return MarkedSetSpanDAC(makeProvider: { spanDACDataProvider(routing: routing) },
                                    handoff: handoff, sleep: { _ in })
        }
        var opsSent: Set<String> { Set(data.opsInOrder() + output.opsInOrder()) }
    }

    /// `brackets`: script both bracket reads as one unchanged SpanDAC (the same
    /// instance and generation 3); false leaves them to the test. `revisions`:
    /// script the closing revision read of a marked playlist as unchanged ("pr1");
    /// false leaves it to the test.
    private func rig(output mode: PlaybackMode, data file: DataFile = .accepted, brackets: Bool = true,
                     revisions: Bool = true) -> Rig {
        let dir = NSTemporaryDirectory() + "marked-spandac-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let modes = PlaybackModeStore(path: dir + "/mode.json")
        XCTAssertTrue(modes.set(mode))
        let dataStore = DataProviderStore(path: dir + "/data.json")
        if file == .accepted { XCTAssertTrue(dataStore.accept()) }
        let data = BridgeLibraryReadsWire()
        if brackets { data.script("slice.libraryAlbums", [bracket(), bracket()]) }
        if revisions { data.script("slice.listRev", [revision(), revision()]) }
        let output = BridgeLibraryReadsWire()
        output.stickyStatus = true
        // The status read after a queue: the same shape the queue reply carries.
        output.script("slice.status", [queuedStatus])
        let routing = RoutingCoordinator(
            store: modes, surface: .tui, outputLock: nil, dataStore: dataStore,
            makeSourceFor: { _ in
                SourceAppClient(path: "/nonexistent", transport: output.transport, libraryTransport: output.transport)
            },
            makeDataClient: {
                SourceAppClient(path: "/nonexistent", transport: data.transport, libraryTransport: data.transport)
            },
            starter: NeverStartsMacSpanDAC())
        let status = StatusStore()
        let library = FakePersistentIDLibrary()
        let player = RecordingHandoffQueuePlayer()
        let handoff = PersistentIDHandoff(library: library, player: player, selfCheck: LibraryAliasSelfCheck(),
                                          currentStamp: { routing.musicTUISpanDACStamp })
        return Rig(routing: routing, data: data, output: output, counter: AppleScriptCallCounter(),
                   status: status, actions: ActionRunner(status: status), library: library, player: player,
                   handoff: handoff)
    }

    /// The Music.app readers, which a SpanDAC marked play must never ask.
    private func refusingReaders(_ reads: Counter) -> MarkedSetReaders {
        MarkedSetReaders(album: { _, _ in reads.bump(); return .readFailure },
                         playlist: { _ in reads.bump(); return nil })
    }

    private final class Counter {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func play(_ items: [MarkedItem], shuffle: Bool = false, _ r: Rig, reads: Counter = Counter(),
                      source: ListSource = .bridge) {
        let marks = MarkedSetStore()
        for item in items { marks.toggle(item, source: source) }
        let routing = r.routing
        playMarkedSet(marks.snapshot, shuffle: shuffle, backend: r.counter.backend, appQueue: AppQueueStore(),
                      routing: routing, actions: r.actions, status: r.status,
                      spanDACData: { spanDACDataProvider(routing: routing) != nil },
                      readers: refusingReaders(reads), spanDAC: r.spanDAC)
        r.actions.waitUntilIdle()
    }

    // MARK: - One queue, in mark order, on a SpanDAC output

    func testAMixedSetOnSpanDACDataSendsOneQueueInMarkOrder() {
        let r = rig(output: .source)
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        let reads = Counter()
        play(mixed, r, reads: reads)

        let queues = r.output.sent("slice.queue")
        XCTAssertEqual(queues.count, 1, "the marked set is ONE queue")
        XCTAssertEqual(queues.first?["library_ids"] as? [String], ["t1", "t2", "p1", "p2", "t3"], "mark order")
        XCTAssertEqual(queues.first?["start_required"] as? Bool, false, "a whole-set play names no start row")
        XCTAssertNil(queues.first?["skip_not_in_library"], "a marked-set play does not ask the output to skip songs")
        XCTAssertNil(queues.first?["skip_repeated"], "a marked-set play does not ask the output to drop repeats")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty, "the play went to the data client, not the output")
        // Read in mark order, each by the ID its mark recorded, between the two brackets.
        XCTAssertEqual(r.data.opsInOrder(), ["slice.libraryAlbums", "slice.libraryAlbumTracks",
                                             "slice.libraryPlaylistTracks", "slice.libraryAlbumTracks",
                                             "slice.listRev", "slice.libraryAlbums"])
        XCTAssertEqual(r.data.sent("slice.libraryAlbumTracks").map { $0["id"] as? String }, ["al1", "al2"])
        XCTAssertEqual(r.data.sent("slice.libraryPlaylistTracks").first?["id"] as? String, "pl1")
        XCTAssertEqual(r.status.current()?.text, "Playing '\(mixedName)' on SpanDAC \u{2014} 5 tracks.")
        XCTAssertFalse(r.status.current()?.text.contains("needs MusicTUI's own data") ?? false,
                       "the old refusal is gone")
        XCTAssertTrue(r.opsSent.isSubset(of: readAndPlayOps), "a write op was sent: \(r.opsSent)")
        XCTAssertEqual(reads.value, 0, "the MusicTUI-data readers were asked")
        XCTAssertEqual(r.counter.callCount, 0, "AppleScript ran")
        XCTAssertEqual(r.player.queues.count, 0, "the hand-off ran on a SpanDAC output")
    }

    func testShuffleSendsEveryIDOnceInOneQueue() {
        let r = rig(output: .source)
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, shuffle: true, r)

        let queues = r.output.sent("slice.queue")
        XCTAssertEqual(queues.count, 1)
        let ids = queues.first?["library_ids"] as? [String] ?? []
        XCTAssertEqual(ids.sorted(), ["p1", "p2", "t1", "t2", "t3"], "a shuffle keeps every ID, once")
        XCTAssertEqual(queues.first?["start_required"] as? Bool, false)
        XCTAssertTrue(r.opsSent.isSubset(of: readAndPlayOps))
    }

    func testAnIPhoneOutputGetsTheSameOneQueue() {
        let r = rig(output: .networkSource("0E6A3F6C-4B51-4D1B-9E1E-5C2A8D3B7F10"))
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.output.sent("slice.queue").map { $0["library_ids"] as? [String] },
                       [["t1", "t2", "p1", "p2", "t3"]])
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertTrue(r.output.opsInOrder().allSatisfy { $0 == "slice.queue" || $0 == "slice.status" },
                      "the iPhone's library was read: \(r.output.opsInOrder())")
    }

    // MARK: - Fails whole

    func testOneFailedReadFailsTheWholePlay() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"]), albumTracks(["t3"])])
        r.data.script("slice.libraryPlaylistTracks", [
            #"{"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"not_in_library","detail":"That playlist isn't in your library any more."}}"#,
        ])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text,
                       "Couldn't read 'Chill' from SpanDAC, so nothing played: That playlist isn't in your library any more.")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a partial queue was sent")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.data.sent("slice.libraryAlbumTracks").count, 1, "reads go on after the first failure")
        XCTAssertTrue(r.opsSent.isSubset(of: readAndPlayOps))
    }

    func testAnEmptyItemFailsTheWholePlay() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1"]), albumTracks([])])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1"])])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text, "'Amnesiac' has no songs SpanDAC can play, so nothing played.")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
    }

    // MARK: - The request frame

    /// Measured, not assumed: what one library ID costs in a `slice.queue`
    /// request, and the largest set that still fits the 64 KiB frame.
    func testTheQueueRequestSizeIsMeasuredExactly() {
        let id = "i.geOG9Cp2Olb6"   // SpanDAC's own documented example, 14 characters
        let none = SourceAppControl.libraryQueueRequestBytes(libraryIDs: [], startRequired: false)
        let one = SourceAppControl.libraryQueueRequestBytes(libraryIDs: [id], startRequired: false)
        let two = SourceAppControl.libraryQueueRequestBytes(libraryIDs: [id, id], startRequired: false)
        XCTAssertEqual(one - none, 16, "an ID and its quotes")
        XCTAssertEqual(two - one, 17, "each further ID adds its comma")
        let fits = (SourceAppControl.maximumRequestBytes - one) / 17 + 1
        XCTAssertLessThanOrEqual(
            SourceAppControl.libraryQueueRequestBytes(libraryIDs: Array(repeating: id, count: fits), startRequired: false),
            SourceAppControl.maximumRequestBytes)
        XCTAssertGreaterThan(
            SourceAppControl.libraryQueueRequestBytes(libraryIDs: Array(repeating: id, count: fits + 1), startRequired: false),
            SourceAppControl.maximumRequestBytes)
    }

    func testASetOverTheRequestFrameRefusesAndSendsNothing() {
        let r = rig(output: .source)
        let big = (0..<4_000).map { String(format: "i.%012d", $0) }
        r.data.script("slice.libraryAlbumTracks", [albumTracks(Array(big.prefix(3_000))), albumTracks(Array(big.suffix(999)))])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1"])])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text,
                       "4,000 songs are more than SpanDAC can take in one queue, so nothing played. Mark fewer albums or playlists.")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a set over the frame was sent, or truncated")
        XCTAssertTrue(r.output.requestCount == 0, "the output was asked anything")
    }

    // MARK: - Partly available

    func testSkippedSongsAndVideosCarryTheAvailabilityLine() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"]), albumTracks(["t3"])])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"], skippedVideos: 2)])
        r.output.script("slice.queue", [queued(skippedUnavailable: 1)])
        play(mixed, r)

        // 5 IDs sent, 1 skipped by SpanDAC, 2 videos never sent: 4 of 7, worded as
        // the single SpanDAC playlist play words it (`bridgePlaylistPlayMessage`):
        // the videos apart from the song SpanDAC can't play.
        XCTAssertEqual(r.status.current()?.text,
                       "Playing 4 of 7 from '\(mixedName)' on SpanDAC: 2 videos skipped. 1 song isn't available to SpanDAC.")
        XCTAssertEqual(r.status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange, true)
    }

    // MARK: - An accepted queue whose follow-up status read fails

    /// Plays the mixed set on a SpanDAC output whose `slice.status` answers until the queue is
    /// served and `statusAfterQueue` after it.
    private func playMixedWithStatusFailingAfterTheQueue(_ statusAfterQueue: String, skippedVideos: Int = 0,
                                                         skippedNotInLibrary: Int = 0) -> Rig {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"]), albumTracks(["t3"])])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"], skippedVideos: skippedVideos,
                                                                     skippedNotInLibrary: skippedNotInLibrary)])
        r.output.script("slice.queue", [queued(skippedUnavailable: 1, token: "tok-1")])
        var queueServed = false
        r.output.handler = { op, _ in
            if op == "slice.queue" { queueServed = true; return nil }
            return op == "slice.status" && queueServed ? statusAfterQueue : nil
        }
        play(mixed, r)
        return r
    }

    func testAnAcceptedMarkedQueueWhoseStatusReadFailsKeepsItsCountsAndSendsTheQueueOnce() {
        let r = playMixedWithStatusFailingAfterTheQueue(
            #"{"ok":false,"op":"slice.status","error":{"kind":"player_disconnected","detail":"the player stopped answering"}}"#,
            skippedVideos: 2, skippedNotInLibrary: 3)
        XCTAssertEqual(r.output.sent("slice.queue").count, 1, "an accepted queue is never sent again")
        XCTAssertEqual(r.status.current()?.text,
                       "Play was requested, but SpanDAC didn't confirm '\(mixedName)' started."
                       + " \u{00B7} skipped 3 songs not in your library 2 videos skipped. 1 song isn't available to SpanDAC.")
        XCTAssertEqual(r.status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange, true)
        XCTAssertEqual(r.routing.spanDACPlay()?.token, "tok-1")
        XCTAssertEqual(r.routing.spanDACPlay()?.rows.count, 5)
    }

    func testAnAcceptedMarkedQueueWhoseStatusIsWarmingIsNotSentAgain() {
        let r = playMixedWithStatusFailingAfterTheQueue(
            #"{"ok":false,"op":"slice.status","error":{"kind":"warming","detail":"preparing your library","retry_after":0}}"#)
        XCTAssertEqual(r.output.sent("slice.queue").count, 1, "a status that is warming must not re-send an accepted queue")
        XCTAssertEqual(r.status.current()?.text,
                       "Play was requested, but SpanDAC didn't confirm '\(mixedName)' started. 1 song isn't available to SpanDAC.")
    }

    /// Playlist-only songs (Anthony, 2026-11-07): SpanDAC leaves them out of the
    /// playlist's rows and says how many. They are never sent, and the play line
    /// says they were skipped, ahead of the songs SpanDAC cannot play.
    func testPlaylistOnlySongsSpanDACSkippedAreSaidInTheMarkedPlayLine() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"]), albumTracks(["t3"])])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"], skippedNotInLibrary: 3)])
        r.output.script("slice.queue", [queued(skippedUnavailable: 1)])
        play(mixed, r)

        XCTAssertEqual(r.output.sent("slice.queue").count, 1)
        XCTAssertEqual(r.status.current()?.text,
                       "Skipped 3 not in your library \u{00B7} Playing '\(mixedName)' on SpanDAC \u{2014} 4 tracks. "
                       + "1 song isn't available to SpanDAC.")
        XCTAssertEqual(r.status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange, true)
    }

    func testTwoMarkedPlaylistsAddTheirPlaylistOnlySongs() {
        let r = rig(output: .source)
        let other = MarkedItem.playlist(id: "pl2", name: "Other")
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1"], skippedNotInLibrary: 1),
                                                      playlistTracks(["p2"], skippedNotInLibrary: 2)])
        r.data.script("slice.listRev", [revision(), revision()])
        r.output.script("slice.queue", [queued()])
        play([chill, other], r)
        XCTAssertEqual(r.status.current()?.text,
                       "Skipped 3 not in your library \u{00B7} Playing '2 playlists' on SpanDAC \u{2014} 2 tracks.")
    }

    // MARK: - The MusicTUI output: the hand-off

    private let aliases = ["t1": "1", "t2": "2", "p1": "3", "p2": "4", "t3": "5"]
    private func hex(_ alias: String) -> String { persistentIDHex(fromAlias: alias)! }
    /// The identity read's answer: each row's alias found once in the library.
    private func handoffHits(_ rows: [(id: String, alias: String)]) -> [String: [HandoffTrackHit]] {
        Dictionary(uniqueKeysWithValues: rows.map { row in
            (hex(row.alias), [HandoffTrackHit(persistentID: hex(row.alias), inLibrary: true, databaseID: "db\(row.alias)",
                                              libraryIndex: Int(row.alias)!, name: "T\(row.id)")])
        })
    }
    private let allRows: [(id: String, alias: String)] = [("t1", "1"), ("t2", "2"), ("p1", "3"), ("p2", "4"), ("t3", "5")]

    func testOnTheMusicTUIOutputTheSetIsOneAppQueueInMarkOrder() {
        let r = rig(output: .musicApp)
        scriptMixedReads(r, aliases: aliases)
        r.library.hits = handoffHits(allRows)
        play(mixed, r)

        XCTAssertEqual(r.player.queues.count, 1, "the hand-off built one queue: \(String(describing: r.status.current()?.text))")
        guard let q = r.player.queues.first else { return }
        XCTAssertEqual(q.playlistName, persistentIDQueueSource)
        XCTAssertEqual(q.displayName, mixedName)
        XCTAssertEqual(q.currentIndex, 1)
        XCTAssertEqual(q.tracks.map { persistentIDOfQueueEntry($0.index) }, ["1", "2", "3", "4", "5"].map(hex),
                       "mark order")
        XCTAssertEqual(r.library.reads.count, 1, "one identity read for the whole set")
        XCTAssertEqual(r.status.current()?.text, LibraryProvenance.playingOnMusicTUI(mixedName))
        XCTAssertEqual(r.output.requestCount, 0, "a SpanDAC output was asked")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty, "a SpanDAC queue was sent for the MusicTUI output")
        XCTAssertTrue(r.opsSent.isSubset(of: readAndPlayOps))
        XCTAssertEqual(r.counter.callCount, 0)
    }

    func testOnTheMusicTUIOutputAShuffleKeepsEveryEntry() {
        let r = rig(output: .musicApp)
        scriptMixedReads(r, aliases: aliases)
        r.library.hits = handoffHits(allRows)
        play(mixed, shuffle: true, r)

        XCTAssertEqual(r.player.queues.count, 1)
        XCTAssertEqual(r.player.queues.first?.tracks.map { persistentIDOfQueueEntry($0.index) }.sorted(),
                       ["1", "2", "3", "4", "5"].map(hex).sorted())
    }

    func testOnTheMusicTUIOutputAnUnavailableSongCarriesTheAvailabilityLine() {
        let r = rig(output: .musicApp)
        var some = aliases
        some["p2"] = nil   // SpanDAC gave this song no identity
        scriptMixedReads(r, aliases: some)
        r.library.hits = handoffHits(allRows.filter { $0.id != "p2" })
        play(mixed, r)

        XCTAssertEqual(r.player.queues.first?.tracks.count, 4)
        // The hand-off's own wording, as a single SpanDAC album or playlist play
        // on the MusicTUI output words it.
        XCTAssertEqual(r.status.current()?.text,
                       "Playing '\(mixedName)' on MusicTUI. 1 song isn't available to SpanDAC.")
    }

    // MARK: - One snapshot for the whole set

    private func albumTracks(_ ids: [String], generation: Int, aliases: [String: String] = [:]) -> String {
        albumTracks(ids, aliases: aliases).replacingOccurrences(of: "\"generation\":3", with: "\"generation\":\(generation)")
    }
    private func playlistTracks(_ ids: [String], generation: Int, nextCursor: String? = nil,
                                listRev: String? = "pr1") -> String {
        var page = playlistTracks(ids, listRev: listRev)
            .replacingOccurrences(of: "\"generation\":3", with: "\"generation\":\(generation)")
        if let nextCursor {
            page = page.replacingOccurrences(of: "\"next_cursor\":null", with: "\"next_cursor\":\"\(nextCursor)\"")
        }
        return page
    }
    private var changedLine: String {
        "SpanDAC's library changed while '\(mixedName)' was being read, so nothing played. Try again."
    }

    /// A refresh lands between two marked items: the playlist answers a newer
    /// snapshot than the album before it. Nothing is queued, and the reads stop.
    func testARefreshBetweenTwoItemsRefusesAndSendsNoQueue() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"], generation: 3),
                                                   albumTracks(["t3"], generation: 4)])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"], generation: 4)])
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text, changedLine)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a queue mixing two snapshots was sent")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.data.sent("slice.libraryAlbumTracks").count, 1, "reads went on after the snapshot moved")
        XCTAssertTrue(r.opsSent.isSubset(of: readAndPlayOps))
    }

    /// The same between two albums, on the MusicTUI output: no hand-off.
    func testARefreshBetweenTwoAlbumsRefusesOnTheMusicTUIOutput() {
        let r = rig(output: .musicApp)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"], generation: 3, aliases: aliases),
                                                   albumTracks(["t3"], generation: 4, aliases: aliases)])
        r.library.hits = handoffHits(allRows)
        play([inRainbows, amnesiac], r)

        XCTAssertEqual(r.status.current()?.text,
                       "SpanDAC's library changed while '2 albums' was being read, so nothing played. Try again.")
        XCTAssertEqual(r.player.queues.count, 0, "a hand-off mixing two snapshots played")
        XCTAssertEqual(r.library.reads.count, 0)
    }

    /// A playlist whose walk restarted onto a newer snapshot, after an album was
    /// read on the older one: the restarted pages are not the album's snapshot.
    func testAPlaylistWalkThatRestartsOntoANewSnapshotRefuses() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"], generation: 3)])
        r.data.script("slice.libraryPlaylistTracks", [
            playlistTracks(["p1"], generation: 3, nextCursor: "c2"),
            #"{"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"stale_generation","detail":"That playlist changed while you were reading it; start again."}}"#,
            playlistTracks(["p1", "p2"], generation: 4),
        ])
        r.output.script("slice.queue", [queued()])
        play([inRainbows, chill], r)

        XCTAssertEqual(r.status.current()?.text,
                       "SpanDAC's library changed while '1 album and 1 playlist' was being read, so nothing played. Try again.")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
    }

    // MARK: - A switch while a request is held

    private let iPhone = PlaybackMode.networkSource("0E6A3F6C-4B51-4D1B-9E1E-5C2A8D3B7F10")

    private func until(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    /// Starts the play without waiting, holds the `n`th request of `op`, switches
    /// the output while it is held, then lets it answer.
    private func switchWhileHeld(_ r: Rig, _ items: [MarkedItem], op: String, at n: Int = 0) throws {
        r.data.gate(op: op, at: n)
        let marks = MarkedSetStore()
        for item in items { marks.toggle(item, source: .bridge) }
        let routing = r.routing
        playMarkedSet(marks.snapshot, shuffle: false, backend: r.counter.backend, appQueue: AppQueueStore(),
                      routing: routing, actions: r.actions, status: r.status,
                      spanDACData: { spanDACDataProvider(routing: routing) != nil },
                      readers: refusingReaders(Counter()), spanDAC: r.spanDAC)
        XCTAssertTrue(until { r.data.reached(op: op, at: n) }, "the play never sent \(op)")
        let switched = try r.routing.switchMode(to: iPhone, readiness: { .ready },
                                                pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(switched, .switched(to: iPhone))
        r.data.release(op: op, at: n)
        r.actions.waitUntilIdle()
    }

    /// The album read answers `warming` while the output switches: the retry is
    /// never sent, nor any later read, and nothing plays.
    func testASwitchWhileAWarmingAlbumReadIsHeldSendsNothingMore() throws {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [
            #"{"ok":false,"op":"slice.libraryAlbumTracks","error":{"kind":"warming","detail":"preparing your library","retry_after":0}}"#,
            albumTracks(["t1", "t2"]), albumTracks(["t3"]),
        ])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"])])
        r.output.script("slice.queue", [queued()])
        try switchWhileHeld(r, mixed, op: "slice.libraryAlbumTracks")

        XCTAssertEqual(r.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(r.data.sent("slice.libraryAlbumTracks").count, 1, "the warming read was retried after the switch")
        XCTAssertTrue(r.data.sent("slice.libraryPlaylistTracks").isEmpty)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
    }

    /// The first page of a playlist answers, with more to come, while the output
    /// switches: the next page is never asked for, and nothing plays.
    func testASwitchWhileTheFirstPlaylistPageIsHeldSendsNothingMore() throws {
        let r = rig(output: .source)
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1"], generation: 3, nextCursor: "c2"),
                                                      playlistTracks(["p2"], generation: 3)])
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"])])
        r.output.script("slice.queue", [queued()])
        try switchWhileHeld(r, [chill, inRainbows], op: "slice.libraryPlaylistTracks")

        XCTAssertEqual(r.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(r.data.sent("slice.libraryPlaylistTracks").count, 1, "the next page was read after the switch")
        XCTAssertTrue(r.data.sent("slice.libraryAlbumTracks").isEmpty)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
    }

    // MARK: - One SpanDAC process: the bracket reads

    /// The item reads are bracketed by two one-row `slice.libraryAlbums` reads,
    /// the first before any item and the second after the last, before the queue.
    func testTheReadsAreBracketedByTwoOneRowAlbumPages() {
        let r = rig(output: .source)
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.data.opsInOrder(), ["slice.libraryAlbums", "slice.libraryAlbumTracks",
                                             "slice.libraryPlaylistTracks", "slice.libraryAlbumTracks",
                                             "slice.listRev", "slice.libraryAlbums"])
        let brackets = r.data.sent("slice.libraryAlbums")
        XCTAssertEqual(brackets.count, 2)
        for body in brackets {
            XCTAssertEqual(Set(body.keys), ["op", "limit"], "a bracket asks for more than one first-page row: \(body)")
            XCTAssertEqual(body["limit"] as? Int, 1)
        }
        XCTAssertEqual(r.output.sent("slice.queue").count, 1)
    }

    /// SpanDAC restarted between the brackets and reused generation 3: every read
    /// answered 3, but the second bracket names another process. Nothing plays.
    func testARestartThatReusesTheGenerationRefuses() {
        let r = rig(output: .source, brackets: false)
        r.data.script("slice.libraryAlbums", [bracket(instance: "I1"), bracket(instance: "I2")])
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text, changedLine)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a queue read across two SpanDAC processes was sent")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.output.requestCount, 0, "the output was asked")
    }

    func testARestartThatReusesTheGenerationRefusesOnTheMusicTUIOutput() {
        let r = rig(output: .musicApp, brackets: false)
        r.data.script("slice.libraryAlbums", [bracket(instance: "I1"), bracket(instance: "I2")])
        scriptMixedReads(r, aliases: aliases)
        r.library.hits = handoffHits(allRows)
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text, changedLine)
        XCTAssertEqual(r.player.queues.count, 0, "a hand-off read across two SpanDAC processes played")
        XCTAssertEqual(r.library.reads.count, 0)
    }

    /// A refresh after the last item read, before the queue: the second bracket
    /// answers a newer generation. Nothing plays.
    func testAGenerationChangeAfterTheLastReadRefuses() {
        let r = rig(output: .source, brackets: false)
        r.data.script("slice.libraryAlbums", [bracket(generation: 3), bracket(generation: 4)])
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text, changedLine)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a queue read before a refresh was sent after it")
        XCTAssertEqual(r.output.requestCount, 0)
    }

    /// The first bracket names the snapshot: an item read that answers another
    /// generation refuses, and the reads stop there.
    func testAFirstItemReadOnAnotherGenerationThanTheFirstBracketRefuses() {
        let r = rig(output: .source, brackets: false)
        r.data.script("slice.libraryAlbums", [bracket(generation: 2), bracket(generation: 3)])
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text, changedLine)
        XCTAssertEqual(r.data.opsInOrder(), ["slice.libraryAlbums", "slice.libraryAlbumTracks"],
                       "reads went on after the first item answered another generation")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
    }

    /// A SpanDAC whose album page names no process cannot show that one process
    /// served the whole set: refused, before any item is read.
    func testABracketWithoutAnInstanceRefuses() {
        let r = rig(output: .source, brackets: false)
        r.data.script("slice.libraryAlbums", [bracket(instance: nil), bracket(instance: nil)])
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text,
                       "This SpanDAC build can't confirm '\(mixedName)' was read from one library, so nothing played. "
                           + "Update SpanDAC.")
        XCTAssertEqual(r.data.opsInOrder(), ["slice.libraryAlbums"], "an item was read")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
    }

    /// A bracket that answers `warming` is retried inside the play's budget.
    func testAWarmingBracketIsRetried() {
        let r = rig(output: .source, brackets: false)
        r.data.script("slice.libraryAlbums", [
            #"{"ok":false,"op":"slice.libraryAlbums","error":{"kind":"warming","detail":"preparing your library","retry_after":0}}"#,
            bracket(), bracket(),
        ])
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2", "p1", "p2", "t3"])
        XCTAssertEqual(r.data.sent("slice.libraryAlbums").count, 3)
    }

    /// The first bracket is held while the output switches: no item is read, and
    /// nothing plays.
    func testASwitchWhileTheFirstBracketIsHeldSendsNothingMore() throws {
        let r = rig(output: .source)
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        try switchWhileHeld(r, mixed, op: "slice.libraryAlbums", at: 0)

        XCTAssertEqual(r.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(r.data.opsInOrder(), ["slice.libraryAlbums"], "an item was read after the switch")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
    }

    /// The second bracket is held while the output switches: nothing is queued,
    /// on the old output or the new one.
    func testASwitchWhileTheSecondBracketIsHeldQueuesNothing() throws {
        let r = rig(output: .source)
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        try switchWhileHeld(r, mixed, op: "slice.libraryAlbums", at: 1)

        XCTAssertEqual(r.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(r.data.sent("slice.libraryAlbums").count, 2)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
    }

    // MARK: - One revision of each marked playlist

    private let setOfTwo = "1 album and 1 playlist"
    private var setOfTwoChangedLine: String {
        "SpanDAC's library changed while '\(setOfTwo)' was being read, so nothing played. Try again."
    }

    /// A playlist edit between two pages: SpanDAC's generation stays 3 (a
    /// playlist's membership is read live), but the second page answers another
    /// `list_rev`. Nothing plays, and nothing is read after that page.
    func testARevisionChangeBetweenPagesWithTheGenerationUnchangedRefuses() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"])])
        r.data.script("slice.libraryPlaylistTracks", [
            playlistTracks(["p1"], generation: 3, nextCursor: "c2", listRev: "pr1"),
            playlistTracks(["p2"], generation: 3, listRev: "pr2"),
        ])
        r.output.script("slice.queue", [queued()])
        play([inRainbows, chill], r)

        XCTAssertEqual(r.status.current()?.text, setOfTwoChangedLine)
        XCTAssertEqual(r.data.opsInOrder(), ["slice.libraryAlbums", "slice.libraryAlbumTracks",
                                             "slice.libraryPlaylistTracks", "slice.libraryPlaylistTracks"],
                       "reads went on after the playlist's revision moved")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a queue of a mixed playlist was sent")
        XCTAssertEqual(r.output.requestCount, 0)
    }

    /// A restart of the playlist's walk is a change too, even when the restarted
    /// pages answer the same generation and revision as the first bracket.
    func testARestartedPlaylistWalkRefusesEvenOnTheSameGeneration() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"])])
        r.data.script("slice.libraryPlaylistTracks", [
            playlistTracks(["p1"], generation: 3, nextCursor: "c2"),
            #"{"ok":false,"op":"slice.libraryPlaylistTracks","error":{"kind":"stale_generation","detail":"That playlist changed while you were reading it; start again."}}"#,
            playlistTracks(["p1", "p2"], generation: 3),
        ])
        r.output.script("slice.queue", [queued()])
        play([inRainbows, chill], r)

        XCTAssertEqual(r.status.current()?.text, setOfTwoChangedLine)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a restarted walk was played")
        XCTAssertTrue(r.data.sent("slice.listRev").isEmpty)
    }

    /// A playlist edit after its last page, before the queue: the walk agreed
    /// with itself, the generation never moved, but the revision read before the
    /// closing bracket answers another `list_rev`. Nothing plays.
    func testARevisionChangeAfterTheLastPageRefuses() {
        let r = rig(output: .source, revisions: false)
        scriptMixedReads(r)
        r.data.script("slice.listRev", [revision("pr2")])
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text, changedLine)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a queue of a playlist that changed was sent")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.output.requestCount, 0, "the output was asked")
        XCTAssertEqual(r.data.sent("slice.libraryAlbums").count, 1, "the closing bracket was read after a refusal")
    }

    func testARevisionChangeAfterTheLastPageRefusesOnTheMusicTUIOutput() {
        let r = rig(output: .musicApp, revisions: false)
        scriptMixedReads(r, aliases: aliases)
        r.data.script("slice.listRev", [revision("pr2")])
        r.library.hits = handoffHits(allRows)
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text, changedLine)
        XCTAssertEqual(r.player.queues.count, 0, "a hand-off of a playlist that changed played")
        XCTAssertEqual(r.library.reads.count, 0)
    }

    /// A SpanDAC that sends no `list_rev` on a playlist page cannot show the
    /// pages are one list: refused with the bracket's update line, before the
    /// revision read or the closing bracket.
    func testAPlaylistPageWithoutARevisionRefusesWithTheUpdateLine() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"])])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"], listRev: nil)])
        r.output.script("slice.queue", [queued()])
        play([inRainbows, chill], r)

        XCTAssertEqual(r.status.current()?.text,
                       "This SpanDAC build can't confirm '\(setOfTwo)' was read from one library, so nothing played. "
                           + "Update SpanDAC.")
        XCTAssertTrue(r.data.sent("slice.listRev").isEmpty)
        XCTAssertEqual(r.data.sent("slice.libraryAlbums").count, 1)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
    }

    /// A SpanDAC whose pages carry `list_rev` but which does not serve the
    /// revision read (`unknown_op`): the same update line, and nothing plays.
    func testASpanDACWithoutTheRevisionReadRefusesWithTheUpdateLine() {
        let r = rig(output: .source, revisions: false)
        scriptMixedReads(r)
        r.data.script("slice.listRev", [
            #"{"ok":false,"op":"slice.listRev","error":{"kind":"unknown_op","detail":"unknown op slice.listRev"}}"#,
        ])
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.status.current()?.text,
                       "This SpanDAC build can't confirm '\(mixedName)' was read from one library, so nothing played. "
                           + "Update SpanDAC.")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.output.requestCount, 0)
    }

    /// An unchanged revision plays as before: every page and the revision read
    /// agree, and the revision read is the smallest one there is, one
    /// `slice.listRev` of the playlist by its ID, no rows, sent after the last
    /// item read and before the closing bracket.
    func testAnUnchangedRevisionPlaysAsBefore() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"])])
        r.data.script("slice.libraryPlaylistTracks", [
            playlistTracks(["p1"], generation: 3, nextCursor: "c2"),
            playlistTracks(["p2"], generation: 3),
        ])
        r.output.script("slice.queue", [queued()])
        play([inRainbows, chill], r)

        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2", "p1", "p2"])
        XCTAssertEqual(r.status.current()?.text, "Playing '\(setOfTwo)' on SpanDAC \u{2014} 4 tracks.")
        XCTAssertEqual(r.data.opsInOrder(), ["slice.libraryAlbums", "slice.libraryAlbumTracks",
                                             "slice.libraryPlaylistTracks", "slice.libraryPlaylistTracks",
                                             "slice.listRev", "slice.libraryAlbums"])
        let asked = r.data.sent("slice.listRev")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?["op"] as? String, "slice.listRev")
        XCTAssertEqual(asked.first?["kind"] as? String, "playlist")
        XCTAssertEqual(asked.first?["id"] as? String, "pl1")
        // The marked playlist's revision describes the list the set read (the TUI
        // asks SpanDAC to skip songs that are not in the library), so it says so.
        XCTAssertEqual(asked.first.map { Set($0.keys) }, ["op", "kind", "id", "skip_not_in_library"])
        XCTAssertEqual(asked.first?["skip_not_in_library"] as? Bool, true)
        XCTAssertTrue(r.opsSent.isSubset(of: readAndPlayOps))
    }

    /// Only playlists are revalidated: a set of albums sends no revision read.
    func testASetOfAlbumsSendsNoRevisionRead() {
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"]), albumTracks(["t3"])])
        r.output.script("slice.queue", [queued()])
        play([inRainbows, amnesiac], r)

        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2", "t3"])
        XCTAssertTrue(r.data.sent("slice.listRev").isEmpty)
    }

    /// The revision read answers `warming`: retried inside the play's budget,
    /// then the set plays.
    func testAWarmingRevisionReadIsRetried() {
        let r = rig(output: .source, revisions: false)
        scriptMixedReads(r)
        r.data.script("slice.listRev", [
            #"{"ok":false,"op":"slice.listRev","error":{"kind":"warming","detail":"preparing your library","retry_after":0}}"#,
            revision(),
        ])
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2", "p1", "p2", "t3"])
        XCTAssertEqual(r.data.sent("slice.listRev").count, 2)
    }

    /// The revision read is held while the output switches: the closing bracket
    /// is never read and nothing is queued, on the old output or the new one.
    func testASwitchWhileTheRevisionReadIsHeldQueuesNothing() throws {
        let r = rig(output: .source)
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        try switchWhileHeld(r, mixed, op: "slice.listRev")

        XCTAssertEqual(r.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(r.data.sent("slice.listRev").count, 1)
        XCTAssertEqual(r.data.sent("slice.libraryAlbums").count, 1, "the closing bracket was read after the switch")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
    }

    /// A warming revision read is held while the output switches: its retry is
    /// never sent.
    func testASwitchWhileAWarmingRevisionReadIsHeldSendsNoRetry() throws {
        let r = rig(output: .source, revisions: false)
        scriptMixedReads(r)
        r.data.script("slice.listRev", [
            #"{"ok":false,"op":"slice.listRev","error":{"kind":"warming","detail":"preparing your library","retry_after":0}}"#,
            revision(),
        ])
        r.output.script("slice.queue", [queued()])
        try switchWhileHeld(r, mixed, op: "slice.listRev")

        XCTAssertEqual(r.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(r.data.sent("slice.listRev").count, 1, "the warming revision read was retried after the switch")
        XCTAssertEqual(r.data.sent("slice.libraryAlbums").count, 1)
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty)
    }

    // MARK: - Up Next after SpanDAC skipped a song

    /// The status SpanDAC answers after the play: `row` and `next_rows` are
    /// indexes into the request MusicTUI sent, so a skipped song shifts nothing.
    private func playingStatus(row: Int, title: String, nextRows: [Int]?, token: String) -> String {
        let next = nextRows.map { ",\"next_rows\":[\($0.map(String.init).joined(separator: ","))]" } ?? ""
        return """
        {"ok":true,"op":"slice.status","status":{"playback":"playing","title":"\(title)","artist":"Radiohead",
         "contract":3,"authorization":"authorized","capabilities":["slice.status","queue.jump"],
         "row":\(row)\(next),"queue_token":"\(token)",
         "queue":{"phase":"complete","requested":4,"present":4,"index":\(row)}}}
        """
    }

    /// The mixed set with p1 (request index 2) skipped by SpanDAC, played.
    private func playWithAMiddleSkip() -> (Rig, SourceAppClient) {
        let r = rig(output: .source)
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued(skippedUnavailable: 1, token: "tok-1")])
        play(mixed, r)
        return (r, SourceAppClient(path: "/nonexistent", transport: r.output.transport,
                                   libraryTransport: r.output.transport))
    }

    /// With `next_rows`, Up Next is what SpanDAC vouched for, and a jump to a row
    /// after the skipped song asks SpanDAC for THAT song's request index.
    func testAJumpAfterAMiddleSkipTargetsTheSongShown() throws {
        let (r, client) = playWithAMiddleSkip()
        r.output.script("slice.status", [playingStatus(row: 0, title: "Tt1", nextRows: [1, 3, 4], token: "tok-1")])
        let status = try client.control.status()
        let play = try XCTUnwrap(r.routing.spanDACPlay())
        let entries = spanDACQueueWindow(sent: play.rows, token: play.token, sentOrderUnreliable: play.sentOrderUnreliable,
                                         status: status).entries
        XCTAssertEqual(entries.map(\.name), ["Tt1", "Tt2", "Tp2", "Tt3"], "the skipped song is listed")
        let target = try XCTUnwrap(entries.first { $0.name == "Tp2" })
        r.output.script("slice.queueJump", [
            #"{"ok":true,"op":"slice.queueJump","status":{"playback":"playing","title":"Tp2","artist":"Radiohead","contract":3,"authorization":"authorized","row":3,"next_rows":[4],"queue_token":"tok-1"},"queue_token":"tok-1"}"#,
        ])
        _ = try jumpSpanDACQueue(routing: r.routing, client: client, displayedToken: "tok-1", entryIndex: target.index)
        let row = try XCTUnwrap(r.output.sent("slice.queueJump").first?["row"] as? Int)
        XCTAssertEqual(play.rows[row].id, "p2", "the jump asked for another song than the one shown")
    }

    /// Without `next_rows`, the sent order would stand in for SpanDAC's, and it
    /// still holds the song SpanDAC skipped: nothing after the playing row is
    /// listed, so no jump can be aimed at a row SpanDAC never queued.
    func testWithoutNextRowsAPlayWithASkipListsNothingToJumpTo() throws {
        let (r, client) = playWithAMiddleSkip()
        r.output.script("slice.status", [playingStatus(row: 0, title: "Tt1", nextRows: nil, token: "tok-1")])
        let status = try client.control.status()
        let play = try XCTUnwrap(r.routing.spanDACPlay())
        let entries = spanDACQueueWindow(sent: play.rows, token: play.token, sentOrderUnreliable: play.sentOrderUnreliable,
                                         status: status).entries
        XCTAssertEqual(entries.map(\.name), ["Tt1"], "rows SpanDAC did not vouch for were listed")
    }

    // MARK: - The whole set's notice through the hand-off's confirmation

    /// A mixed set with a playlist video left out and a song SpanDAC gave no
    /// identity, through the real hand-off, the shell's player and a confirmer.
    /// Music does not confirm at first (the warning), then confirms late (the
    /// line comes back): both keep the video and the song.
    func testTheSetsNoticeSurvivesAnUnconfirmedAndALateConfirmedHandoff() throws {
        let r = rig(output: .musicApp)
        var some = aliases
        some["t3"] = nil   // SpanDAC gave this song no identity
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"], aliases: some),
                                                   albumTracks(["t3"], aliases: some)])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"], skippedVideos: 1, aliases: some)])
        r.library.hits = handoffHits(allRows.filter { $0.id != "t3" })
        let first = hex("1")
        let confirm = HonestPlayingTests.ConfirmRig([PlayerIdentityReading(state: "paused", persistentID: "00000000000000A1",
                                                                           requestedID: nil)],
                                                    status: r.status)
        confirm.onRead = { n in
            if n == 9 { confirm.setReadings([PlayerIdentityReading(state: "playing", persistentID: first, requestedID: nil)]) }
        }
        let store = AppQueueStore()
        store.confirmer = confirm.confirmer
        let routing = r.routing
        let handoff = PersistentIDHandoff(
            library: r.library,
            player: AppQueueHandoffPlayer(store: store,
                                          playFirst: requestedHandoffPlayFirst(backend: r.counter.backend, appQueue: store)),
            selfCheck: LibraryAliasSelfCheck(), currentStamp: { routing.musicTUISpanDACStamp })
        let marks = MarkedSetStore()
        for item in mixed { marks.toggle(item, source: .bridge) }
        playMarkedSet(marks.snapshot, shuffle: false, backend: r.counter.backend, appQueue: store,
                      routing: routing, actions: r.actions, status: r.status,
                      spanDACData: { spanDACDataProvider(routing: routing) != nil },
                      readers: refusingReaders(Counter()),
                      spanDAC: MarkedSetSpanDAC(makeProvider: { spanDACDataProvider(routing: routing) },
                                                handoff: handoff, sleep: { _ in }))
        r.actions.waitUntilIdle()
        let notice = "1 video skipped. 1 song isn't available to SpanDAC."
        let line = "Playing '\(mixedName)' on MusicTUI. \(notice)"
        XCTAssertEqual(r.status.current()?.text, line, "the play's own line")
        XCTAssertEqual(store.read()?.tracks.count, 4)

        confirm.runJobs()
        XCTAssertEqual(confirm.posts, [playNotStartedWarning(mixedName) + " " + notice],
                       "the unconfirmed warning dropped part of the set's notice")
        XCTAssertNil(confirm.confirmer.currentTicket(), "the late playing read confirmed it")
        XCTAssertEqual(r.status.current()?.text, line, "the late confirmation dropped part of the set's notice")
    }

    /// Songs SpanDAC skipped because they are not in the library lead EVERY line of a
    /// marked-set hand-off: the play's own, the unconfirmed warning and the late
    /// confirmation's restored line.
    func testTheSkippedNotInLibraryLeadSurvivesAnUnconfirmedAndALateConfirmedHandoff() throws {
        let r = rig(output: .musicApp)
        let some = aliases
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"], aliases: some),
                                                   albumTracks(["t3"], aliases: some)])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"], skippedNotInLibrary: 2, aliases: some)])
        r.library.hits = handoffHits(allRows)
        let first = hex("1")
        let confirm = HonestPlayingTests.ConfirmRig([PlayerIdentityReading(state: "paused", persistentID: "00000000000000A1",
                                                                           requestedID: nil)],
                                                    status: r.status)
        confirm.onRead = { n in
            if n == 9 { confirm.setReadings([PlayerIdentityReading(state: "playing", persistentID: first, requestedID: nil)]) }
        }
        let store = AppQueueStore()
        store.confirmer = confirm.confirmer
        let routing = r.routing
        let handoff = PersistentIDHandoff(
            library: r.library,
            player: AppQueueHandoffPlayer(store: store,
                                          playFirst: requestedHandoffPlayFirst(backend: r.counter.backend, appQueue: store)),
            selfCheck: LibraryAliasSelfCheck(), currentStamp: { routing.musicTUISpanDACStamp })
        let marks = MarkedSetStore()
        for item in mixed { marks.toggle(item, source: .bridge) }
        playMarkedSet(marks.snapshot, shuffle: false, backend: r.counter.backend, appQueue: store,
                      routing: routing, actions: r.actions, status: r.status,
                      spanDACData: { spanDACDataProvider(routing: routing) != nil },
                      readers: refusingReaders(Counter()),
                      spanDAC: MarkedSetSpanDAC(makeProvider: { spanDACDataProvider(routing: routing) },
                                                handoff: handoff, sleep: { _ in }))
        r.actions.waitUntilIdle()
        let lead = "Skipped 2 not in your library \u{00B7} "
        let line = lead + "Playing '\(mixedName)' on MusicTUI."
        XCTAssertEqual(r.status.current()?.text, line, "the play's own line")
        XCTAssertEqual(store.read()?.tracks.count, 5)
        XCTAssertTrue(r.data.sent("slice.libraryPlaylistTracks").allSatisfy { $0["skip_not_in_library"] as? Bool == true },
                      "a marked playlist read did not ask to skip")
        XCTAssertTrue(r.data.sent("slice.listRev").allSatisfy { $0["skip_not_in_library"] as? Bool == true },
                      "the closing revision read must describe the same (skipped) list")

        confirm.runJobs()
        XCTAssertEqual(confirm.posts,
                       [playNotStartedWarning(mixedName) + " \u{00B7} skipped 2 songs not in your library"],
                       "the unconfirmed warning keeps its own words first and the skip follows")
        for width in [50, 80] {
            XCTAssertTrue(truncText(confirm.posts.first ?? "", to: width - 4)
                            .hasPrefix("Play was requested, but Music didn't confirm"), "\(width)")
        }
        XCTAssertNil(confirm.confirmer.currentTicket(), "the late playing read confirmed it")
        XCTAssertEqual(r.status.current()?.text, line, "the late confirmation dropped the skip")
    }

    // MARK: - A song in two marked items plays once, at its first position

    /// SpanDAC refuses a `slice.queue` that repeats a library ID, so a shared
    /// song is sent once, where the first item put it. Chill holds t2, which
    /// In Rainbows played first.
    private func scriptSharingReads(_ r: Rig, skippedVideos: Int = 0, aliases: [String: String] = [:]) {
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"], aliases: aliases),
                                                   albumTracks(["t3"], aliases: aliases)])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "t2", "p2"], skippedVideos: skippedVideos,
                                                                     aliases: aliases)])
    }

    func testASharedSongIsSentOnceAtItsFirstPosition() {
        let r = rig(output: .source)
        scriptSharingReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)

        let ids = r.output.sent("slice.queue").first?["library_ids"] as? [String] ?? []
        XCTAssertEqual(ids, ["t1", "t2", "p1", "p2", "t3"], "the shared song once, at the album's position")
        XCTAssertEqual(Set(ids).count, ids.count, "the request repeats a library ID")
        XCTAssertEqual(r.status.current()?.text,
                       "Playing '\(mixedName)' on SpanDAC \u{2014} 5 tracks. 1 repeated song plays once.",
                       "a removed duplicate is said, and is not a skipped song")
    }

    func testAShuffledSetSendsASharedSongOnce() {
        let r = rig(output: .source)
        scriptSharingReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, shuffle: true, r)

        let ids = r.output.sent("slice.queue").first?["library_ids"] as? [String] ?? []
        XCTAssertEqual(ids.sorted(), ["p1", "p2", "t1", "t2", "t3"], "a shuffle repeats or drops a song")
    }

    /// The same videos and the same song SpanDAC can't play, with and without
    /// the shared song: the same availability sentences, then the repeated one.
    func testADuplicateLeavesTheAvailabilitySentencesAsTheyWere() {
        let r = rig(output: .source)
        scriptSharingReads(r, skippedVideos: 2)
        r.output.script("slice.queue", [queued(skippedUnavailable: 1)])
        play(mixed, r)

        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["t1", "t2", "p1", "p2", "t3"])
        XCTAssertEqual(r.status.current()?.text,
                       "Playing 4 of 7 from '\(mixedName)' on SpanDAC: 2 videos skipped. 1 song isn't available to SpanDAC. "
                           + "1 repeated song plays once.")
    }

    func testOnTheMusicTUIOutputASharedSongIsHandedOffOnce() {
        let r = rig(output: .musicApp)
        scriptSharingReads(r, aliases: aliases)
        r.library.hits = handoffHits(allRows)
        play(mixed, r)

        XCTAssertEqual(r.player.queues.count, 1, "the hand-off built no queue: \(String(describing: r.status.current()?.text))")
        XCTAssertEqual(r.player.queues.first?.tracks.map { persistentIDOfQueueEntry($0.index) },
                       ["1", "2", "3", "4", "5"].map(hex), "the shared song once, at the album's position")
        XCTAssertEqual(r.status.current()?.text,
                       LibraryProvenance.playingOnMusicTUI(mixedName) + " 1 repeated song plays once.",
                       "a removed duplicate is said, and is not a skipped song")
    }

    func testOnTheMusicTUIOutputAShuffledSetHandsASharedSongOffOnce() {
        let r = rig(output: .musicApp)
        scriptSharingReads(r, aliases: aliases)
        r.library.hits = handoffHits(allRows)
        play(mixed, shuffle: true, r)

        XCTAssertEqual(r.player.queues.first?.tracks.map { persistentIDOfQueueEntry($0.index) }.sorted(),
                       ["1", "2", "3", "4", "5"].map(hex).sorted())
    }

    // MARK: - The repeated-song sentence, last, on every path

    /// Chill alone, with p1 three times and p2 once.
    private func scriptRepeatInsideChill(_ r: Rig, aliases: [String: String] = [:]) {
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p1", "p2", "p1"], aliases: aliases)])
    }

    func testOnASpanDACOutputARepeatInsideOnePlaylistIsSaidInThePlural() {
        let r = rig(output: .source)
        scriptRepeatInsideChill(r)
        r.output.script("slice.queue", [queued()])
        play([chill], r)

        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["p1", "p2"])
        XCTAssertEqual(r.status.current()?.text, "Playing 'Chill' on SpanDAC \u{2014} 2 tracks. 1 repeated song plays once.",
                       "p1 three times is one repeated song, not the two entries removed")
    }

    /// [A, B, A, A] with a video and B not playable: the "N of M" figures are
    /// those of the two songs sent, whatever the wording counts as repeated.
    func testARepeatedSongLeavesTheSpanDACNOfMArithmeticAsItWas() {
        let r = rig(output: .source)
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2", "p1", "p1"], skippedVideos: 1)])
        r.output.script("slice.queue", [queued(skippedUnavailable: 1)])
        play([chill], r)

        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["p1", "p2"])
        XCTAssertEqual(r.status.current()?.text,
                       "Playing 1 of 3 from 'Chill' on SpanDAC: 1 video skipped. 1 song isn't available to SpanDAC. "
                           + "1 repeated song plays once.")
    }

    func testOnASpanDACOutputTwoDifferentSongsEachRepeatedAreSaidInThePlural() {
        let r = rig(output: .source)
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2", "p1", "p2", "t3"])])
        r.output.script("slice.queue", [queued()])
        play([chill], r)

        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["p1", "p2", "t3"])
        XCTAssertEqual(r.status.current()?.text, "Playing 'Chill' on SpanDAC \u{2014} 3 tracks. 2 repeated songs play once.")
    }

    func testOnASpanDACOutputOneRepeatIsSaidInTheSingular() {
        let r = rig(output: .source)
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2", "p1"])])
        r.output.script("slice.queue", [queued()])
        play([chill], r)

        XCTAssertEqual(r.status.current()?.text, "Playing 'Chill' on SpanDAC \u{2014} 2 tracks. 1 repeated song plays once.")
    }

    func testASetWithNoRepeatKeepsItsSpanDACLineOnBothOutputs() {
        let r = rig(output: .source)
        scriptMixedReads(r)
        r.output.script("slice.queue", [queued()])
        play(mixed, r)
        XCTAssertEqual(r.status.current()?.text, "Playing '\(mixedName)' on SpanDAC \u{2014} 5 tracks.")

        let h = rig(output: .musicApp)
        scriptMixedReads(h, aliases: aliases)
        h.library.hits = handoffHits(allRows)
        play(mixed, h)
        XCTAssertEqual(h.status.current()?.text, LibraryProvenance.playingOnMusicTUI(mixedName))
    }

    func testOnTheMusicTUIOutputARepeatInsideOnePlaylistIsSaidInThePlural() {
        let r = rig(output: .musicApp)
        scriptRepeatInsideChill(r, aliases: aliases)
        r.library.hits = handoffHits(allRows)
        play([chill], r)

        XCTAssertEqual(r.player.queues.first?.tracks.map { persistentIDOfQueueEntry($0.index) }, ["3", "4"].map(hex))
        XCTAssertEqual(r.status.current()?.text, "Playing 'Chill' on MusicTUI. 1 repeated song plays once.")
    }

    func testOnTheMusicTUIOutputTwoDifferentSongsEachRepeatedAreSaidInThePlural() {
        let r = rig(output: .musicApp)
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2", "p1", "p2", "t3"], aliases: aliases)])
        r.library.hits = handoffHits(allRows)
        play([chill], r)

        XCTAssertEqual(r.player.queues.first?.tracks.map { persistentIDOfQueueEntry($0.index) }, ["3", "4", "5"].map(hex))
        XCTAssertEqual(r.status.current()?.text, "Playing 'Chill' on MusicTUI. 2 repeated songs play once.")
    }

    /// Through the real hand-off, the shell's player and a confirmer: Music
    /// does not confirm at first (the warning), then confirms late (the line
    /// comes back). Both carry the video, the song with no identity and the
    /// repeated song, in that order.
    private func handoffWithConfirmer(_ items: [MarkedItem], _ r: Rig, first: String)
        -> (confirm: HonestPlayingTests.ConfirmRig, store: AppQueueStore) {
        let confirm = HonestPlayingTests.ConfirmRig([PlayerIdentityReading(state: "paused", persistentID: "00000000000000A1",
                                                                           requestedID: nil)],
                                                    status: r.status)
        confirm.onRead = { n in
            if n == 9 { confirm.setReadings([PlayerIdentityReading(state: "playing", persistentID: first, requestedID: nil)]) }
        }
        let store = AppQueueStore()
        store.confirmer = confirm.confirmer
        let routing = r.routing
        let handoff = PersistentIDHandoff(
            library: r.library,
            player: AppQueueHandoffPlayer(store: store,
                                          playFirst: requestedHandoffPlayFirst(backend: r.counter.backend, appQueue: store)),
            selfCheck: LibraryAliasSelfCheck(), currentStamp: { routing.musicTUISpanDACStamp })
        let marks = MarkedSetStore()
        for item in items { marks.toggle(item, source: .bridge) }
        playMarkedSet(marks.snapshot, shuffle: false, backend: r.counter.backend, appQueue: store,
                      routing: routing, actions: r.actions, status: r.status,
                      spanDACData: { spanDACDataProvider(routing: routing) != nil },
                      readers: refusingReaders(Counter()),
                      spanDAC: MarkedSetSpanDAC(makeProvider: { spanDACDataProvider(routing: routing) },
                                                handoff: handoff, sleep: { _ in }))
        r.actions.waitUntilIdle()
        confirm.runJobs()
        return (confirm, store)
    }

    func testTheRepeatSentenceSurvivesAnUnconfirmedAndALateConfirmedHandoff() {
        // Across items, singular: In Rainbows (t1, t2), Chill (p1, t2, p2),
        // Amnesiac (t3, no identity), with a video left out.
        let r = rig(output: .musicApp)
        var some = aliases
        some["t3"] = nil
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"], aliases: some),
                                                   albumTracks(["t3"], aliases: some)])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "t2", "p2"], skippedVideos: 1, aliases: some)])
        r.library.hits = handoffHits(allRows.filter { $0.id != "t3" })
        let across = handoffWithConfirmer(mixed, r, first: hex("1"))
        let notice = "1 video skipped. 1 song isn't available to SpanDAC. 1 repeated song plays once."
        XCTAssertEqual(across.confirm.posts, [playNotStartedWarning(mixedName) + " " + notice],
                       "the unconfirmed warning dropped part of the set's notice")
        XCTAssertEqual(r.status.current()?.text, "Playing '\(mixedName)' on MusicTUI. \(notice)",
                       "the late confirmation dropped part of the set's notice")

        // Inside one playlist, plural, nothing else left out.
        let q = rig(output: .musicApp)
        scriptRepeatInsideChill(q, aliases: aliases)
        q.library.hits = handoffHits(allRows)
        let inside = handoffWithConfirmer([chill], q, first: hex("3"))
        XCTAssertEqual(inside.confirm.posts, [playNotStartedWarning("Chill") + " 1 repeated song plays once."])
        XCTAssertEqual(q.status.current()?.text, "Playing 'Chill' on MusicTUI. 1 repeated song plays once.")
    }

    // MARK: - Marks never play from another data source

    func testSpanDACMarksDoNotPlayOnMusicTUIData() {
        let r = rig(output: .musicApp, data: .missing)
        let reads = Counter()
        play(mixed, r, reads: reads)

        XCTAssertEqual(r.status.current()?.text, LibraryProvenance.musicAppSelectedBridgeList)
        XCTAssertEqual(r.data.requestCount + r.output.requestCount, 0, "SpanDAC was read")
        XCTAssertEqual(reads.value, 0, "the MusicTUI-data readers were asked")
        XCTAssertEqual(r.player.queues.count, 0)
        XCTAssertEqual(r.counter.callCount, 0)
    }

    func testMusicTUIMarksDoNotPlayOnSpanDACData() {
        let r = rig(output: .source)
        let reads = Counter()
        play([.album(title: "In Rainbows", artist: "Radiohead"), .playlist(id: "00000000000000F1", name: "Chill")],
             r, reads: reads, source: .musicApp)

        XCTAssertEqual(r.status.current()?.text, LibraryProvenance.bridgeSelectedMusicAppList)
        XCTAssertEqual(r.data.requestCount + r.output.requestCount, 0)
        XCTAssertEqual(reads.value, 0)
    }

    // MARK: - From the rails

    func testMarkingASpanDACAlbumRecordsItsIDAndPPlaysIt() {
        let r = rig(output: .source, brackets: false)
        r.data.script("slice.libraryAlbums", [
            """
            {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
             "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":2,"kind":"album"}],
             "next_cursor":null}
            """,
            bracket(), bracket(),
        ])
        r.data.script("slice.libraryAlbumTracks", [albumTracks(["t1", "t2"])])
        r.output.script("slice.queue", [queued()])
        let marks = MarkedSetStore()
        let routing = r.routing
        let s = LibraryScene(backend: r.counter.backend, routing: routing, sources: LibraryAppleScriptSpy().sources(),
                             appQueue: AppQueueStore(), status: r.status, actions: r.actions,
                             makeProvider: { spanDACDataProvider(routing: routing) },
                             handoff: r.handoff, warmUpSleep: { _ in },
                             resultCache: temporaryResultCache().cache,
                             screenWidth: { 120 },   // two-zone: no automatic preview read
                             marks: marks)
        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: self.frame, snapshot: self.idle).contains("In Rainbows") })
        XCTAssertEqual(s.handle(.char("m")), .redraw)
        XCTAssertEqual(marks.items, [inRainbows], "a SpanDAC album mark carries SpanDAC's album ID")
        XCTAssertTrue(s.render(frame: frame, snapshot: idle).contains(markedRowGlyph), "the mark is not shown")
        XCTAssertEqual(s.handle(.char("p")), .push(.nowPlaying))
        r.actions.waitUntilIdle()
        XCTAssertEqual(r.output.sent("slice.queue").map { $0["library_ids"] as? [String] }, [["t1", "t2"]])
        XCTAssertEqual(r.status.current()?.text, "Playing 'In Rainbows' on SpanDAC \u{2014} 2 tracks.")
    }

    func testPOnTheSpanDACPlaylistsRailPlaysTheMarks() {
        let r = rig(output: .source)
        r.data.script("slice.libraryPlaylists", [
            """
            {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
             "items":[{"id":"pl1","title":"Chill","kind":"playlist"}],"next_cursor":null}
            """,
        ])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks(["p1", "p2"])])
        r.output.script("slice.queue", [queued()])
        let marks = MarkedSetStore()
        let routing = r.routing
        let s = PlaylistsScene(backend: r.counter.backend, routing: routing, playlists: [], sources: .empty,
                               appQueue: AppQueueStore(), status: r.status, actions: r.actions,
                               metaCache: temporaryPlaylistMetaCache().cache,
                               makeProvider: { spanDACDataProvider(routing: routing) },
                               handoff: r.handoff, warmUpSleep: { _ in },
                               screenWidth: { 120 },
                               marks: marks)
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Chill"] })
        XCTAssertEqual(s.handle(.char("m")), .redraw)
        XCTAssertEqual(marks.items, [chill])
        XCTAssertEqual(s.handle(.char("p")), .push(.nowPlaying))
        r.actions.waitUntilIdle()
        XCTAssertEqual(r.output.sent("slice.queue").map { $0["library_ids"] as? [String] }, [["p1", "p2"]])
        XCTAssertEqual(r.status.current()?.text, "Playing 'Chill' on SpanDAC \u{2014} 2 tracks.")
    }
}
