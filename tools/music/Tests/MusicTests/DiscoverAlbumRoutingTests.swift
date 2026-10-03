// tools/music/Tests/MusicTests/DiscoverAlbumRoutingTests.swift
//
// Which Discover play takes the album clean-up path (album-cleanup score step
// W, design test 3). With SpanDAC data on the MusicTUI output, Enter on a song
// in a Discover album and `p` on an album rail row run the album transaction
// in two phases; the album's LAST row (a one-row slice) takes it too, never
// the single-song add and never SpanDAC's container play. MusicTUI's own data
// refuses with N3's sentence; a SpanDAC output queues on its own player; a
// `pl.` playlist keeps the copy path.
//
// Every test drives the real scene and a real `RoutingCoordinator` over
// temporary stores, and the production lifecycle factory over the album
// world's composed runtime (`WAlbumWorld`, DiscoverAlbumEndToEndTests.swift):
// the player, SpanDAC and every script are fakes, and the external-call
// tripwire is armed throughout. Built and tested with fakes only.
import XCTest
@testable import music

final class DiscoverAlbumRoutingTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let albumID = "1440000001"
    private let albumName = "Some Album"

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
    private static let albumRail = rail(#"{"id":"1440000001","kind":"album","name":"Some Album","subtitle":"Artist"}"#)
    private static let playlistRail = rail(#"{"id":"pl.u-abc","kind":"playlist","name":"Boom Bap","subtitle":"Apple Music Hip-Hop"}"#)

    private var albumRow: DiscoverItem {
        DiscoverItem(id: albumID, name: albumName, subtitle: "Artist", url: nil, artworkURL: nil,
                     detail: .album(trackCount: nil, year: nil, genre: nil))
    }

    private struct Fixture {
        let rig: SceneDataRig
        let scene: DiscoverScene
        let routing: RoutingCoordinator
        let actions: ActionRunner
        let world: WAlbumWorld
        let mac: FakeSpanDACMac
        let lib: FakeAppleLibrary
        var status: StatusStore { world.status }
        var lifecycle: DiscoverLifecycleCoordinator { world.lifecycle }
    }

    private func fixture(output: PlaybackMode = .musicApp, accepted: Bool = true, rail: String = albumRail,
                         api: RESTAPIBackend? = nil) -> Fixture {
        let rig = SceneDataRig(output: output, accepted: accepted)
        rig.replies["slice.recommendations"] = rail
        rig.replies["slice.containerTracks"] = Self.tracksReply
        let routing = rig.coordinator()
        let world = WAlbumWorld(rows: rows, spandacDataSelected: {
            if case .consistent(.spandacMac, _) = routing.selection { return true }
            return false
        })
        let actions = ActionRunner(status: world.status)
        let scene = DiscoverScene(feed: nil, status: world.status, actions: actions, api: api,
                                  lifecycle: world.lifecycle, routing: routing, opener: SceneRecordingOpener())
        // The OLD paths' SpanDAC: the single-song add and SpanDAC's container
        // play would reach this, never the album world.
        let lib = FakeAppleLibrary()
        for row in rows { lib.catalogue[row.id] = (row.name, "Artist", albumName) }
        let mac = FakeSpanDACMac(library: lib)
        scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        scene.libraryOps = mac.client
        return Fixture(rig: rig, scene: scene, routing: routing, actions: actions, world: world, mac: mac, lib: lib)
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

    /// The old album paths were not taken: no single-song add, no SpanDAC
    /// container play, nothing queued on a SpanDAC output.
    private func assertNoOldPath(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.mac.ops("slice.libraryAdd").count, 0, "the single-song add ran", file: file, line: line)
        XCTAssertEqual(f.mac.ops("slice.libraryEnsurePlaylist").count, 0, "SpanDAC's container play ran",
                       file: file, line: line)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0, file: file, line: line)
        XCTAssertEqual(f.rig.outputBuilt, [], file: file, line: line)
    }

    /// The album path was not taken: no relations read, no ensure, no journal.
    private func assertAlbumPathUntouched(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.world.relations.calls, [], file: file, line: line)
        XCTAssertEqual(f.world.library.calls, [], file: file, line: line)
        XCTAssertEqual(f.world.albumRequests, [], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.world.directory.path),
                       "the journal was written", file: file, line: line)
        XCTAssertFalse(f.lifecycle.copyPlaySlotIsHeld, file: file, line: line)
    }

    /// The album transaction ran for exactly `slice`, and he heard it.
    private func assertAlbumPlayed(_ f: Fixture, slice: [DiscoverItem],
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.world.albumRequests,
                       [DiscoverCopyRequest(playlistID: albumID, playlistTitle: albumName, rows: slice,
                                            selected: 0, kind: .albumContainer)], file: file, line: line)
        let entry = f.world.entry()
        XCTAssertEqual(entry?.kind, .albumContainer, file: file, line: line)
        XCTAssertEqual(entry?.playlistID, albumID, file: file, line: line)
        XCTAssertEqual(entry?.songs?.map(\.catalogueID), slice.map(\.id), file: file, line: line)
        XCTAssertEqual(entry?.state, .listening, file: file, line: line)
        XCTAssertEqual(f.world.library.calls.filter { $0.hasPrefix("ensure:") }.count, 1, file: file, line: line)
        XCTAssertTrue(f.world.library.calls.first?.hasSuffix(":" + slice.map(\.id).joined(separator: ",")) == true,
                      "the ensure carries the slice", file: file, line: line)
        XCTAssertEqual(f.status.current()?.text, "Playing " + discoverAlbumPlayingTail(song: slice[0].name),
                       file: file, line: line)
        XCTAssertFalse(f.lifecycle.copyPlaySlotIsHeld, file: file, line: line)
    }

    // MARK: - Design test 3

    /// The album's LAST row is a one-row slice: it reaches the copy-play slot
    /// as an album request and runs the album transaction, never `.add` and
    /// never `requestSpanDACPlay`.
    func testTheLastRowOfAnAlbumTakesTheAlbumPathNeverTheSingleSongAdd() {
        let f = fixture()
        drillIn(f)

        enter(f, row: 4)

        assertAlbumPlayed(f, slice: [rows[4]])
        assertNoOldPath(f)
        XCTAssertEqual(f.lib.launches, 0)
        XCTAssertEqual(ExternalCallTripwire.shared.recorded.count, 0)
    }

    /// Enter on the first and a middle row: the album path, from that row to
    /// the album's end (the FULL rows and the cursor became that slice).
    func testEnterOnAnAlbumSongRunsTheAlbumPathFromThatRow() {
        for selected in [0, 2] {
            let f = fixture()
            drillIn(f)

            enter(f, row: selected)

            assertAlbumPlayed(f, slice: Array(rows[selected...]))
            assertNoOldPath(f)
        }
    }

    /// `p` on an album rail row: the album path over every row, `selected = 0`.
    func testPOnAnAlbumRailRowRunsTheAlbumPathFromTheTop() {
        let f = fixture()
        loadRails(f)

        f.scene.playAllFromRail(f.scene.rails[0].items[0])
        drain(f.actions)

        XCTAssertEqual(f.rig.sent("slice.containerTracks").count, 1, "the tracks were read")
        assertAlbumPlayed(f, slice: rows)
        assertNoOldPath(f)
    }

    /// MusicTUI's own data: N3's sentence, before any album op or playlist.
    func testAnAlbumOnWebDataRefusesWithTheWebDataSentence() {
        let f = fixture(accepted: false, api: RESTAPIBackend(developerToken: "d", userToken: "u", storefront: "us"))

        f.scene.playCatalogSlice(catalogIDs: ["903", "904", "905"], containerTitle: albumName, trackName: "Song 3",
                                 copy: discoverAlbumRequest(container: albumRow, rows: rows, selected: 2),
                                 albumTitle: DiscoverScene.catalogueAlbumTitle(albumRow))
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, DiscoverScene.webDataPlayRefused(albumName))
        assertAlbumPathUntouched(f)
        XCTAssertEqual(f.rig.sent.count, 0, "no SpanDAC was asked anything")
    }

    /// A SpanDAC output: the album's slice reaches `playCatalogue` on the
    /// output, unchanged, and nothing of the album path runs.
    func testAnAlbumOnASpanDACOutputStillQueuesOnTheOutput() {
        let f = fixture(output: .networkSource(SceneDataRig.ipad))
        drillIn(f)

        enter(f, row: 2)

        XCTAssertEqual(f.rig.sent("slice.queue").map(\.tag), ["output:\(SceneDataRig.ipad)"])
        XCTAssertEqual(f.rig.sent("slice.queue").first?.body["ids"] as? [String], ["903", "904", "905"])
        assertAlbumPathUntouched(f)
        XCTAssertEqual(f.mac.allOps, [])
    }

    /// A `pl.` playlist still takes the copy path, not the album one.
    func testACataloguePlaylistStillTakesTheCopyPath() {
        let f = fixture(rail: Self.playlistRail)
        drillIn(f)

        enter(f, row: 1)

        XCTAssertEqual(f.world.ops.calls.first, "copies:pl.u-abc", "the copy path's first SpanDAC read")
        XCTAssertEqual(f.world.relations.calls, [])
        XCTAssertEqual(f.world.library.calls, [])
        XCTAssertEqual(f.world.albumRequests, [])
        XCTAssertFalse(f.world.entries().contains { $0.kind == .albumContainer })
        assertNoOldPath(f)
    }

    /// A SpanDAC without the three album capabilities: the album path's
    /// preflight refuses with the update sentence (design test 2), with no
    /// ensure, no journal write, and no fall back to any other path.
    func testAnAlbumWithoutTheCapabilitiesRefusesAndFallsBackToNothing() {
        let f = fixture()
        f.world.relations.offers = false
        drillIn(f)

        enter(f, row: 1)

        XCTAssertEqual(f.status.current()?.text, updateSpanDACToPlayOnMusicTUI)
        XCTAssertEqual(f.world.relations.calls, [], "only the capability was read")
        XCTAssertEqual(f.world.library.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.world.directory.path), "the journal was written")
        XCTAssertFalse(f.lifecycle.copyPlaySlotIsHeld)
        assertNoOldPath(f)
    }
}
