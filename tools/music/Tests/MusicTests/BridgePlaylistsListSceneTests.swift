import XCTest
@testable import music

/// C2: the Playlists tab's rail sourced from Bridge — the list, provenance,
/// header, note, and the tab opening with no AppleScript in Bridge mode.
/// Direct precedent: `BridgeLibraryListsSceneTests` (Part A, Albums/Artists).
/// Uses the shared `BridgeLibraryReadsWire` / `BridgeSelectedFlag` from
/// `BridgeLibraryTestSupport.swift`, and this tab's own
/// `PlaylistAppleScriptSpy` / `playlistsTestScene` / `settleScene` from
/// `BridgePlaylistsTestSupport.swift`.
final class BridgePlaylistsListSceneTests: XCTestCase {

    private let frame = shellLayout(width: 138, height: 30)
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    /// 3 rows on the wire (`total` 3): a real playlist, one of MusicTUI's own
    /// temp album containers, and `__cfromB` — which is NOT a temp name and
    /// must show in both modes (D1).
    private let playlistsPage = """
    {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":3,
     "items":[{"id":"pl1","title":"Top 25 Most Played","kind":"playlist"},
              {"id":"pl2","title":"__album__ 58D7C6EE— Aja","kind":"playlist"},
              {"id":"pl3","title":"__cfromB","kind":"playlist"}],
     "next_cursor":null}
    """
    /// Anthony's own worked example (D1): a wire `total` of 59 with exactly
    /// one `__album__` temp row shown gives N = 58.
    private func fiftyNineWireOneTemp() -> String {
        var items = "{\"id\":\"pl0\",\"title\":\"__album__ 58D7C6EE— Aja\",\"kind\":\"playlist\"}"
        for i in 1..<59 {
            items += ",{\"id\":\"pl\(i)\",\"title\":\"Playlist \(i)\",\"kind\":\"playlist\"}"
        }
        return """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":59,
         "items":[\(items)],"next_cursor":null}
        """
    }

    // MARK: - The Bridge rail

