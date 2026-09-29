import XCTest
@testable import music

/// The Library and Playlists tabs on the two axes (score: data route and
/// output, step 4): the lists follow the DATA selection, plays follow the
/// OUTPUT, and a play of a SpanDAC library row on the MusicTUI output goes to
/// the hand-off.
///
/// Every coordinator here is the production one, composed with a temp
/// mode.json and a temp data.json (never `~/.config/music`) and with counting
/// factories: the DATA client answers from `data`, and every OUTPUT client
/// answers from `output`, so a test can say which side a request reached and
/// whether a client was built at all. The scenes' provider is the shell's own
/// `spanDACDataProvider`. The AppleScript backend is `AppleScriptCallCounter`'s
/// inert script, so nothing reaches Apple's Music app.
final class BridgeLibraryDataRouteTests: XCTestCase {

    private let frame = shellLayout(width: 140, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    // MARK: - Fixtures

    private let songPage = """
    {"ok":true,"op":"slice.librarySongs","generation":3,"total":1,
     "items":[{"id":"s1","title":"Nude","artist":"Radiohead","album":"In Rainbows","kind":"song"}],
     "next_cursor":null}
    """
    private let albumPage = """
    {"ok":true,"op":"slice.libraryAlbums","generation":3,"total":1,
     "items":[{"id":"al1","title":"In Rainbows","artist":"Radiohead","track_count":3,"kind":"album"}],
     "next_cursor":null}
    """
    private let artistPage = """
    {"ok":true,"op":"slice.libraryArtists","generation":3,"total":1,
     "items":[{"id":"ar1","title":"Radiohead","kind":"artist"}],"next_cursor":null}
    """
    private let playlistPage = """
    {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
     "items":[{"id":"pl1","title":"Chill","kind":"playlist"}],"next_cursor":null}
    """
    private let playlistTracks = """
    {"ok":true,"op":"slice.libraryPlaylistTracks","generation":3,"total":2,
     "items":[{"id":"p1","title":"One","artist":"A","kind":"song"},{"id":"p2","title":"Two","artist":"A","kind":"song"}],
     "next_cursor":null,"skipped_videos":0}
    """
    private let queued = """
    {"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T","artist":"A",
     "contract":3,"authorization":"authorized","queue":{"phase":"complete","requested":1,"present":1,"index":0}}}
    """
    private func containerReply(_ op: String, _ ids: [String]) -> String {
        let items = ids.map { "{\"id\":\"\($0)\",\"title\":\"T\($0)\",\"artist\":\"Radiohead\",\"album\":\"In Rainbows\",\"kind\":\"song\"}" }
            .joined(separator: ",")
        return "{\"ok\":true,\"op\":\"\(op)\",\"generation\":3,\"items\":[\(items)]}"
    }

    // MARK: - Rig

    /// How many clients each factory built, and for which output.
    private final class Built {
        private let lock = NSLock()
        private var dataClients = 0
        private var outputs: [PlaybackMode] = []
        func data() { lock.lock(); dataClients += 1; lock.unlock() }
        func output(_ mode: PlaybackMode) { lock.lock(); outputs.append(mode); lock.unlock() }
        var dataCount: Int { lock.lock(); defer { lock.unlock() }; return dataClients }
        var outputModes: [PlaybackMode] { lock.lock(); defer { lock.unlock() }; return outputs }
    }

    /// Records every hand-off; succeeds unless told to refuse.
    private final class HandoffSpy: MusicTUIHandoff {
        struct Call: Equatable { let ids: [String]; let startAt: Int; let shuffle: Bool; let title: String }
        private let lock = NSLock()
        private var recorded: [Call] = []
        var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
        /// What every play reports back (nothing skipped unless a test says so).
        var report = HandoffPlayReport()
        func playLibrary(rows: [MusicRow], startAt: Int, startRequired: Bool, shuffle: Bool,
                         title: String) throws -> HandoffPlayReport {
            lock.lock()
            recorded.append(Call(ids: rows.map(\.id), startAt: startAt, shuffle: shuffle, title: title))
            let report = self.report
            lock.unlock()
            return report
        }
    }

    private enum DataFile { case accepted, missing }

    private struct Rig {
        let routing: RoutingCoordinator
        let data: BridgeLibraryReadsWire
        let output: BridgeLibraryReadsWire
        let built: Built
        let counter: AppleScriptCallCounter
        let handoff: HandoffSpy
        let status: StatusStore
    }

    private func rig(output mode: PlaybackMode, data file: DataFile) -> Rig {
        let dir = NSTemporaryDirectory() + "data-route-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let modes = PlaybackModeStore(path: dir + "/mode.json")
        XCTAssertTrue(modes.set(mode))
        let dataStore = DataProviderStore(path: dir + "/data.json")
        if file == .accepted { XCTAssertTrue(dataStore.accept()) }
        let data = BridgeLibraryReadsWire()
        let output = BridgeLibraryReadsWire()
        let built = Built()
        let routing = RoutingCoordinator(
            store: modes, surface: .tui, outputLock: nil, dataStore: dataStore,
            makeSourceFor: { mode in
                built.output(mode)
                return SourceAppClient(path: "/nonexistent", transport: output.transport,
                                       libraryTransport: output.transport)
            },
            makeDataClient: {
                built.data()
                return SourceAppClient(path: "/nonexistent", transport: data.transport,
                                       libraryTransport: data.transport)
            },
            starter: NeverStartsMacSpanDAC())
        let status = StatusStore()
        return Rig(routing: routing, data: data, output: output, built: built,
                   counter: AppleScriptCallCounter(), handoff: HandoffSpy(), status: status)
    }

    private func libraryScene(_ r: Rig, spy: LibraryAppleScriptSpy = LibraryAppleScriptSpy(),
                              appQueue: AppQueueStore = AppQueueStore(),
                              resolved: AlbumResolution? = nil) -> LibraryScene {
        let routing = r.routing
        return LibraryScene(backend: r.counter.backend, routing: routing, sources: spy.sources(),
                            appQueue: appQueue, status: r.status, actions: ActionRunner(status: r.status),
                            resolveAlbum: { backend, title, artist in
                                resolved ?? resolveAlbumPlaybackTracks(backend: backend, title: title, artist: artist)
                            },
                            makeProvider: { spanDACDataProvider(routing: routing) },
                            handoff: r.handoff,
                            warmUpSleep: { _ in },
                            resultCache: temporaryResultCache().cache)
    }

    private func wait(seconds: Double = 3.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    // MARK: - Reads follow data

    func testLibraryReadsFollowDataNotOutput() {
        // SpanDAC data with the MusicTUI output: the list is SpanDAC on this
        // Mac's, read through the DATA client; no output client is built and
        // AppleScript's library read is never asked.
        let spanDAC = rig(output: .musicApp, data: .accepted)
        spanDAC.data.script("slice.librarySongs", [songPage])
        let spanDACSpy = LibraryAppleScriptSpy()
        let s1 = libraryScene(spanDAC, spy: spanDACSpy)
        goToSubView(s1, .songs)
        XCTAssertTrue(settleScene(s1) { s1.songsForTest.map(\.id) == ["s1"] })
        XCTAssertEqual(spanDAC.data.sent("slice.librarySongs").count, 1)
        XCTAssertEqual(spanDACSpy.count("onSongs"), 0, "SpanDAC data read the AppleScript library")
        XCTAssertEqual(spanDAC.output.requestCount, 0)
        XCTAssertEqual(spanDAC.built.outputModes, [], "a read built an OUTPUT client")

        // The same MusicTUI output with MusicTUI's own data: AppleScript, and
        // no SpanDAC client of either kind is ever built.
        let open = rig(output: .musicApp, data: .missing)
        let openSpy = LibraryAppleScriptSpy()
        openSpy.songs = [LibrarySong(id: "a1", title: "Old", artist: "X", album: "Y")]
        let s2 = libraryScene(open, spy: openSpy)
        goToSubView(s2, .songs)
        XCTAssertTrue(settleScene(s2) { s2.songsForTest.map(\.id) == ["a1"] })
        XCTAssertGreaterThan(openSpy.count("onSongs"), 0)
        XCTAssertEqual(open.data.requestCount, 0)
        XCTAssertEqual(open.built.dataCount, 0, "open data built a SpanDAC data client")
        XCTAssertEqual(open.built.outputModes, [])
    }

    func testPlaylistsReadFromTheMacWhenTheOutputIsAnIPhone() {
        let r = rig(output: .networkSource("0E6A3F6C-4B51-4D1B-9E1E-5C2A8D3B7F10"), data: .accepted)
        r.data.script("slice.libraryPlaylists", [playlistPage])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks])
        r.output.script("slice.queue", [queued])
        r.output.script("slice.status", [queued])
        let routing = r.routing
        let s = PlaylistsScene(backend: r.counter.backend, routing: routing, playlists: [], sources: .empty,
                               appQueue: AppQueueStore(), status: r.status, actions: ActionRunner(status: r.status),
                               metaCache: temporaryPlaylistMetaCache().cache,
                               makeProvider: { spanDACDataProvider(routing: routing) },
                               handoff: r.handoff, warmUpSleep: { _ in },
                               screenWidth: { 120 })   // two-zone: no automatic preview read
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Chill"] })
        XCTAssertEqual(r.data.sent("slice.libraryPlaylists").count, 1, "the rail was not read from the Mac")
        XCTAssertEqual(r.output.requestCount, 0, "the iPhone's library was read")

        _ = s.handle(.char("p"))
        XCTAssertTrue(wait { !r.output.sent("slice.queue").isEmpty }, "the play never reached the iPhone")
        XCTAssertEqual(r.output.sent("slice.queue").first?["library_ids"] as? [String], ["p1", "p2"])
        XCTAssertEqual(r.data.sent("slice.libraryPlaylistTracks").count, 1, "the tracks were not read from the Mac")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty, "the play went to the Mac, not the selected output")
        XCTAssertEqual(r.output.sent("slice.libraryPlaylists").count + r.output.sent("slice.libraryPlaylistTracks").count, 0)
        XCTAssertEqual(r.built.outputModes, [.networkSource("0E6A3F6C-4B51-4D1B-9E1E-5C2A8D3B7F10")])
        XCTAssertEqual(r.handoff.calls, [])
        XCTAssertEqual(r.counter.callCount, 0)
    }

    // MARK: - Plays follow the output

    func testLibraryPlayOnMusicTUIOutputGoesToTheHandoff() {
        let r = rig(output: .musicApp, data: .accepted)
        r.data.script("slice.libraryAlbums", [albumPage])
        // Twice: a proactive preview may read the tracks before the play does.
        r.data.script("slice.libraryAlbumTracks", [containerReply("slice.libraryAlbumTracks", ["t1", "t2", "t3"]),
                                                   containerReply("slice.libraryAlbumTracks", ["t1", "t2", "t3"])])
        r.data.script("slice.librarySongs", [songPage])
        let s = libraryScene(r)

        goToSubView(s, .albums)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("In Rainbows") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(wait { !r.handoff.calls.isEmpty }, "the album never reached the hand-off")
        XCTAssertEqual(r.handoff.calls.first,
                       HandoffSpy.Call(ids: ["t1", "t2", "t3"], startAt: 1, shuffle: false, title: "In Rainbows"))
        XCTAssertTrue(settleScene(s) { r.status.current()?.text == LibraryProvenance.playingOnMusicTUI("In Rainbows") },
                      "got: \(String(describing: r.status.current()?.text))")

        // A song: the row SpanDAC gave, by its id.
        goToSubView(s, .songs)
        XCTAssertTrue(settleScene(s) { s.songsForTest.map(\.id) == ["s1"] })
        _ = s.handle(.enter)
        XCTAssertTrue(wait { r.handoff.calls.count == 2 })
        XCTAssertEqual(r.handoff.calls.last, HandoffSpy.Call(ids: ["s1"], startAt: 1, shuffle: false, title: "Nude"))

        XCTAssertTrue(r.data.sent("slice.queue").isEmpty, "a SpanDAC queue was sent for the MusicTUI output")
        XCTAssertEqual(r.output.requestCount, 0)
        XCTAssertEqual(r.built.outputModes, [], "the MusicTUI output built a SpanDAC output client")
        XCTAssertEqual(r.counter.callCount, 0, "the scene itself reached AppleScript (the hand-off's to do)")
    }

    /// A SpanDAC playlist on the MusicTUI output whose hand-off skipped a song
    /// that is no longer available: the footer says it is playing and how
    /// many were skipped (ruling, 2026-09-24). The live shape, at the scene.
    func testAPlaylistHandOffThatSkippedASongSaysSoOnTheFooter() {
        let r = rig(output: .musicApp, data: .accepted)
        r.data.script("slice.libraryPlaylists", [playlistPage])
        r.data.script("slice.libraryPlaylistTracks", [playlistTracks])
        r.handoff.report = HandoffPlayReport(skippedUnavailable: 1)
        let routing = r.routing
        let s = PlaylistsScene(backend: r.counter.backend, routing: routing, playlists: [], sources: .empty,
                               appQueue: AppQueueStore(), status: r.status, actions: ActionRunner(status: r.status),
                               metaCache: temporaryPlaylistMetaCache().cache,
                               makeProvider: { spanDACDataProvider(routing: routing) },
                               handoff: r.handoff, warmUpSleep: { _ in },
                               screenWidth: { 120 })
        XCTAssertTrue(settleScene(s) { s.railNamesForTest == ["Chill"] })
        _ = s.handle(.char("p"))
        XCTAssertTrue(wait { !r.handoff.calls.isEmpty }, "the playlist never reached the hand-off")
        XCTAssertEqual(r.handoff.calls.first?.ids, ["p1", "p2"])
        let expected = LibraryProvenance.playingOnMusicTUI("Chill") + " 1 song isn't available to SpanDAC."
        XCTAssertTrue(settleScene(s) { r.status.current()?.text == expected },
                      "got: \(String(describing: r.status.current()?.text))")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.built.outputModes, [])
    }

    /// An owned song on the MusicTUI output with SpanDAC data and no DAC on
    /// this Mac: it plays by persistent ID through the hand-off. Nothing asks
    /// for a DAC, and nothing is sent to any SpanDAC to play.
    func testOwnedSongPlaysOnMusicTUIOutputWithoutADAC() {
        let r = rig(output: .musicApp, data: .accepted)
        r.data.script("slice.status", Array(repeating: noDACStatus, count: 8))
        r.data.script("slice.librarySongs", [songPage])
        let s = libraryScene(r)

        goToSubView(s, .songs)
        XCTAssertTrue(settleScene(s) { s.songsForTest.map(\.id) == ["s1"] })
        _ = s.handle(.enter)
        XCTAssertTrue(wait { !r.handoff.calls.isEmpty }, "the song never reached the hand-off")
        XCTAssertEqual(r.handoff.calls.first, HandoffSpy.Call(ids: ["s1"], startAt: 1, shuffle: false, title: "Nude"))
        XCTAssertFalse(r.status.current()?.text.contains("DAC") ?? false,
                       "got: \(String(describing: r.status.current()?.text))")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.output.requestCount, 0)
        XCTAssertEqual(r.built.outputModes, [])
    }

    func testTheShellsDefaultHandoffRefusesAndPlaysNothing() {
        let r = rig(output: .musicApp, data: .accepted)
        r.data.script("slice.librarySongs", [songPage])
        let routing = r.routing
        let s = LibraryScene(backend: r.counter.backend, routing: routing, sources: LibraryAppleScriptSpy().sources(),
                             appQueue: AppQueueStore(), status: r.status, actions: ActionRunner(status: r.status),
                             makeProvider: { spanDACDataProvider(routing: routing) },
                             handoff: RefusingHandoff(), warmUpSleep: { _ in },
                             resultCache: temporaryResultCache().cache)
        goToSubView(s, .songs)
        XCTAssertTrue(settleScene(s) { s.songsForTest.map(\.id) == ["s1"] })
        _ = s.handle(.enter)
        XCTAssertTrue(wait { r.status.current()?.text == pickASpanDACOutput },
                      "got: \(String(describing: r.status.current()?.text))")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.output.requestCount, 0)
        XCTAssertEqual(r.counter.callCount, 0)
    }

    // MARK: - Provenance and the stamp

    func testAListFromBeforeTheSwitchReloadsAndRefusesPlay() throws {
        let r = rig(output: .musicApp, data: .missing)
        r.data.script("slice.librarySongs", [songPage])
        let spy = LibraryAppleScriptSpy()
        spy.songs = [LibrarySong(id: "a1", title: "Old", artist: "X", album: "Y")]
        let s = libraryScene(r, spy: spy)
        goToSubView(s, .songs)
        XCTAssertTrue(settleScene(s) { s.songsForTest.map(\.id) == ["a1"] })

        // The person accepts SpanDAC as the data source (the Output tab's
        // switch screen) while this list is on screen; Enter lands before the
        // Library tab ticks again.
        XCTAssertEqual(try r.routing.acceptSpanDACData(readiness: { .ready }), .switched(to: .spandacMac))
        _ = s.handle(.enter)
        XCTAssertTrue(wait { r.status.current()?.text == listFromBeforeSpanDACSwitch },
                      "got: \(String(describing: r.status.current()?.text))")
        XCTAssertEqual(r.counter.callCount, 0, "a list from before the switch reached AppleScript")
        XCTAssertEqual(r.handoff.calls, [])
        XCTAssertEqual(r.built.outputModes, [])

        // The next tick reloads the list from SpanDAC on this Mac.
        XCTAssertTrue(settleScene(s) { s.songsForTest.map(\.id) == ["s1"] }, "the list did not reload from SpanDAC")
        XCTAssertEqual(r.data.sent("slice.librarySongs").count, 1)
    }

    func testAPlayWhoseReadCrossedASwitchPlaysNothing() throws {
        let r = rig(output: .source, data: .accepted)
        r.data.script("slice.libraryArtists", [artistPage])
        r.data.script("slice.libraryArtistSongs", [containerReply("slice.libraryArtistSongs", ["t1", "t2"])])
        r.data.gate(op: "slice.libraryArtistSongs", at: 0)
        r.output.script("slice.queue", [queued])
        let s = libraryScene(r)

        goToSubView(s, .artists)
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Radiohead") })
        _ = s.handle(.char("p"))
        XCTAssertTrue(wait { r.data.reached(op: "slice.libraryArtistSongs", at: 0) }, "the play never read the songs")

        // The output moves while the play's read is in flight.
        let switched = try r.routing.switchMode(to: .networkSource("0E6A3F6C-4B51-4D1B-9E1E-5C2A8D3B7F10"), readiness: { .ready },
                                                pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(switched, .switched(to: .networkSource("0E6A3F6C-4B51-4D1B-9E1E-5C2A8D3B7F10")))
        r.data.release(op: "slice.libraryArtistSongs")

        XCTAssertTrue(wait { r.status.current()?.text == sourceChangedNothingPlayed },
                      "got: \(String(describing: r.status.current()?.text))")
        XCTAssertTrue(r.output.sent("slice.queue").isEmpty, "a play whose read crossed a switch reached an output")
        XCTAssertTrue(r.data.sent("slice.queue").isEmpty)
        XCTAssertEqual(r.handoff.calls, [])
        XCTAssertEqual(r.built.outputModes, [], "an output client was built for a play that must not run")
    }

    // MARK: - Blocked and open data

    func testBlockedStateLibraryIsTheShippedPathAndPlaysNothing() {
        // A stored SpanDAC output with no data.json at all: C-REPAIR.
        let r = rig(output: .source, data: .missing)
        XCTAssertEqual(r.routing.selection, .outputBlocked(stored: .source))
        let spy = LibraryAppleScriptSpy()
        spy.songs = [LibrarySong(id: "a1", title: "Old", artist: "X", album: "Y")]
        let s = libraryScene(r, spy: spy)

        goToSubView(s, .songs)
        XCTAssertTrue(settleScene(s) { s.songsForTest.map(\.id) == ["a1"] })
        XCTAssertGreaterThan(spy.count("onSongs"), 0, "blocked reads must run the shipped AppleScript read")

        _ = s.handle(.enter)
        XCTAssertTrue(wait { r.status.current()?.text == finishSwitchingToSpanDAC },
                      "got: \(String(describing: r.status.current()?.text))")
        s.playAlbum(title: "Album", artist: "A", shuffle: false)
        XCTAssertTrue(wait { r.status.current()?.text == finishSwitchingToSpanDAC })
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(r.counter.callCount, 0, "a blocked play reached AppleScript")
        XCTAssertEqual(r.built.dataCount, 0, "blocked built a SpanDAC data client")
        XCTAssertEqual(r.built.outputModes, [], "blocked built a SpanDAC output client")
        XCTAssertEqual(r.data.requestCount + r.output.requestCount, 0)
        XCTAssertEqual(r.handoff.calls, [])
    }

    func testOpenDataLibraryIsTheShippedAppleScriptPath() {
        let r = rig(output: .musicApp, data: .missing)
        let queue = AppQueueStore()
        let tracks = (1...3).map { TrackListEntry(index: $0, name: "T\($0)", artist: "A", isCurrent: false, album: "Album") }
        let spy = LibraryAppleScriptSpy()
        spy.songs = [LibrarySong(id: "a1", title: "Old", artist: "X", album: "Y")]
        let s = libraryScene(r, spy: spy, appQueue: queue, resolved: AlbumResolution(tracks: tracks, matched: 3))

        goToSubView(s, .songs)
        XCTAssertTrue(settleScene(s) { s.songsForTest.map(\.id) == ["a1"] })
        XCTAssertGreaterThan(spy.count("onSongs"), 0)

        // The shipped album body: the app-owned queue, then AppleScript.
        s.playAlbum(title: "Album", artist: "A", shuffle: false)
        XCTAssertTrue(wait { queue.read()?.displayName == "Album" }, "the shipped album body did not run")
        XCTAssertEqual(queue.read()?.tracks.count, 3)
        XCTAssertTrue(wait { r.counter.callCount > 0 }, "the shipped body never reached AppleScript")

        // A song row plays through the shipped AppleScript resolution too.
        let before = r.counter.callCount
        _ = s.handle(.enter)
        XCTAssertTrue(wait { r.counter.callCount > before }, "the shipped song path never reached AppleScript")

        XCTAssertEqual(r.built.dataCount, 0, "open data built a SpanDAC data client")
        XCTAssertEqual(r.built.outputModes, [], "open data built a SpanDAC output client")
        XCTAssertEqual(r.data.requestCount + r.output.requestCount, 0)
        XCTAssertEqual(r.handoff.calls, [])
    }
}
