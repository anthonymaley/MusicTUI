// tools/music/Tests/MusicTests/DiscoverFromHereRoutingTests.swift
//
// Which Discover play takes the path on Apple's own copy, and that it runs in
// two phases (score step C6, design section 9 item 6, ruling D4).
//
// Only a Discover PLAYLIST with a `pl.` id, with SpanDAC data on the MusicTUI
// output, takes it. An album, a song on a rail, MusicTUI's own data and a
// SpanDAC output keep the path they ship with. Every test drives the real
// scene and a real `RoutingCoordinator` over temporary stores; the player, the
// SpanDAC ops and the scripts are fakes, and the external-call tripwire is
// armed throughout. Built and tested with fakes only.
import XCTest
@testable import music

final class DiscoverFromHereRoutingTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let playlistID = "pl.u-abc"
    private let title = "Boom Bap"

    override func setUp() {
        super.setUp()
        ExternalCallTripwire.shared.arm()
    }

    override func tearDown() {
        let escaped = ExternalCallTripwire.shared.disarm()
        XCTAssertEqual(escaped.count, 0, "a call escaped the fakes: \(escaped)")
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The five rows SpanDAC serves for any container here, with lengths.
    private var rows: [DiscoverItem] {
        (1...5).map {
            DiscoverItem(id: "90\($0)", name: "Song \($0)", subtitle: "Artist", url: nil, artworkURL: nil,
                         detail: .song, length: .milliseconds(200_000 + ($0 - 1) * 1_000))
        }
    }

    private static let tracksReply: String = {
        let items = (1...5).map {
            #"{"id":"90\#($0)","kind":"song","name":"Song \#($0)","subtitle":"Artist","duration_ms":\#(200_000 + ($0 - 1) * 1_000)}"#
        }
        return #"{"ok":true,"op":"slice.containerTracks","items":[\#(items.joined(separator: ","))]}"#
    }()

    private static func rail(_ items: String) -> String {
        #"{"ok":true,"op":"slice.recommendations","rails":[{"title":"Made For You","items":[\#(items)]}]}"#
    }
    private static let playlistRail = rail(#"{"id":"pl.u-abc","kind":"playlist","name":"Boom Bap","subtitle":"Apple Music Hip-Hop"}"#)
    private static let albumRail = rail(#"{"id":"1440000001","kind":"album","name":"Some Album","subtitle":"Artist"}"#)
    private static let songRail = rail(#"{"id":"777","kind":"song","name":"Rail Song","subtitle":"Rail Artist"}"#)

    private var playlistRow: DiscoverItem {
        DiscoverItem(id: playlistID, name: title, subtitle: nil, url: nil, artworkURL: nil,
                     detail: .playlist(description: nil))
    }

    private struct Fixture {
        let rig: SceneDataRig
        let scene: DiscoverScene
        let routing: RoutingCoordinator
        let status: StatusStore
        let actions: ActionRunner
        let world: DFH6World
        let lifecycle: DiscoverLifecycleCoordinator
        let log: SceneLifecycleLog
    }

    /// A lifecycle whose web-service and container seams only record, so a
    /// test can say the old paths were or were not taken. Its copy seams are
    /// the composed ones; toasts reach the status store as the shell's do.
    private func recordingLifecycle(_ log: SceneLifecycleLog, world: DFH6World,
                                    status: StatusStore) -> DiscoverLifecycleCoordinator {
        enum Stop: Error { case stop }
        var seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, ids in log.create(ids); throw Stop.stop }, readCount: { _ in 0 },
            play: { log.play($0) }, confirmRead: { _ in "" },
            post: { toast in
                switch toast {
                case .startupCleanup: break
                case .outcome(let outcome, let title):
                    let m = discoverToastMessage(for: outcome, title: title)
                    status.post(m.text, error: m.isError, untilStateChange: m.isError)
                case .progress(let text): status.post(text, ttl: 60)
                }
            },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }),
            readCountByPersistentID: { _ in 100 },
            confirmReadByPersistentID: { _ in discoverConfirmedToken },
            readContainerTrackIDsByPersistentID: { log.mac?.containerTrackIDs($0) },
            readTracksByPersistentID: { hexes in
                guard let mac = log.mac else { throw Stop.stop }
                return try mac.library.persistentIDReader.tracks(persistentIDs: hexes)
            })
        seams.copy = world.runtime.seams
        let coordinator = DiscoverLifecycleCoordinator(seams: seams)
        coordinator.completeLaunchSweep(.swept)
        return coordinator
    }

    /// `production`: the shell's own lifecycle factory (its real toast
    /// mapping); otherwise the recording one.
    private func fixture(output: PlaybackMode = .musicApp, accepted: Bool = true, rail: String = playlistRail,
                         production: Bool = false, api: RESTAPIBackend? = nil) -> Fixture {
        let rig = SceneDataRig(output: output, accepted: accepted)
        rig.replies["slice.recommendations"] = rail
        rig.replies["slice.containerTracks"] = Self.tracksReply
        let routing = rig.coordinator()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let log = SceneLifecycleLog()
        let world = DFH6World(rows: rows, selected: 0, spandacDataSelected: {
            if case .consistent(.spandacMac, _) = routing.selection { return true }
            return false
        })
        let lifecycle = production ? world.lifecycle(status: status)
                                   : recordingLifecycle(log, world: world, status: status)
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: api,
                                  lifecycle: lifecycle, routing: routing, opener: SceneRecordingOpener())
        return Fixture(rig: rig, scene: scene, routing: routing, status: status, actions: actions,
                       world: world, lifecycle: lifecycle, log: log)
    }

    private func loadRails(_ f: Fixture) {
        let deadline = Date().addingTimeInterval(5)
        while f.scene.rails.isEmpty && f.scene.loadFailure == nil && Date() < deadline {
            _ = f.scene.tick(snapshot: idle)
            usleep(2_000)
        }
        XCTAssertFalse(f.scene.rails.isEmpty, "the rails never loaded")
    }

    /// Enter on the first rail row, then wait for its track list.
    private func drillIn(_ f: Fixture) {
        loadRails(f)
        _ = f.scene.handle(.enter)
        let deadline = Date().addingTimeInterval(5)
        while f.scene.trackRows.isEmpty && Date() < deadline {
            _ = f.scene.tick(snapshot: idle)
            usleep(2_000)
        }
        XCTAssertEqual(f.scene.trackRows, rows, "the drill-in did not show the five rows")
    }

    /// Enter on row `selected` of the drilled-in track list, run to the end.
    private func enter(_ f: Fixture, row selected: Int) {
        f.world.player.trackK = DFH6World.copyTrack(matching: rows, selected: selected)
        _ = f.scene.handle(.home)
        for _ in 0..<selected { _ = f.scene.handle(.down) }
        _ = f.scene.handle(.enter)
        drain(f.actions)
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.enqueueQuiet { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "ActionRunner never drained")
    }

    /// Runs `body` on another thread; false when it had not returned in 2 s.
    private func elsewhere(_ body: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { body(); done.signal() }
        return done.wait(timeout: .now() + 2) == .success
    }

    private func assertCopyPathUntouched(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.world.ops.calls, [], file: file, line: line)
        XCTAssertEqual(f.world.requests, [], file: file, line: line)
        XCTAssertEqual(f.world.player.calls, [], file: file, line: line)
        XCTAssertEqual(f.world.scripts, [], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.world.directory.path),
                       "the journal was written", file: file, line: line)
        XCTAssertFalse(f.lifecycle.copyPlaySlotIsHeld, file: file, line: line)
    }

    // MARK: - Item 6: which play takes the path

    /// SpanDAC data, the MusicTUI output, a playlist: the copy play is
    /// reserved and run with the FULL rows and the cursor, for the first, a
    /// middle and the LAST row. Nothing goes to the web service, to SpanDAC's
    /// container or single-song ops, or to a SpanDAC player.
    func testEnterOnAPlaylistRowRunsTheCopyPlayWithTheFullRowsAndTheCursor() {
        for selected in [0, 2, 4] {
            let f = fixture()
            let mac = FakeSpanDACMac(library: FakeAppleLibrary())
            f.scene.libraryOps = mac.client
            f.log.mac = mac
            drillIn(f)

            enter(f, row: selected)

            XCTAssertEqual(f.world.requests, [DiscoverCopyRequest(playlistID: playlistID, playlistTitle: title,
                                                                  rows: rows, selected: selected)], "row \(selected)")
            XCTAssertEqual(f.world.ops.calls, ["copies:\(playlistID)", "add:\(playlistID)"], "row \(selected)")
            XCTAssertEqual(f.world.player.currentIndex, selected, "row \(selected)")
            XCTAssertEqual(f.world.entries().map(\.state), [.listening], "row \(selected)")
            XCTAssertEqual(f.status.current()?.text, "Playing \(title)", "row \(selected)")
            XCTAssertFalse(f.lifecycle.copyPlaySlotIsHeld)

            XCTAssertEqual(f.log.created, [], "the web-service create ran (row \(selected))")
            XCTAssertEqual(f.log.played, [], "the container play ran (row \(selected))")
            XCTAssertEqual(mac.ops("slice.libraryEnsurePlaylist").count, 0, "row \(selected)")
            XCTAssertEqual(mac.ops("slice.libraryAdd").count, 0, "the single-song add ran (row \(selected))")
            XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
            XCTAssertEqual(f.rig.outputBuilt, [])
            XCTAssertEqual(ExternalCallTripwire.shared.recorded.count, 0, "row \(selected)")
        }
    }

    /// `p` on a playlist rail row: the same path, from the top (k = 1).
    func testPOnAPlaylistRailRowRunsTheCopyPlayFromTheTop() {
        let f = fixture()
        loadRails(f)

        f.scene.playAllFromRail(playlistRow)
        drain(f.actions)

        XCTAssertEqual(f.world.requests, [DiscoverCopyRequest(playlistID: playlistID, playlistTitle: title,
                                                              rows: rows, selected: 0)])
        XCTAssertEqual(f.world.player.commands, ["playCopy"], "k = 1: no pause, no skip, no second play")
        XCTAssertEqual(f.world.entries().map(\.state), [.listening])
        XCTAssertEqual(f.log.created, [])
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
    }

    /// What a refused album play must leave behind: the refusal, lasting, and
    /// no library mutation and no play on any fake. Every SpanDAC op counts,
    /// not only the adds, because the refusal comes before the first of them.
    private func assertAlbumRefused(_ f: Fixture, mac: FakeSpanDACMac, lib: FakeAppleLibrary,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let shown = f.status.current()
        XCTAssertEqual(shown?.text, DiscoverScene.albumPlayRefused("Some Album"), file: file, line: line)
        XCTAssertEqual(shown?.isError, true, file: file, line: line)
        XCTAssertEqual(shown?.staysUntilStateChange, true, "a won't-play message lasts", file: file, line: line)
        XCTAssertEqual(mac.allOps, [], "SpanDAC's library ops were reached", file: file, line: line)
        XCTAssertEqual(lib.allEvents, [], "the library saw a write or a read", file: file, line: line)
        XCTAssertEqual(lib.allSeeded, [], file: file, line: line)
        XCTAssertEqual(lib.launches, 0, file: file, line: line)
        XCTAssertEqual(f.log.created, [], "the web-service playlist was made", file: file, line: line)
        XCTAssertEqual(f.log.played, [], "a container played", file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, file: file, line: line)
        XCTAssertEqual(f.rig.outputBuilt, [], file: file, line: line)
        assertCopyPathUntouched(f, file: file, line: line)
    }

    /// An album refuses (owner's ruling, after probe P-C showed a playlist
    /// made from catalogue ids adds its songs and keeps them): from the first
    /// row and a middle one, SpanDAC is asked nothing and nothing plays.
    func testEnterOnAnAlbumRowRefusesAndAddsNothing() {
        for selected in [0, 2] {
            let f = fixture(rail: Self.albumRail)
            let lib = FakeAppleLibrary()
            let mac = FakeSpanDACMac(library: lib)
            f.scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
            f.scene.libraryOps = mac.client
            f.log.mac = mac
            drillIn(f)

            enter(f, row: selected)

            assertAlbumRefused(f, mac: mac, lib: lib)
        }
    }

    /// The LAST row of an album is a one-song slice, which used to be added
    /// alone. It refuses too.
    func testTheLastRowOfAnAlbumRefusesAndAddsNothing() {
        let f = fixture(rail: Self.albumRail)
        let lib = FakeAppleLibrary()
        lib.catalogue["905"] = ("Song 5", "Artist", "Some Album")
        let mac = FakeSpanDACMac(library: lib)
        f.scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        f.scene.libraryOps = mac.client
        f.log.mac = mac
        drillIn(f)

        enter(f, row: 4)

        assertAlbumRefused(f, mac: mac, lib: lib)
    }

    /// `p` on an album rail row: the same refusal, after the track read.
    func testPOnAnAlbumRailRowRefusesAndAddsNothing() {
        let f = fixture(rail: Self.albumRail)
        let lib = FakeAppleLibrary()
        let mac = FakeSpanDACMac(library: lib)
        f.scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        f.scene.libraryOps = mac.client
        f.log.mac = mac
        loadRails(f)

        f.scene.playAllFromRail(f.scene.rails[0].items[0])
        drain(f.actions)

        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, 1, "the tracks were read")
        assertAlbumRefused(f, mac: mac, lib: lib)
    }

    /// A SpanDAC output is not a refused path: an album's slice is queued on
    /// the output as before, and no library op is sent.
    func testAnAlbumOnASpanDACOutputStillQueuesOnTheOutput() {
        let f = fixture(output: .networkSource(SceneDataRig.ipad), rail: Self.albumRail)
        drillIn(f)

        enter(f, row: 2)

        XCTAssertEqual(f.rig.sent("slice.queue").map(\.tag), ["output:\(SceneDataRig.ipad)"])
        XCTAssertEqual(f.rig.sent("slice.queue").first?.body["ids"] as? [String], ["903", "904", "905"])
        XCTAssertNotEqual(f.status.current()?.text, DiscoverScene.albumPlayRefused("Some Album"))
        assertCopyPathUntouched(f)
        XCTAssertEqual(f.log.created, [])
    }

    /// A song shown directly on a rail: the single-song path, as it ships.
    func testEnterOnARailSongKeepsTheSingleSongPath() {
        let f = fixture(rail: Self.songRail)
        let lib = FakeAppleLibrary()
        lib.catalogue["777"] = ("Rail Song", "Rail Artist", "Some Album")
        let mac = FakeSpanDACMac(library: lib)
        f.scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        f.scene.libraryOps = mac.client
        f.log.mac = mac
        loadRails(f)

        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, "Playing Rail Song")
        XCTAssertEqual(mac.ops("slice.libraryAdd").first?["ids"] as? [String], ["777"])
        assertCopyPathUntouched(f)
    }

    /// MusicTUI's own data: the shipped path, which ignores the copy request.
    func testAPlaylistUnderMusicTUIsOwnDataTakesTheShippedPath() {
        let f = fixture(accepted: false,
                        api: RESTAPIBackend(developerToken: "d", userToken: "u", storefront: "us"))
        let request = DiscoverCopyRequest(playlistID: playlistID, playlistTitle: title, rows: rows, selected: 1)

        f.scene.playCatalogSlice(catalogIDs: ["902", "903", "904", "905"], containerTitle: title,
                                 trackName: "Song 2", copy: request)
        drain(f.actions)

        XCTAssertEqual(f.log.created, [["902", "903", "904", "905"]], "the shipped web-service container")
        assertCopyPathUntouched(f)
        XCTAssertEqual(f.rig.sent.count, 0, "no SpanDAC was asked anything")
    }

    /// A SpanDAC output: the slice is queued on the OUTPUT, also from the
    /// last row (a one-row slice that now carries the container's origin).
    func testAPlaylistOnASpanDACOutputQueuesOnTheOutput() {
        for (selected, expected) in [(1, ["902", "903", "904", "905"]), (4, ["905"])] {
            let f = fixture(output: .networkSource(SceneDataRig.ipad))
            drillIn(f)

            enter(f, row: selected)

            XCTAssertEqual(f.rig.sent("slice.queue").map(\.tag), ["output:\(SceneDataRig.ipad)"])
            XCTAssertEqual(f.rig.sent("slice.queue").first?.body["ids"] as? [String], expected)
            assertCopyPathUntouched(f)
            XCTAssertEqual(f.log.created, [])
        }
    }

    /// A lifecycle with no copy seams (not wired) refuses rather than falling
    /// back to any other path.
    func testAPlaylistWithNoCopyWiringRefusesAndFallsBackToNothing() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        rig.replies["slice.recommendations"] = Self.playlistRail
        rig.replies["slice.containerTracks"] = Self.tracksReply
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let log = SceneLifecycleLog()
        enum Stop: Error { case stop }
        let unwired = DiscoverLifecycleCoordinator(seams: DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, ids in log.create(ids); throw Stop.stop }, readCount: { _ in 0 },
            play: { log.play($0) }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in })))
        unwired.completeLaunchSweep(.swept)
        let mac = FakeSpanDACMac(library: FakeAppleLibrary())
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: unwired, routing: rig.coordinator(), opener: SceneRecordingOpener())
        scene.libraryOps = mac.client

        scene.playAllFromRail(playlistRow)
        drain(actions)

        XCTAssertEqual(status.current()?.text, pickASpanDACOutput)
        XCTAssertEqual(log.created, [])
        XCTAssertEqual(log.played, [])
        XCTAssertEqual(mac.ops("slice.libraryEnsurePlaylist").count, 0)
        XCTAssertEqual(rig.sent("slice.queue").count, 0)
    }

    // MARK: - Two phases

    /// (iv) Phase A's branch makes no socket, AppleScript or journal call: the
    /// first fake is reached only after `perform` has returned, with the slot
    /// held and the boundary free on this very thread.
    func testPhaseAReachesNoFakeUntilPerformHasReturned() {
        let f = fixture(production: true)
        drillIn(f)
        var events: [String] = []
        var boundaryFreeAtFirst: Bool?
        var slotHeldAtFirst: Bool?
        var journalAtFirst: Bool?
        f.world.onFake = { name in
            if events.isEmpty {
                // Inside a `perform` branch this same-thread call throws the re-entry error.
                boundaryFreeAtFirst = (try? f.routing.choose(.discoverFeed, musicApp: { 0 }, source: { _ in 1 })) != nil
                slotHeldAtFirst = f.lifecycle.copyPlaySlotIsHeld
                journalAtFirst = FileManager.default.fileExists(atPath: f.world.directory.path)
            }
            events.append(name)
        }

        enter(f, row: 1)

        XCTAssertEqual(events.first, "ops.offers", "the capability read is phase B's first step")
        XCTAssertEqual(boundaryFreeAtFirst, true, "the first fake was reached inside the routing boundary")
        XCTAssertEqual(slotHeldAtFirst, true)
        XCTAssertEqual(journalAtFirst, false)
        XCTAssertEqual(f.world.entries().map(\.state), [.listening])
    }

    /// (i) A competing `choose`, and a transport `perform`, both return while
    /// the add is still in flight: the long wait does not hold the boundary.
    func testACompetingChooseAndATransportActionAreNotBlockedDuringTheAdd() {
        let f = fixture(production: true)
        drillIn(f)
        var chose: Bool?
        var transported: Bool?
        var ran = 0
        f.world.duringAdd = { [self] in
            chose = elsewhere {
                _ = try? f.routing.choose(.discoverFeed, musicApp: { 0 }, source: { _ in 1 })
            }
            transported = elsewhere {
                try? f.routing.perform(.playPause, musicApp: { ran += 1 }, source: { _ in }, unaffected: {})
            }
        }

        enter(f, row: 1)

        XCTAssertEqual(chose, true, "a `choose` waited on the add")
        XCTAssertEqual(transported, true, "a transport action waited on the add")
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(f.world.entries().map(\.state), [.listening], "a transport action does not supersede the play")
    }

    private func assertNothingPlayedAndTheCopyIsGone(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.world.player.commands, [], "no command reached the player", file: file, line: line)
        XCTAssertEqual(f.world.deletes, [DFH6World.hex], "the owned copy was deleted", file: file, line: line)
        XCTAssertEqual(f.world.entries().map(\.state), [.closed], file: file, line: line)
        XCTAssertEqual(f.world.shuffle, true, file: file, line: line)
        XCTAssertFalse(f.lifecycle.copyPlaySlotIsHeld, file: file, line: line)
    }

    /// (ii) An output switch commits while the add is in flight: nothing
    /// plays, the copy the add made is deleted, and he is told why.
    func testAnOutputSwitchBetweenThePhasesPlaysNothingAndDeletesTheCopy() {
        let f = fixture(production: true)
        drillIn(f)
        var switched: Bool?
        f.world.duringAdd = { [self] in
            switched = elsewhere {
                _ = try? f.routing.switchMode(to: .source, readiness: { .ready },
                                              pauseOutgoing: { _ in true }, dropQueue: { _ in })
            }
        }

        enter(f, row: 2)

        XCTAssertEqual(switched, true)
        XCTAssertEqual(f.routing.mode, .source, "the switch did not commit")
        assertNothingPlayedAndTheCopyIsGone(f)
        // His own status store has no switch stamp here, so the line is read as posted.
        XCTAssertEqual(f.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(f.status.current()?.staysUntilStateChange, true)
    }

    /// (ii) The same when he stops using SpanDAC's data instead.
    func testStoppingSpanDACDataBetweenThePhasesPlaysNothingAndDeletesTheCopy() {
        let f = fixture(production: true)
        drillIn(f)
        var stopped: Bool?
        f.world.duringAdd = { [self] in
            stopped = elsewhere {
                _ = try? f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
            }
        }

        enter(f, row: 2)

        XCTAssertEqual(stopped, true)
        XCTAssertEqual(f.routing.selection, .consistent(data: .open, output: .musicApp))
        assertNothingPlayedAndTheCopyIsGone(f)
        XCTAssertEqual(f.status.current()?.text, sourceChangedNothingPlayed)
    }

    /// (iii) A station play reaches the player while the add is in flight:
    /// the later play wins. Nothing of ours plays, the copy is deleted, and no
    /// error is posted.
    func testALaterPlayBetweenThePhasesSupersedesSilently() {
        let f = fixture(production: true)
        drillIn(f)
        var played: Bool?
        var stationRan = 0
        f.world.duringAdd = { [self] in
            played = elsewhere {
                try? f.routing.perform(.radioStationPlay, expecting: nil, origin: .spandacCatalogue,
                                       musicApp: { _ in stationRan += 1 }, source: { _ in }, unaffected: {})
            }
        }

        enter(f, row: 2)

        XCTAssertEqual(played, true)
        XCTAssertEqual(stationRan, 1)
        assertNothingPlayedAndTheCopyIsGone(f)
        XCTAssertNotEqual(f.status.current()?.isError, true, "a superseded play says nothing")
        XCTAssertNotEqual(f.status.current()?.text, sourceChangedNothingPlayed)
    }

    /// (v) A stale `expecting` still refuses in phase A, with nothing reserved.
    func testAStaleStampRefusesInPhaseAWithNothingReserved() {
        let f = fixture(production: true)
        drillIn(f)
        // The data source moves after the rows were read; no tick sees it.
        _ = try? f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(try? f.routing.acceptSpanDACData(readiness: { .ready }), .switched(to: .spandacMac))

        f.world.player.trackK = DFH6World.copyTrack(matching: rows, selected: 0)
        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, sourceChangedNothingPlayed)
        assertCopyPathUntouched(f)
    }

    /// (v) A throw after `.reserved` leaves the slot free; the other phase A
    /// answers are the score's.
    func testPhaseAGivesTheSlotBackWhenTheReservationThrows() {
        let f = fixture(production: true)
        let request = DiscoverCopyRequest(playlistID: playlistID, playlistTitle: title, rows: rows, selected: 0)

        // Outside a `perform` branch the real coordinator refuses to reserve.
        XCTAssertThrowsError(try discoverCopyPhaseA(request, lifecycle: f.lifecycle,
                                                    reservation: { try f.routing.reservationForThisBranch() }))
        XCTAssertFalse(f.lifecycle.copyPlaySlotIsHeld, "the slot leaked")

        // Inside one, it reserves; a second request then finds the slot busy.
        var first: DiscoverCopyPhaseA?
        XCTAssertNoThrow(try f.routing.perform(.discoverTrackPlay, expecting: nil, origin: .spandacDiscoverContainer,
            musicApp: { path in
                XCTAssertEqual(path, .addContainer)
                first = try discoverCopyPhaseA(request, lifecycle: f.lifecycle,
                                               reservation: { try f.routing.reservationForThisBranch() })
            }, source: { _ in }, unaffected: {}))
        XCTAssertEqual(first?.reservation,
                       RoutingReservation(epoch: f.routing.epoch, dataEpoch: f.routing.dataEpoch,
                                          playSerial: f.routing.playSerial))
        XCTAssertTrue(f.lifecycle.copyPlaySlotIsHeld)
        XCTAssertThrowsError(try discoverCopyPhaseA(request, lifecycle: f.lifecycle, reservation: { first!.reservation })) {
            XCTAssertEqual(($0 as? ActionError)?.message, discoverCopyBusyText(playlist: title))
        }
        XCTAssertTrue(f.lifecycle.copyPlaySlotIsHeld, "a busy answer must not release the holder's slot")
        f.lifecycle.cancelCopyPlay(first!.slot)

        // Exiting: nothing runs and nothing is said.
        f.lifecycle.closeAdmission()
        XCTAssertNil(try discoverCopyPhaseA(request, lifecycle: f.lifecycle, reservation: { first!.reservation }))
        assertCopyPathUntouched(f)
    }

    // MARK: - The gate

    /// `.holds` runs the body; a moved stamp, a later play, and a re-entry
    /// throw do not, and each is named.
    func testTheGateMapsTheReservationCheck() throws {
        let f = fixture(production: true)
        var reservation: RoutingReservation?
        try f.routing.perform(.discoverTrackPlay, expecting: nil, origin: .spandacDiscoverContainer,
                              musicApp: { _ in reservation = try f.routing.reservationForThisBranch() },
                              source: { _ in }, unaffected: {})
        let gate = discoverCopyGate(routing: f.routing, reservation: try XCTUnwrap(reservation))
        var ran = 0

        XCTAssertEqual(gate { ran += 1 }, .ran)
        XCTAssertEqual(ran, 1)

        // Re-entry: the gate called from inside a branch counts as moved.
        var inside: DiscoverCopyGateResult?
        try f.routing.perform(.playPause, musicApp: { inside = gate { ran += 1 } }, source: { _ in }, unaffected: {})
        XCTAssertEqual(inside, .sourceChanged)
        XCTAssertEqual(ran, 1)

        try f.routing.perform(.radioStationPlay, expecting: nil, origin: .spandacCatalogue,
                              musicApp: { _ in }, source: { _ in }, unaffected: {})
        XCTAssertEqual(gate { ran += 1 }, .superseded)

        _ = try f.routing.switchMode(to: .source, readiness: { .ready },
                                     pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(gate { ran += 1 }, .sourceChanged, "a moved stamp is named before a later play")
        XCTAssertEqual(ran, 1)
    }

    // MARK: - The shell's two hooks

    func testEnqueueQuietRunsOnTheSameSerialQueueAndPostsNothing() {
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        status.post("lasting", error: true, untilStateChange: true)
        var order: [String] = []
        let gate = DispatchSemaphore(value: 0)
        actions.run("Volume") { gate.wait(); order.append("first") }
        actions.enqueueQuiet { order.append("quiet") }
        gate.signal()
        actions.waitUntilIdle()

        XCTAssertEqual(order, ["first", "quiet"])
        XCTAssertEqual(status.current()?.text, "lasting", "a quiet action is not a state change")
    }

    /// The poller's hook runs first on every tick, whichever output is
    /// selected: here a blocked output, where the tick asks no player.
    func testThePollerCallsItsTickHookWhateverTheOutput() {
        let rig = SceneDataRig(output: .source, accepted: false)
        let routing = rig.coordinator()
        let poller = PlaybackPoller(store: NowPlayingStore(), backend: AppleScriptBackend(),
                                    appQueue: AppQueueStore(), queueStore: QueueStore(path: rig.dir + "/queue.json"),
                                    routing: routing)
        var ticks = 0
        poller.onTick = { ticks += 1 }

        poller.tick()
        poller.tick()

        XCTAssertEqual(ticks, 2)
        XCTAssertEqual(ExternalCallTripwire.shared.recorded.count, 0)
    }
}
