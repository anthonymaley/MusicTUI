// tools/music/Tests/MusicTests/DiscoverWebDataRefusalTests.swift
//
// Album-cleanup step N3 (owner ruling 2026-10-03 14:01): on MusicTUI's own
// (web) data with the MusicTUI output, EVERY Discover play that would build a
// temporary playlist from catalogue ids refuses with `webDataPlayRefused`,
// before any library call. That is Enter on a track inside a playlist or an
// album, `p` on a playlist or album rail row, and Enter on a rail song.
// Stations, SpanDAC data and a SpanDAC output are unchanged.
//
// Fakes only: the web feed, the lifecycle's create seam, the routing rig and
// the SpanDAC fakes. The external-call tripwire is armed throughout.
import XCTest
@testable import music

final class DiscoverWebDataRefusalTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

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

    private static let playlist = DiscoverItem(id: "pl.u-abc", name: "Boom Bap", subtitle: nil, url: nil,
                                               artworkURL: nil, detail: .playlist(description: nil))
    private static let album = DiscoverItem(id: "700", name: "An Album", subtitle: "A", url: nil,
                                            artworkURL: nil, detail: .album(trackCount: 3, year: 2001, genre: nil))
    private static let song = DiscoverItem(id: "777", name: "Rail Song", subtitle: "Rail Artist", url: nil,
                                           artworkURL: nil, detail: .song)
    private static let stationURL = "https://music.apple.com/us/station/apple-music-1/ra.978194965"
    private static let station = DiscoverItem(id: "ra.978194965", name: "Apple Music 1", subtitle: nil,
                                              url: stationURL, artworkURL: nil, detail: .station(isLive: true))

    private static let tracks = [
        DiscoverItem(id: "801", name: "S1", subtitle: "A", url: nil, artworkURL: nil, detail: .song),
        DiscoverItem(id: "802", name: "S2", subtitle: "A", url: nil, artworkURL: nil, detail: .song),
        DiscoverItem(id: "803", name: "S3", subtitle: "A", url: nil, artworkURL: nil, detail: .song),
    ]

    private final class Feed: DiscoverFeedReading {
        let railItems: [DiscoverItem]
        init(_ items: [DiscoverItem]) { railItems = items }
        func rails(limit: Int) throws -> [DiscoverRail] {
            [DiscoverRail(id: "r1", title: "For You", items: railItems, isRecentlyPlayed: false,
                          resourceTypes: ["songs"])]
        }
        func tracks(for item: DiscoverItem) throws -> [DiscoverItem] { DiscoverWebDataRefusalTests.tracks }
    }

    private final class Creates {
        private let lock = NSLock()
        private var stored: [[String]] = []
        func add(_ ids: [String]) { lock.lock(); stored.append(ids); lock.unlock() }
        var ids: [[String]] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private enum Stop: Error { case stop }

    private struct Fixture {
        let rig: SceneDataRig
        let scene: DiscoverScene
        let status: StatusStore
        let actions: ActionRunner
        let creates: Creates
        let opener: SceneRecordingOpener
    }

    /// `accepted: false` is MusicTUI's own (web) data; `true` is SpanDAC's.
    private func fixture(output: PlaybackMode = .musicApp, accepted: Bool = false,
                         items: [DiscoverItem], keys: Bool = true) -> Fixture {
        let rig = SceneDataRig(output: output, accepted: accepted)
        let routing = rig.coordinator()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let creates = Creates()
        let opener = SceneRecordingOpener()
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, ids in creates.add(ids); throw Stop.stop }, readCount: { _ in 0 },
            play: { _ in }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }))
        let lifecycle = DiscoverLifecycleCoordinator(seams: seams)
        lifecycle.completeLaunchSweep(.swept)
        let scene = DiscoverScene(
            feed: Feed(items), status: status, actions: actions,
            api: keys ? RESTAPIBackend(developerToken: "d", userToken: "u", storefront: "us") : nil,
            lifecycle: lifecycle, routing: routing, opener: opener)
        return Fixture(rig: rig, scene: scene, status: status, actions: actions, creates: creates, opener: opener)
    }

    private func tickUntil(_ s: DiscoverScene, _ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { _ = s.tick(snapshot: idle); usleep(1_000) }
    }

    private func loadRails(_ f: Fixture) {
        tickUntil(f.scene) { !f.scene.rails.isEmpty || f.scene.loadFailure != nil }
        XCTAssertFalse(f.scene.rails.isEmpty, "the rails never loaded")
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.enqueueQuiet { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "ActionRunner never drained")
    }

    /// Drill into the first rail row and wait for its tracks.
    private func drillIn(_ f: Fixture) {
        loadRails(f)
        _ = f.scene.handle(.enter)
        tickUntil(f.scene) { !f.scene.trackRows.isEmpty }
        XCTAssertEqual(f.scene.trackRows.map(\.id), ["801", "802", "803"])
    }

    private func assertRefused(_ f: Fixture, _ title: String, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.status.current()?.text, DiscoverScene.webDataPlayRefused(title), what,
                       file: file, line: line)
        XCTAssertEqual(f.status.current()?.isError, true, what, file: file, line: line)
        XCTAssertEqual(f.status.current()?.staysUntilStateChange, true, what, file: file, line: line)
        XCTAssertEqual(f.creates.ids, [], "the web-service create ran: \(what)", file: file, line: line)
        XCTAssertEqual(f.rig.sent.count, 0, "a SpanDAC request was sent: \(what)", file: file, line: line)
        XCTAssertEqual(f.opener.opened, [], what, file: file, line: line)
    }

    // MARK: - The sentence

    func testTheSentenceNamesTheTitle() {
        XCTAssertEqual(DiscoverScene.webDataPlayRefused("Boom Bap"),
                       "Nothing played: on MusicTUI's own data, playing 'Boom Bap' would add its songs to your "
                       + "library and leave them there, because MusicTUI can't tell which ones it added.")
    }

    // MARK: - Web data on the MusicTUI output refuses everything that builds a playlist

    /// Enter on a track inside a playlist: a middle row and the LAST row.
    func testEnterOnATrackInAPlaylistRefuses() {
        for downs in [0, 1, 2] {
            let f = fixture(items: [Self.playlist])
            drillIn(f)
            for _ in 0..<downs { _ = f.scene.handle(.down) }

            XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
            drain(f.actions)

            assertRefused(f, "Boom Bap", "playlist row \(downs)")
        }
    }

    /// Enter on a track inside an album, which refused before N3 with the
    /// album sentence: it now names the web-data one.
    func testEnterOnATrackInAnAlbumRefuses() {
        for downs in [0, 2] {
            let f = fixture(items: [Self.album])
            drillIn(f)
            for _ in 0..<downs { _ = f.scene.handle(.down) }

            XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
            drain(f.actions)

            assertRefused(f, "An Album", "album row \(downs)")
        }
    }

    /// `p` on a playlist rail row and on an album rail row.
    func testPOnAPlaylistAndOnAnAlbumRailRowRefuses() {
        for item in [Self.playlist, Self.album] {
            let f = fixture(items: [item])
            loadRails(f)

            f.scene.playAllFromRail(item)
            drain(f.actions)

            assertRefused(f, item.name, item.name)
        }
    }

    /// Enter on a song shown directly on a rail.
    func testEnterOnARailSongRefuses() {
        let f = fixture(items: [Self.song])
        loadRails(f)

        XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
        drain(f.actions)

        assertRefused(f, "Rail Song", "rail song")
    }

    /// The early sign-in guards sit in the callers and are untouched: with no
    /// keys the old sentence is still what a rail song says.
    func testWithoutKeysTheEarlySignInGuardStillSpeaks() {
        let f = fixture(items: [Self.song], keys: false)
        loadRails(f)

        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, DiscoverScene.signInToPlay)
        XCTAssertEqual(f.creates.ids, [])
    }

    // MARK: - Unchanged

    /// A station row still plays, by its share URL.
    func testAStationRowStillPlays() {
        let f = fixture(items: [Self.station])
        loadRails(f)

        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.opener.opened, ["music://music.apple.com/us/station/apple-music-1/ra.978194965"])
        XCTAssertEqual(f.status.current()?.text, "Playing Apple Music 1")
        XCTAssertEqual(f.creates.ids, [])
    }

    /// SpanDAC data on the MusicTUI output: a rail song still takes the
    /// single-song add path, not the refusal.
    func testSpanDACDataOnTheMusicTUIOutputReachesItsOwnBranch() {
        let f = fixture(accepted: true, items: [Self.song])
        // SpanDAC data serves its own rails over the wire, not the web feed.
        f.rig.replies["slice.recommendations"] = #"{"ok":true,"op":"slice.recommendations","rails":[{"title":"Made For You","items":[{"id":"777","kind":"song","name":"Rail Song","subtitle":"Rail Artist"}]}]}"#
        let lib = FakeAppleLibrary()
        lib.catalogue["777"] = ("Rail Song", "Rail Artist", "Some Album")
        let mac = FakeSpanDACMac(library: lib)
        f.scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        f.scene.libraryOps = mac.client
        loadRails(f)

        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, "Playing Rail Song")
        XCTAssertEqual(mac.ops("slice.libraryAdd").first?["ids"] as? [String], ["777"])
        XCTAssertEqual(f.creates.ids, [])
    }

    /// A SpanDAC output (which needs accepted SpanDAC data: a SpanDAC output
    /// with web data fails closed, so there is no such column): the slice
    /// queues on the output and the web-service create never runs.
    func testASpanDACOutputStillQueuesTheSlice() {
        let f = fixture(output: .networkSource(SceneDataRig.ipad), accepted: true, items: [Self.playlist])

        f.scene.playCatalogSlice(catalogIDs: ["802", "803"], containerTitle: "Boom Bap", trackName: "S2")
        drain(f.actions)

        XCTAssertEqual(f.rig.sent("slice.queue").map(\.tag), ["output:\(SceneDataRig.ipad)"])
        XCTAssertEqual(f.rig.sent("slice.queue").first?.body["ids"] as? [String], ["802", "803"])
        XCTAssertNotEqual(f.status.current()?.text, DiscoverScene.webDataPlayRefused("Boom Bap"))
        XCTAssertEqual(f.creates.ids, [])
    }
}
