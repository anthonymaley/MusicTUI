// tools/music/Tests/MusicTests/MacRouteP9Tests.swift
//
// Score step P9 (mac-route-plan.md): on the Mac DAC route every song played goes
// through the rate transition one at a time, never through a temporary playlist
// Music plays straight through. The TUI's search song and album (added to the
// library through SpanDAC, then played by their library identity) and the CLI's
// Music-data album, artist and song plays. Off the route nothing changes; a
// library add that fails still refuses. Fakes only: a recording route seam, a
// fake library, fake scripts and launcher; no AppleScript, socket or real store.
import XCTest
@testable import music

final class MacRouteP9Tests: XCTestCase {

    /// A route seam that records the plays it is handed.
    private final class RouteRecorder {
        var on: Bool
        var plays: [(label: String, ids: [String])] = []
        var startsOK = true
        init(on: Bool = true) { self.on = on }
        var seam: MacRouteSongPlay {
            MacRouteSongPlay(isOn: { [unowned self] in on },
                             play: { [unowned self] label, ids in
                                 plays.append((label, ids)); return startsOK
                             })
        }
    }

    // MARK: - TUI: a search song and a search album on the route

    private struct Scene {
        let scene: DiscoverScene
        let routing: RoutingCoordinator
        let status: StatusStore
        let actions: ActionRunner
        let lib: FakeAppleLibrary
        let mac: FakeSpanDACMac
        let route: RouteRecorder
        let read: DiscoverScene.RowsRead
    }

