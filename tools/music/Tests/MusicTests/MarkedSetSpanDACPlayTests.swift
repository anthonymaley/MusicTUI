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
    private let readAndPlayOps: Set<String> = ["slice.libraryAlbumTracks", "slice.libraryPlaylistTracks",
                                               "slice.queue", "slice.status"]

    private func song(_ id: String, alias: String? = nil) -> String {
        let a = alias.map { ",\"alias\":\"\($0)\"" } ?? ""
        return "{\"id\":\"\(id)\",\"title\":\"T\(id)\",\"artist\":\"Radiohead\",\"album\":\"A\",\"kind\":\"song\"\(a)}"
    }
    private func albumTracks(_ ids: [String], aliases: [String: String] = [:]) -> String {
        let items = ids.map { song($0, alias: aliases[$0]) }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryAlbumTracks\",\"generation\":3,\"items\":[\(items)]}"
    }
    private func playlistTracks(_ ids: [String], skippedVideos: Int = 0, aliases: [String: String] = [:]) -> String {
        let items = ids.map { song($0, alias: aliases[$0]) }.joined(separator: ",")
        return "{\"ok\":true,\"op\":\"slice.libraryPlaylistTracks\",\"generation\":3,\"total\":\(ids.count),"
            + "\"items\":[\(items)],\"next_cursor\":null,\"skipped_videos\":\(skippedVideos)}"
    }
    private func queued(skippedUnavailable: Int = 0) -> String {
        """
        {"ok":true,"op":"slice.queue","skipped_unavailable":\(skippedUnavailable),
         "status":{"playback":"playing","title":"T","artist":"A",
         "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}}}
        """
    }
    private let status = """
    {"ok":true,"op":"slice.status","playback":"playing","title":"T","artist":"A",
     "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}}
    """

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

    private func rig(output mode: PlaybackMode, data file: DataFile = .accepted) -> Rig {
        let dir = NSTemporaryDirectory() + "marked-spandac-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let modes = PlaybackModeStore(path: dir + "/mode.json")
        XCTAssertTrue(modes.set(mode))
        let dataStore = DataProviderStore(path: dir + "/data.json")
        if file == .accepted { XCTAssertTrue(dataStore.accept()) }
        let data = BridgeLibraryReadsWire()
        let output = BridgeLibraryReadsWire()
        output.stickyStatus = true
        output.script("slice.status", [status])
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
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty, "the play went to the data client, not the output")
        // Read in mark order, each by the ID its mark recorded.
        XCTAssertEqual(r.data.opsInOrder(), ["slice.libraryAlbumTracks", "slice.libraryPlaylistTracks",
                                             "slice.libraryAlbumTracks"])
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

        // 5 IDs sent, 1 skipped by SpanDAC, 2 videos never sent: 4 of 7.
        XCTAssertEqual(r.status.current()?.text, "Playing 4 of 7 \u{2014} the rest aren't available yet.")
        XCTAssertEqual(r.status.current(now: Date().addingTimeInterval(3600))?.staysUntilStateChange, true)
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
        XCTAssertEqual(r.status.current()?.text, "Playing 4 of 5 \u{2014} the rest aren't available yet.")
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
        let r = rig(output: .source)
        r.data.script("slice.libraryAlbums", [
            """
            {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
             "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":2,"kind":"album"}],
             "next_cursor":null}
            """,
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