    func testItShowsTheWiresPlaylistsInWireOrder() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage]])
        let spy = PlaylistAppleScriptSpy()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Top 25 Most Played") })
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertEqual(s.railNamesForTest, ["Top 25 Most Played", "__cfromB"])
        XCTAssertTrue(out.contains("__cfromB"))
        XCTAssertEqual(spy.count("loadMusicAppPlaylists"), 0)
        XCTAssertEqual(spy.count("makeSources"), 0)
        XCTAssertEqual(spy.count("onMeta"), 0)
        XCTAssertEqual(spy.count("onPreview"), 0)
        XCTAssertEqual(spy.count("onTracks"), 0)
        XCTAssertEqual(spy.count("onArtworkMap"), 0)
    }

    func testTheHeaderReadsPlaylistsBridgeLibraryWithTheVisibleCount() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [fiftyNineWireOneTemp()]])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy())

        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("Playlists \u{2014} Bridge library (58)")
        }, "the header never showed the visible count of 58")
    }

    func testBridgePlaylistHeaderCountReturnsShownNeverWireTotal() {
        XCTAssertEqual(bridgePlaylistHeaderCount(shown: 58, wireTotal: 59), 58)
        XCTAssertEqual(bridgePlaylistHeaderCount(shown: 0, wireTotal: nil), 0)
    }

    // MARK: - Temp containers

    func testTempContainersAreNotShownAndNotCountedAndCfromBShows() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage]])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy())

        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("Playlists \u{2014} Bridge library (2)")
        }, "the header counted a temp container")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("__album__"), "a temp container was rendered: \(out)")
        XCTAssertTrue(out.contains("__cfromB"), "a non-temp name starting with __ was hidden")
        XCTAssertEqual(s.railNamesForTest, ["Top 25 Most Played", "__cfromB"])
    }

    // MARK: - The note

    func testTheNoteIsInTheRenderAndIsNotARowDownStaysOnTheLastRow() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage]])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy())

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Top 25 Most Played") })
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Some Music.app playlists"), "the note never rendered: \(out)")

        // Two rows, so index 1 (the last) is reachable; further ↓ must not
        // move the cursor onto the note (it is not addressable as a row).
        _ = s.handle(.down)
        let beforeExtra = s.railCursorForTest
        _ = s.handle(.down)
        XCTAssertEqual(s.railCursorForTest, beforeExtra, "the cursor moved past the last real row")
    }

    // MARK: - Pages: rule 9's regression

    func testTwoPagesLandingBeforeOneTickAreBothShown() {
        let page1 = """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":2,
         "items":[{"id":"pl1","title":"Alpha","kind":"playlist"}],"next_cursor":"c1"}
        """
        let page2 = """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":2,
         "items":[{"id":"pl2","title":"Zulu","kind":"playlist"}],"next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [page1, page2]])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy())

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Zulu") },
                      "the second page never landed")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Alpha") && out.contains("Zulu"), "a page was dropped: \(out)")
    }

    // MARK: - The filter

    func testSlashTopFiltersBridgesRows() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage]])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy())

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Top 25 Most Played") })
        _ = s.handle(.char("/"))
        for c in "Top" { _ = s.handle(.char(c)) }
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Top 25 Most Played"))
        XCTAssertFalse(out.contains("__cfromB"), "the filter matched a row it should have excluded")
    }

    func testAFilterTypedWhileWarmingAppliesOnceTheListLands() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage]])
        wire.gate(op: "slice.libraryPlaylists", at: 0)
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy())

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Loading playlists") },
                      "never observed the pre-load state")
        _ = s.handle(.char("/"))
        for c in "Top" { _ = s.handle(.char(c)) }
        wire.release(op: "slice.libraryPlaylists", at: 0)
        XCTAssertTrue(settleScene(s) {
            let out = s.render(frame: frame, snapshot: idle)
            return out.contains("Top 25 Most Played") || out.contains("(no matches)")
        })
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Top 25 Most Played"), "a filter typed before the rows arrived never matched once they loaded")
        XCTAssertFalse(out.contains("__cfromB"))
    }

    // MARK: - Warming

    func testTheRailShowsPreparingYourLibraryThenGivesUpVisibly() {
        let warming = """
        {"ok":false,"op":"slice.libraryPlaylists","error":{"kind":"warming","detail":"preparing your library","retry_after":5.0}}
        """
        let requests = Int(LibraryWarmUp.maxTotalWait / LibraryWarmUp.maxWait) + 1
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": Array(repeating: warming, count: requests)])
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   warmUpSleep: { _ in })

        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("Bridge is still preparing your library - press r to retry")
        }, "it never gave up visibly")
    }

    func testRReWalksTheWireSeesASecondRequestAndTheSpyStaysAtZero() {
        let noAccess = """
        {"ok":false,"op":"slice.libraryPlaylists","error":{"kind":"unauthorized","detail":"no access"}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [noAccess]])
        let spy = PlaylistAppleScriptSpy()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("press r to retry") },
                      "the Bridge failure never showed")
        wire.script("slice.libraryPlaylists", [playlistsPage])
        _ = s.handle(.char("r"))
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Top 25 Most Played") },
                      "r did not re-walk Bridge")
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, 2)
        XCTAssertEqual(spy.count("loadMusicAppPlaylists"), 0)
    }

    // MARK: - An older Bridge

    func testAnOlderBridgeShowsTheUpdateBridgeSentence() {
        let unknownOp = """
        {"ok":false,"op":"slice.libraryPlaylists","error":{"kind":"unknown_op","detail":"no such op"}}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [unknownOp]])
        let spy = PlaylistAppleScriptSpy()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(true), wire: wire, spy: spy)

        XCTAssertTrue(settleScene(s) {
            s.render(frame: frame, snapshot: idle).contains("This Bridge build can't list your playlists \u{2014} update Bridge")
        })
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Top 25"), "a Music.app row appeared after an older-Bridge refusal")
        XCTAssertEqual(spy.count("loadMusicAppPlaylists"), 0)
    }

    // MARK: - Music.app mode: unaffected

    func testInMusicAppModeTheRailAndBadgesComeFromTheInjectedSourcesAndNoWireRequest() {
        let wire = BridgeLibraryReadsWire()
        let s = playlistsTestScene(flag: BridgeSelectedFlag(false), wire: wire, spy: PlaylistAppleScriptSpy(),
                                   names: ["Chill", "Top 25 Most Played"])

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Chill") })
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Top 25 Most Played"))
        XCTAssertFalse(out.contains("Bridge library"), "a header named Bridge in Music.app mode: \(out)")
        XCTAssertFalse(out.contains("Some Music.app playlists"), "the Bridge-only note showed in Music.app mode")
        XCTAssertEqual(wire.requestCount, 0, "Music.app mode reached the wire at all")
    }

    // MARK: - Provenance (D7)

    func testMusicAppToBridgeTheWireSeesTheOpOldNamesAreGoneFocusIsOnTheRailCursorZeroStatusPosts() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage]])
        let flag = BridgeSelectedFlag(false)
        let status = StatusStore()
        let s = playlistsTestScene(flag: flag, wire: wire, spy: PlaylistAppleScriptSpy(), status: status,
                                   names: ["Music.app Playlist"])

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Music.app Playlist") })

        flag.selected = true
        XCTAssertTrue(settleScene(s) { !wire.sent("slice.libraryPlaylists").isEmpty },
                      "the flip never asked Bridge for playlists")
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Top 25 Most Played") },
                      "the rail never reloaded from Bridge")
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Music.app Playlist"), "the old Music.app rows were still on screen: \(out)")
        XCTAssertEqual(s.railCursorForTest, 0)
        XCTAssertEqual(status.current()?.text, LibraryProvenance.bridgePlaylistsShown)
    }

    func testBridgeToMusicAppTheLoaderIsCalledOnceMakeSourcesGetsThoseNamesAndNoFurtherWireRequests() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage]])
        let flag = BridgeSelectedFlag(true)
        let spy = PlaylistAppleScriptSpy()
        spy.names = ["Reloaded Playlist"]
        let status = StatusStore()
        let s = playlistsTestScene(flag: flag, wire: wire, spy: spy, status: status)

        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Top 25 Most Played") })
        let bridgeRequestsBeforeFlip = wire.sent("slice.libraryPlaylists").count

        flag.selected = false
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Reloaded Playlist") },
                      "the rail never reloaded from Music.app")
        XCTAssertEqual(spy.count("loadMusicAppPlaylists"), 1)
        XCTAssertEqual(spy.count("makeSources"), 1)
        XCTAssertEqual(wire.sent("slice.libraryPlaylists").count, bridgeRequestsBeforeFlip,
                       "the flip back to Music.app asked Bridge again")
        XCTAssertEqual(status.current()?.text, LibraryProvenance.musicAppPlaylistsShown)
    }

    // MARK: - Stale posts

    /// A Music.app `onMeta` result gated until after a flip to Bridge AND
    /// back to Music.app again (a fresh, different-named load landing at the
    /// SAME index the gated post targets) must never paint the reloaded
    /// list — the epoch check `postMeta`/`drainMeta` carry (rule 10), not
    /// merely the array-bounds guard a single flip alone would rely on.
    func testAMusicAppOnMetaResultGatedUntilAfterAFlipToBridgeIsDropped() {
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [playlistsPage]])
        let flag = BridgeSelectedFlag(false)
        let gate = DispatchSemaphore(value: 0)
        // Blocks until released, so its result can be made to land AFTER a
        // full round trip through Bridge and back.
        let blockedSources = PlaylistDataSources(
            onMeta: { idxs in
                gate.wait()
                return Dictionary(uniqueKeysWithValues: idxs.map { ($0, (999, 100, false, "")) })
            },
            onPreview: { _ in nil }, onTracks: { _ in nil }, onArtworkMap: nil)
        let s = PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                               routing: RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"),
                                                           surface: .tui, makeSource: { SourceAppClient(path: "/nonexistent", transport: wire.transport) }),
                               playlists: ["Slow Playlist"], sources: blockedSources,
                               appQueue: AppQueueStore(), status: StatusStore(), actions: ActionRunner(status: StatusStore()),
                               metaCache: temporaryPlaylistMetaCache().cache,
                               makeProvider: {
                                   flag.selected
                                       ? BridgeMusicProvider(control: SourceAppControl(path: "/nonexistent", transport: wire.transport, libraryTransport: wire.transport))
                                       : nil
                               },
                               loadMusicAppPlaylists: { (["New Playlist"], []) },
                               makeSources: { _ in .empty },
                               warmUpSleep: { _ in }, screenWidth: { 138 })

        flag.selected = true
        for _ in 0..<5 { _ = s.tick(snapshot: idle) }
        flag.selected = false
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("New Playlist") },
                      "the second Music.app load never landed")

        gate.signal()
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }

        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("999"), "a stale onMeta result from before the flip landed on the reloaded list: \(out)")
    }

    func testABridgePageGatedUntilAfterAFlipToMusicAppNeverAppears() {
        let page1 = """
        {"ok":true,"op":"slice.libraryPlaylists","generation":3,"total":1,
         "items":[{"id":"pl1","title":"Gated Bridge Playlist","kind":"playlist"}],"next_cursor":null}
        """
        let wire = BridgeLibraryReadsWire(["slice.libraryPlaylists": [page1]])
        wire.gate(op: "slice.libraryPlaylists", at: 0)
        let flag = BridgeSelectedFlag(true)
        let spy = PlaylistAppleScriptSpy()
        spy.names = ["Music.app Playlist"]
        let s = playlistsTestScene(flag: flag, wire: wire, spy: spy)

        XCTAssertTrue(settleScene(s) { wire.reached(op: "slice.libraryPlaylists", at: 0) },
                      "never reached the gated first page")
        flag.selected = false   // flip away from Bridge while the page is in flight
        XCTAssertTrue(settleScene(s) { s.render(frame: frame, snapshot: idle).contains("Music.app Playlist") },
                      "the provenance reset never reloaded Music.app")
        wire.release(op: "slice.libraryPlaylists", at: 0)
        Thread.sleep(forTimeInterval: 0.15)
        for _ in 0..<10 { _ = s.tick(snapshot: idle) }
        let out = s.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Gated Bridge Playlist"), "a Bridge row landed after the rail had reset to Music.app: \(out)")
    }

    // MARK: - openPlaylistsScene

    func testOpenPlaylistsSceneInBridgeModeReturnsAndTheLoaderCountIsZero() {
        var loaderCalls = 0
        let status = StatusStore()
        var built: (names: [String], subscription: Set<String>)? = nil
        let scene = openPlaylistsScene(bridgeSelected: true, status: status,
                                       loadMusicAppPlaylists: { loaderCalls += 1; return (["x"], []) },
                                       build: { names, subscription in
                                           built = (names, subscription)
                                           return PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                                                 routing: RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"), surface: .tui, makeSource: { SourceAppClient() }),
                                                                 playlists: names, subscriptionNames: subscription,
                                                                 sources: .empty, appQueue: AppQueueStore(), status: status,
                                                                 actions: ActionRunner(status: status),
                                                                 metaCache: temporaryPlaylistMetaCache().cache)
                                       })
        XCTAssertNotNil(scene)
        XCTAssertEqual(loaderCalls, 0, "Bridge mode called loadMusicAppPlaylists")
        XCTAssertEqual(built?.names, [], "Bridge mode built with non-empty names")
    }

    func testOpenPlaylistsSceneInMusicAppModeWithNoNamesReturnsNilAndPostsNoPlaylistsFound() {
        let status = StatusStore()
        let scene = openPlaylistsScene(bridgeSelected: false, status: status,
                                       loadMusicAppPlaylists: { ([], []) },
                                       build: { names, subscription in
                                           XCTFail("build should not be called with no names")
                                           return PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                                                 routing: RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"), surface: .tui, makeSource: { SourceAppClient() }),
                                                                 playlists: names, subscriptionNames: subscription,
                                                                 sources: .empty, appQueue: AppQueueStore(), status: status,
                                                                 actions: ActionRunner(status: status),
                                                                 metaCache: temporaryPlaylistMetaCache().cache)
                                       })
        XCTAssertNil(scene)
        XCTAssertEqual(status.current()?.text, "No playlists found.")
    }

    func testOpenPlaylistsSceneInMusicAppModeWithNamesBuildsWithThoseNames() {
        let status = StatusStore()
        var built: (names: [String], subscription: Set<String>)? = nil
        let scene = openPlaylistsScene(bridgeSelected: false, status: status,
                                       loadMusicAppPlaylists: { (["Chill", "Deep House"], ["Deep House"]) },
                                       build: { names, subscription in
                                           built = (names, subscription)
                                           return PlaylistsScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                                                                 routing: RoutingCoordinator(store: PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json"), surface: .tui, makeSource: { SourceAppClient() }),
                                                                 playlists: names, subscriptionNames: subscription,
                                                                 sources: .empty, appQueue: AppQueueStore(), status: status,
                                                                 actions: ActionRunner(status: status),
                                                                 metaCache: temporaryPlaylistMetaCache().cache)
                                       })
        XCTAssertNotNil(scene)
        XCTAssertEqual(built?.names, ["Chill", "Deep House"])
        XCTAssertEqual(built?.subscription, ["Deep House"])
    }
}