    private func makeScene(route: RouteRecorder) throws -> Scene {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let routing = rig.coordinator()
        routing.macRouteStore.set(true)
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let lib = FakeAppleLibrary()
        for n in 1...3 { lib.catalogue["90\(n)"] = ("T\(n)", "A", "Boom Bap") }
        let mac = FakeSpanDACMac(library: lib)
        let seamsLifecycle = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, _ in XCTFail("the web-service create ran") }, readCount: { _ in 0 },
            play: { _ in XCTFail("played") }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }))
        let lifecycle = DiscoverLifecycleCoordinator(seams: seamsLifecycle)
        lifecycle.completeLaunchSweep(.swept)
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: lifecycle, routing: routing, opener: SceneRecordingOpener())
        var seams = lib.seams
        seams.route = route.seam
        scene.cataloguePlayer = SpanDACCataloguePlayer(seams: seams)
        scene.libraryOps = mac.client
        let read = DiscoverScene.RowsRead(try routing.choose(.discoverFeed, musicApp: { 0 }, source: { _ in 1 }))
        return Scene(scene: scene, routing: routing, status: status, actions: actions, lib: lib, mac: mac,
                     route: route, read: read)
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    private var albumRows: [DiscoverItem] {
        (1...3).map {
            DiscoverItem(id: "90\($0)", name: "T\($0)", subtitle: "A", url: nil, artworkURL: nil, detail: .song)
        }
    }
    private var albumItem: DiscoverItem {
        DiscoverItem(id: "1440000001", name: "Boom Bap", subtitle: "A", url: nil, artworkURL: nil,
                     detail: .album(trackCount: nil, year: nil, genre: nil))
    }

    func testASearchSongOnTheRouteIsAddedThenPlayedByIdentityThroughTheRoute() throws {
        let t = try makeScene(route: RouteRecorder())

        t.scene.playCatalogSlice(catalogIDs: ["901"], containerTitle: "Boom Bap", trackName: "T1",
                                 trackArtist: "A", read: t.read, searchOrigin: true)
        drain(t.actions)

        XCTAssertEqual(t.status.current()?.text, "Playing T1")
        XCTAssertEqual(t.mac.ops("slice.libraryAdd").first?["ids"] as? [String], ["901"])
        let pid = try XCTUnwrap(t.lib.owned["901"])
        XCTAssertEqual(t.route.plays.map(\.ids), [[pid]])
        XCTAssertEqual(t.route.plays.map(\.label), ["T1"])
        XCTAssertEqual(t.lib.allSeeded, [], "no temporary playlist was built")
        XCTAssertFalse(t.lib.allEvents.contains { $0.hasPrefix("build:") })
        XCTAssertEqual(t.lib.launches, 0, "no cleanup watcher was started")
    }

    func testASearchAlbumOnTheRouteIsAddedThenPlayedInOrderByIdentityWithNoTemporaryPlaylist() throws {
        let t = try makeScene(route: RouteRecorder())

        t.scene.playCatalogSlice(catalogIDs: ["901", "902", "903"], containerTitle: "Boom Bap", trackName: "T1",
                                 read: t.read,
                                 copy: discoverAlbumRequest(container: albumItem, rows: albumRows, selected: 0),
                                 albumTitle: "Boom Bap", searchOrigin: true)
        drain(t.actions)

        XCTAssertEqual(t.status.current()?.text, "Playing Boom Bap")
        XCTAssertEqual(t.mac.ops("slice.libraryAdd").first?["ids"] as? [String], ["901", "902", "903"])
        XCTAssertEqual(t.mac.ops("slice.libraryEnsurePlaylist").count, 0, "no temporary playlist was asked for")
        let pids = try ["901", "902", "903"].map { try XCTUnwrap(t.lib.owned[$0]) }
        XCTAssertEqual(t.route.plays.map(\.ids), [pids], "every song, in the album's order, by library identity")
        XCTAssertEqual(t.route.plays.map(\.label), ["Boom Bap"])
        XCTAssertEqual(t.lib.allSeeded, [])
        XCTAssertEqual(t.lib.launches, 0)
    }

    func testAnOwnedSongInTheAlbumIsNotAddedAgain() throws {
        let t = try makeScene(route: RouteRecorder())
        let owned = t.lib.own(catalogueID: "902", name: "T2", artist: "A", album: "Boom Bap")

        t.scene.playCatalogSlice(catalogIDs: ["901", "902", "903"], containerTitle: "Boom Bap", trackName: "T1",
                                 read: t.read,
                                 copy: discoverAlbumRequest(container: albumItem, rows: albumRows, selected: 0),
                                 albumTitle: "Boom Bap", searchOrigin: true)
        drain(t.actions)

        XCTAssertEqual(t.mac.ops("slice.libraryAdd").first?["ids"] as? [String], ["901", "903"])
        XCTAssertEqual(t.route.plays.first?.ids[1], owned)
        XCTAssertEqual(t.route.plays.first?.ids.count, 3)
    }

    func testAFailedLibraryAddStillRefusesAndPlaysNothingOnTheRoute() throws {
        for album in [false, true] {
            let t = try makeScene(route: RouteRecorder())
            t.mac.adds = [.refuse("no")]
            if album {
                t.scene.playCatalogSlice(catalogIDs: ["901", "902"], containerTitle: "Boom Bap", trackName: "T1",
                                         read: t.read,
                                         copy: discoverAlbumRequest(container: albumItem, rows: albumRows, selected: 0),
                                         albumTitle: "Boom Bap", searchOrigin: true)
            } else {
                t.scene.playCatalogSlice(catalogIDs: ["901"], containerTitle: "Boom Bap", trackName: "T1",
                                         trackArtist: "A", read: t.read, searchOrigin: true)
            }
            drain(t.actions)

            let said = t.status.current()?.text ?? ""
            XCTAssertTrue(said.contains("couldn't add"), "album=\(album): \(said)")
            XCTAssertEqual(t.route.plays.count, 0, "album=\(album): nothing was played")
        }
    }

    func testAnAlbumWithASongThatNeverAppearsPlaysNothing() throws {
        let t = try makeScene(route: RouteRecorder())
        t.lib.aliasVisible = false   // lookups never report an alias

        t.scene.playCatalogSlice(catalogIDs: ["901", "902"], containerTitle: "Boom Bap", trackName: "T1",
                                 read: t.read,
                                 copy: discoverAlbumRequest(container: albumItem, rows: albumRows, selected: 0),
                                 albumTitle: "Boom Bap", searchOrigin: true)
        drain(t.actions)

        XCTAssertTrue((t.status.current()?.text ?? "").contains("nothing was played"))
        XCTAssertEqual(t.route.plays.count, 0)
    }

    func testARouteThatCannotStartPlaysNothingAndSaysSo() throws {
        let route = RouteRecorder()
        route.startsOK = false
        let t = try makeScene(route: route)

        t.scene.playCatalogSlice(catalogIDs: ["901", "902"], containerTitle: "Boom Bap", trackName: "T1",
                                 read: t.read,
                                 copy: discoverAlbumRequest(container: albumItem, rows: albumRows, selected: 0),
                                 albumTitle: "Boom Bap", searchOrigin: true)
        drain(t.actions)

        XCTAssertEqual(t.status.current()?.text, macRouteSongPlayNotStarted)
    }

    /// Off the route (the seam present but not on) a song is the shipped
    /// bounded play: a container is built and the watcher started.
    func testASearchSongOffTheRouteIsTheShippedBoundedPlay() throws {
        let t = try makeScene(route: RouteRecorder(on: false))
        // Off the route a search play is refused by the coordinator, so the
        // Discover (non-search) play carries the same seam here.
        t.scene.playCatalogSlice(catalogIDs: ["901"], containerTitle: "Boom Bap", trackName: "T1",
                                 trackArtist: "A", read: t.read)
        drain(t.actions)

        XCTAssertEqual(t.route.plays.count, 0)
        XCTAssertEqual(t.lib.allSeeded, [try XCTUnwrap(t.lib.owned["901"])], "the container was built")
        XCTAssertEqual(t.lib.launches, 1, "the cleanup watcher was started")
    }

    // MARK: - TUI seam: the app queue is addressed by persistent ID

    func testTheTUIRouteSeamIsOffWithoutAMacRoutePlayer() {
        let seam = MacRouteSongPlay.tui(backend: AppleScriptBackend(), appQueue: AppQueueStore())
        XCTAssertFalse(seam.isOn(), "no player composed: every play is what it was")
    }

    // MARK: - CLI: Music-data album, artist and song on the route

    private final class Rig {
        var scripts: [String] = []
        var launches: [[String]] = []
        var launchOK = true
        var idsReply: String? = nil
        func run(_ s: String) -> String? {
            scripts.append(s)
            if s.contains("persistent ID of track") && !s.contains("make new playlist") { return idsReply }
            if s.contains("set ids to persistent ID") { return "A\u{1F}B\u{1F}C" }
            if s.contains("count of tracks") { return "3" }
            return ""
        }
        func launch(_ path: String, _ args: [String]) -> Bool { launches.append(args); return launchOK }
        var builtAContainer: Bool { scripts.contains { $0.contains("make new playlist") } }
        /// The reservation's fence, in a temp directory (never `~/.config/music`).
        let fenceDir = OutputLockTestSupport.tempDir()
        lazy var fence = RateFence(lock: OutputLock(path: fenceDir + "/output.lock", pollInterval: 0.001))
        func seam(on: Bool = true) -> MacRouteSongPlay {
            .cli(isOnRoute: { on }, launch: { [unowned self] in launch($0, $1) }, json: { false },
                 fence: { [unowned self] in fence })
        }
    }

    private let ids = ["00000000000000A1", "00000000000000A2", "00000000000000A3"]
    private func rows(_ n: Int) -> [LibraryAlbumRow] {
        (1...n).map {
            LibraryAlbumRow(index: $0 * 10, name: "T\($0)", artist: "A", albumArtist: "A",
                            cloudStatus: "subscription", disc: 1, track: $0)
        }
    }
    private func idsArgument(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--ids"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testACLIAlbumOnTheRouteStartsTheRunQueueRunnerAndBuildsNoContainer() {
        let rig = Rig()
        rig.idsReply = ids.joined(separator: "\u{1F}") + "\u{1F}"
        _ = MacRouteCLIStart.take()

        let out = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U", run: rig.run,
                                   launch: { _, _ in XCTFail("the watcher launched"); return true },
                                   route: rig.seam())

        XCTAssertEqual(out, .playing)
        XCTAssertFalse(rig.builtAContainer, "no temporary playlist")
        XCTAssertFalse(rig.scripts.contains { $0.contains("play playlist") })
        let read = rig.scripts.first { $0.contains("persistent ID of track") }
        XCTAssertTrue(read?.contains("track 10 of playlist \"Library\"") == true)
        XCTAssertTrue(read?.contains("track 30 of playlist \"Library\"") == true)
        XCTAssertEqual(rig.launches.count, 1)
        XCTAssertEqual(rig.launches.first?.first, "__run-queue")
        XCTAssertEqual(rig.launches.first.flatMap(idsArgument), ids.joined(separator: ","), "in play order")
        XCTAssertEqual(MacRouteCLIStart.take(),
                       macRoutePlayingLine(label: "Moon Safari", count: 3, json: false))
    }

    /// Fix round 1, finding 3: every CLI route play reserves the ordering for its
    /// runner before the spawn, so a newer command in the spawn gap is not overtaken.
    func testEveryCLIRoutePlayReservesTheFenceAndTheLeaseForItsRunner() throws {
        let rig = Rig()
        rig.idsReply = ids.joined(separator: "\u{1F}") + "\u{1F}"
        _ = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U", run: rig.run,
                             launch: { _, _ in XCTFail("the watcher launched"); return true }, route: rig.seam())
        let args = try XCTUnwrap(rig.launches.first)
        let fenceArg = try XCTUnwrap(args.firstIndex(of: "--fence").map { args[$0 + 1] }.flatMap(Int.init))
        let ownerArg = try XCTUnwrap(args.firstIndex(of: "--owner").map { args[$0 + 1] })
        XCTAssertEqual(try rig.fence.current(), fenceArg)
        XCTAssertEqual(rig.fence.leaseStatus(owner: ownerArg), .ours)
        XCTAssertEqual(idsArgument(args), ids.joined(separator: ","))
    }

    func testACLIArtistOnTheRouteStartsTheRunner() {
        let rig = Rig()
        rig.idsReply = ids.prefix(2).joined(separator: "\u{1F}")
        let tracks = [TrackListEntry(index: 4, name: "a", artist: "Air", isCurrent: false, album: nil),
                      TrackListEntry(index: 9, name: "b", artist: "Air", isCurrent: false, album: nil)]

        let out = playBoundedArtist(name: "Air", tracks: tracks, uuid: "U", run: rig.run,
                                    launch: { _, _ in XCTFail("the watcher launched"); return true },
                                    route: rig.seam())

        XCTAssertEqual(out, .playing)
        XCTAssertFalse(rig.builtAContainer)
        XCTAssertEqual(rig.launches.first?.first, "__run-queue")
        XCTAssertEqual(rig.launches.first.flatMap(idsArgument), ids.prefix(2).joined(separator: ","))
    }

    func testACLISongByIdentityOnTheRouteStartsTheRunnerWithThatOneSong() {
        let rig = Rig()
        _ = MacRouteCLIStart.take()

        let out = playBoundedSongByIdentifier(title: "Teardrop", identifier: "00000000000000a9", uuid: "U",
                                              run: rig.run, launch: { _, _ in XCTFail("watcher"); return true },
                                              route: rig.seam())

        XCTAssertEqual(out, .playing)
        XCTAssertFalse(rig.builtAContainer)
        XCTAssertEqual(rig.scripts, [], "no sweep, no read: the identity is already resolved")
        XCTAssertEqual(rig.launches.first.flatMap(idsArgument), "00000000000000A9")
        XCTAssertEqual(MacRouteCLIStart.take(), macRoutePlayingLine(label: "Teardrop", count: 1, json: false))
    }

    func testALocalSongLookupOnTheRoutePlaysTheSelectedRowByIdentity() {
        let rig = Rig()
        let out = playBoundedLocalSong(
            title: "T1", artist: nil, fetchRows: { _ in self.rows(1) },
            readIdentifier: { _ in "00000000000000B1" }, uuid: "U", run: rig.run,
            launch: { _, _ in XCTFail("watcher"); return true }, route: rig.seam())

        XCTAssertEqual(out, .playing)
        XCTAssertFalse(rig.builtAContainer)
        XCTAssertEqual(rig.launches.first.flatMap(idsArgument), "00000000000000B1")
    }

    func testOffTheRouteTheCLIPlaysAreUnchanged() {
        let rig = Rig()
        var watcher: [String]?
        let out = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U", run: rig.run,
                                   launch: { _, args in watcher = args; return true },
                                   route: rig.seam(on: false))

        XCTAssertEqual(out, .playing)
        XCTAssertTrue(rig.builtAContainer)
        XCTAssertTrue(rig.scripts.contains { $0.contains("play playlist") })
        XCTAssertEqual(rig.launches.count, 0, "no runner")
        XCTAssertNotNil(watcher, "the album watcher, as always")
        XCTAssertFalse(rig.scripts.contains { $0.contains("persistent ID of track") })
    }

    func testACLIPlayWhoseRunnerWillNotStartSaysSoAndPlaysNothing() {
        let rig = Rig()
        rig.idsReply = ids.joined(separator: "\u{1F}")
        rig.launchOK = false
        let out = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U", run: rig.run, route: rig.seam())
        XCTAssertEqual(out, .routeNotStarted)
        XCTAssertEqual(albumOutcomeMessage(out, title: "Moon Safari"), macRouteRunnerNotStartedMessage)
        XCTAssertFalse(rig.builtAContainer)
    }

    func testAnUnreadableOrShortIdentityReadStartsNothing() {
        for reply in [nil, "00000000000000A1", "not-an-id\u{1F}00000000000000A2\u{1F}00000000000000A3"] as [String?] {
            let rig = Rig()
            rig.idsReply = reply
            let out = playBoundedAlbum(title: "Moon Safari", rows: rows(3), uuid: "U", run: rig.run, route: rig.seam())
            XCTAssertEqual(out, .routeNotStarted, "reply \(String(describing: reply))")
            XCTAssertEqual(rig.launches.count, 0)
        }
    }

    func testTheIdentityReadScriptNamesEveryIndexInOrder() {
        let s = libraryPersistentIDsScript(indices: [4, 9])
        XCTAssertTrue(s.contains("persistent ID of track 4 of playlist \"Library\""))
        XCTAssertLessThan(s.range(of: "track 4 ")!.lowerBound, s.range(of: "track 9 ")!.lowerBound)
        XCTAssertFalse(s.contains("make new playlist"), "read-only")
    }

    /// The CLI's now line after a route start is the runner's "Playing ..." line,
    /// said once, and nothing is left for the next play.
    func testTheCLIPrintsTheRunnerLineOnceInPlaceOfTheNowRead() {
        _ = MacRouteCLIStart.take()
        let rig = Rig()
        XCTAssertTrue(rig.seam().play("Moon Safari", ["00000000000000A1"]))
        XCTAssertEqual(MacRouteCLIStart.take(), macRoutePlayingLine(label: "Moon Safari", count: 1, json: false))
        XCTAssertNil(MacRouteCLIStart.take())
    }
}
