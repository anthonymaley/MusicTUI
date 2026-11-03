// tools/music/Tests/MusicTests/DiscoverCatalogueSearchTests.swift
//
// Discover hosts the catalogue search (catalogue-search score, step S5, with
// Revision r2 items 1, 2, 3, 6 and 7). `/` opens a search box from any
// Discover level; Enter reads `slice.search` once, off the input loop, from
// SpanDAC on this Mac; results drill into an artist's albums and an album's
// tracks; plays go through Discover's own play and reach SOUND only on a
// SpanDAC output. On the MusicTUI output the coordinator refuses a play that
// came from search before anything is added, created, queued or played
// (ruling 2026-11-03 17:40).
//
// Every test drives the real scene over a real `RoutingCoordinator` and the
// SceneDataRig's fake SpanDAC clients (DiscoverDataRouteTests.swift), with
// FakeSpanDACMac and FakeAppleLibrary standing in for SpanDAC's library ops and
// Apple's Music app. No test reaches a real player, a socket, the keychain,
// the network or ~/.config/music.
import XCTest
@testable import music

/// Holds the Nth request of one op (by arrival) until released, and records
/// whether each held request has finished.
private final class OpGate {
    private let lock = NSLock()
    private var arrivals = 0
    private var gates: [Int: DispatchSemaphore] = [:]
    private var _finished: Set<Int> = []

    func hold(_ ordinal: Int) {
        lock.lock(); gates[ordinal] = DispatchSemaphore(value: 0); lock.unlock()
    }

    func release(_ ordinal: Int) {
        lock.lock(); let gate = gates[ordinal]; lock.unlock()
        gate?.signal()
    }

    var arrived: Int { lock.lock(); defer { lock.unlock() }; return arrivals }

    func finished(_ ordinal: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return _finished.contains(ordinal) }

    /// The rig's `during` hook: runs on the reading thread, outside the rig's lock.
    func arrive() {
        lock.lock(); let ordinal = arrivals; arrivals += 1; let gate = gates[ordinal]; lock.unlock()
        _ = gate?.wait(timeout: .now() + 10)
        lock.lock(); _finished.insert(ordinal); lock.unlock()
    }
}

final class DiscoverCatalogueSearchTests: XCTestCase {

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

    private static let statusWithArtists = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","title":"On SpanDAC","artist":"A","authorization":"authorized","contract":3,"capabilities":["search.artist","slice.artistAlbums"]}}"#

    /// Grouped on screen as: Artists (0), art1 (1), Albums (2), alb1 (3),
    /// Songs (4), s1 (5). The cursor opens on row 1.
    private static let searchRecords = """
    [{"kind":"artist","id":"art1","title":"Artist One"},
     {"kind":"album","id":"alb1","title":"Album One","subtitle":"Artist One"},
     {"kind":"song","id":"s1","title":"Song One","subtitle":"Artist One","album":"Album One"}]
    """

    private static func searchReply(_ records: String) -> String {
        #"{"ok":true,"op":"slice.search","records":\#(records)}"#
    }

    private static let artistAlbumsReply = """
    {"ok":true,"op":"slice.artistAlbums","records":[
      {"kind":"album","id":"alb2","title":"Album Two","subtitle":"Artist One"}],"more":false}
    """

    private static let albumOneIDs = ["a1", "a2", "a3"]

    private static func tracksReply(_ ids: [String]) -> String {
        let items = ids.map { #"{"id":"\#($0)","kind":"song","name":"Track \#($0)","subtitle":"Artist One"}"# }
        return #"{"ok":true,"op":"slice.containerTracks","items":[\#(items.joined(separator: ","))]}"#
    }

    /// SpanDAC's own queue refusals, as the app words them.
    static let tooManySentence = "A queue holds at most 100 songs in SpanDAC; 101 were requested."
    static let repeatedSentence = "That album holds one song twice, so SpanDAC can't play it."

    private struct Fixture {
        let rig: SceneDataRig
        let scene: DiscoverScene
        let routing: RoutingCoordinator
        let status: StatusStore
        let actions: ActionRunner
        let log: SceneLifecycleLog
        let mac: FakeSpanDACMac
        let lib: FakeAppleLibrary
        let searchGate: OpGate
    }

    private func lifecycle(_ log: SceneLifecycleLog) -> DiscoverLifecycleCoordinator {
        enum Stop: Error { case stop }
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, ids in log.create(ids); throw Stop.stop }, readCount: { _ in 0 },
            play: { log.play($0) }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }),
            readCountByPersistentID: { _ in 100 },
            confirmReadByPersistentID: { _ in discoverConfirmedToken },
            readContainerTrackIDsByPersistentID: { log.mac?.containerTrackIDs($0) },
            readTracksByPersistentID: { hexes in
                guard let mac = log.mac else { throw Stop.stop }
                return try mac.library.persistentIDReader.tracks(persistentIDs: hexes)
            })
        let c = DiscoverLifecycleCoordinator(seams: seams)
        c.completeLaunchSweep(.swept)
        return c
    }

    private func fixture(output: PlaybackMode, accepted: Bool = true, artists: Bool = true) -> Fixture {
        let rig = SceneDataRig(output: output, accepted: accepted)
        if artists { rig.replies["slice.status"] = Self.statusWithArtists }
        rig.responders["slice.search"] = { body in
            switch body["term"] as? String {
            case "first":
                return Self.searchReply(#"[{"kind":"song","id":"f1","title":"First Song","subtitle":"A"}]"#)
            case "second":
                return Self.searchReply(#"[{"kind":"song","id":"z2","title":"Second Song","subtitle":"A"}]"#)
            case "big":
                return Self.searchReply(#"[{"kind":"album","id":"big","title":"Big Album","subtitle":"A"}]"#)
            case "twice":
                return Self.searchReply(#"[{"kind":"album","id":"rep","title":"Twice Album","subtitle":"A"}]"#)
            default:
                return Self.searchReply(Self.searchRecords)
            }
        }
        rig.replies["slice.artistAlbums"] = Self.artistAlbumsReply
        rig.responders["slice.containerTracks"] = { body in
            switch body["id"] as? String {
            case "alb1": return Self.tracksReply(Self.albumOneIDs)
            case "alb2": return Self.tracksReply(["b1", "b2"])
            case "big":  return Self.tracksReply((1...101).map { "n\($0)" })
            case "rep":  return Self.tracksReply(["r1", "r2", "r1"])
            default:     return Self.tracksReply(["901", "902"])
            }
        }
        // SpanDAC's own bounds, as the app enforces them: never split here.
        rig.responders["slice.queue"] = { body in
            let ids = body["ids"] as? [String] ?? []
            if ids.count > 100 {
                return #"{"ok":false,"op":"slice.queue","error":{"kind":"bad_request","detail":"\#(Self.tooManySentence)"}}"#
            }
            if Set(ids).count != ids.count {
                return #"{"ok":false,"op":"slice.queue","error":{"kind":"repeated_title","detail":"\#(Self.repeatedSentence)"}}"#
            }
            return #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T1","artist":"A"}}"#
        }
        let gate = OpGate()
        rig.during["slice.search"] = { gate.arrive() }
        let routing = rig.coordinator()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let log = SceneLifecycleLog()
        let lib = FakeAppleLibrary()
        lib.catalogue["s1"] = ("Song One", "Artist One", "Album One")
        lib.catalogue["777"] = ("Rail Song", "Rail Artist", "Some Album")
        let mac = FakeSpanDACMac(library: lib)
        log.mac = mac
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: lifecycle(log), routing: routing,
                                  opener: SceneRecordingOpener())
        scene.cataloguePlayer = SpanDACCataloguePlayer(seams: lib.seams)
        scene.libraryOps = mac.client
        return Fixture(rig: rig, scene: scene, routing: routing, status: status, actions: actions,
                       log: log, mac: mac, lib: lib, searchGate: gate)
    }

    private func ticks(_ f: Fixture, until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline {
            _ = f.scene.tick(snapshot: idle)
            usleep(2_000)
        }
        XCTAssertTrue(done(), "timed out", file: file, line: line)
    }

    private func settle(_ f: Fixture, seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = f.scene.tick(snapshot: idle)
            usleep(2_000)
        }
    }

    private func loadRails(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        ticks(f, until: { !f.scene.rails.isEmpty }, file: file, line: line)
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    private func type(_ f: Fixture, _ text: String) {
        for c in text { _ = f.scene.handle(c == " " ? .space : .char(c)) }
    }

    private var model: (Fixture) -> CatalogueSearchModel? { { $0.scene.searchPane?.model } }

    /// `/`, the term, Enter, then ticks until the results are on screen.
    private func search(_ f: Fixture, _ term: String = "daft", file: StaticString = #filePath, line: UInt = #line) {
        _ = f.scene.handle(.char("/"))
        type(f, term)
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.model(f)?.results != nil }, file: file, line: line)
    }

    private var isSearch: (Fixture) -> Bool { { if case .search = $0.scene.currentLevel { return true }; return false } }

    /// Nothing added, created, ensured or played: no SpanDAC library op, no
    /// Music.app library event, nothing through the Discover lifecycle.
    private func assertNoLibraryOrPlay(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.mac.allOps, [], "a SpanDAC library op was sent", file: file, line: line)
        XCTAssertEqual(f.lib.events, [], "Music.app's library was touched", file: file, line: line)
        XCTAssertEqual(f.log.created, [], "the lifecycle created a container", file: file, line: line)
        XCTAssertEqual(f.log.played, [], "the lifecycle played", file: file, line: line)
        XCTAssertFalse(f.rig.sent.contains { $0.op.hasPrefix("slice.library") }, "a library op reached a client",
                       file: file, line: line)
    }

    // MARK: - `/` and Enter

    /// `/` opens the box and captures every key, including letters Discover
    /// and the shell use; Enter searches once, on a background thread, and the
    /// box stops capturing while the results show.
    func testSlashCapturesInputAndEnterSearchesOnceOffTheInputLoop() {
        let f = fixture(output: .source)
        loadRails(f)
        XCTAssertFalse(f.scene.capturesAllInput)

        XCTAssertEqual(f.scene.handle(.char("/")), .redraw)
        XCTAssertTrue(isSearch(f), "\(f.scene.currentLevel)")
        XCTAssertTrue(f.scene.capturesAllInput)
        XCTAssertEqual(shellRoute(for: .space, sceneCapturing: f.scene.capturesAllInput), .scene)
        type(f, "p r q j k / daft")
        XCTAssertEqual(model(f)?.text, "p r q j k / daft")
        let out = f.scene.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)
        XCTAssertTrue(out.contains(CatalogueSearchPane.boxPrefix), "the box is not drawn")

        f.searchGate.hold(0)
        _ = f.scene.handle(.enter)
        XCTAssertFalse(f.searchGate.finished(0), "Enter waited for the search: it ran on the input loop")
        XCTAssertFalse(f.scene.capturesAllInput, "the results still capture every key")
        f.searchGate.release(0)
        ticks(f, until: { self.model(f)?.results != nil })

        let searches = f.rig.sent("slice.search")
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(searches.first?.tag, "mac-data", "the search was not read from SpanDAC on this Mac")
        XCTAssertEqual(searches.first?.body["term"] as? String, "p r q j k / daft")
        XCTAssertEqual(f.rig.outputBuilt, [], "a read built an output client")
        XCTAssertEqual(model(f)?.results?.artists.map(\.id), ["art1"])
        XCTAssertEqual(model(f)?.results?.albums.map(\.id), ["alb1"])
        XCTAssertEqual(model(f)?.results?.songs.map(\.id), ["s1"])
    }

    // MARK: - Plays on a SpanDAC output

    /// Enter on a song: one `slice.queue` of exactly its id on the output,
    /// and no library op anywhere.
    func testASearchSongOnASpanDACOutputQueuesJustItsID() {
        let f = fixture(output: .source)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.down)                       // Song One
        XCTAssertEqual(model(f)?.selectedHit?.id, "s1")

        XCTAssertEqual(f.scene.handle(.enter), .push(.nowPlaying))
        drain(f.actions)

        let queues = f.rig.sent("slice.queue")
        XCTAssertEqual(queues.count, 1)
        XCTAssertEqual(queues.first?.body["ids"] as? [String], ["s1"])
        XCTAssertNotEqual(queues.first?.tag, "mac-data", "the play went to the data client, not the output")
        assertNoLibraryOrPlay(f)
    }

    /// `p` on an album: its tracks are read from SpanDAC on this Mac, then
    /// queued whole on the output. No library op.
    func testPOnASearchAlbumReadsItsTracksThenQueuesThem() {
        let f = fixture(output: .source)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)                       // Album One
        XCTAssertEqual(model(f)?.selectedHit?.id, "alb1")

        XCTAssertEqual(f.scene.handle(.char("p")), .push(.nowPlaying))
        drain(f.actions)

        let reads = f.rig.sent("slice.containerTracks")
        XCTAssertEqual(reads.map(\.tag), ["mac-data"])
        XCTAssertEqual(reads.first?.body["id"] as? String, "alb1")
        XCTAssertEqual(reads.first?.body["kind"] as? String, "album")
        XCTAssertEqual(f.rig.sent("slice.queue").map { $0.body["ids"] as? [String] ?? [] }, [Self.albumOneIDs])
        assertNoLibraryOrPlay(f)
    }

    /// Over SpanDAC's 100-song bound: every id is sent (never truncated) and
    /// SpanDAC's own sentence is what he reads.
    func testAnAlbumOverOneHundredSongsRefusesWithSpanDACsSentence() {
        let f = fixture(output: .source)
        loadRails(f)
        search(f, "big")
        _ = f.scene.handle(.char("p"))
        drain(f.actions)

        XCTAssertEqual((f.rig.sent("slice.queue").first?.body["ids"] as? [String])?.count, 101, "the album was cut")
        XCTAssertEqual(f.status.current()?.text, Self.tooManySentence)
        assertNoLibraryOrPlay(f)
    }

    /// A repeated id: sent as it is and refused in SpanDAC's own words.
    func testAnAlbumThatRepeatsASongRefusesWithSpanDACsSentence() {
        let f = fixture(output: .source)
        loadRails(f)
        search(f, "twice")
        _ = f.scene.handle(.char("p"))
        drain(f.actions)

        XCTAssertEqual(f.rig.sent("slice.queue").first?.body["ids"] as? [String], ["r1", "r2", "r1"])
        XCTAssertEqual(f.status.current()?.text, Self.repeatedSentence)
    }

    // MARK: - The MusicTUI output refuses at the coordinator

    func testOnTheMusicTUIOutputASearchSongRefusesBeforeAnyAdd() {
        let f = fixture(output: .musicApp)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.down)                       // Song One
        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, searchPlaysOnSpanDACOnly)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNoLibraryOrPlay(f)
    }

    func testOnTheMusicTUIOutputAWholeSearchAlbumRefusesBeforeAnyAdd() {
        let f = fixture(output: .musicApp)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)                       // Album One
        _ = f.scene.handle(.char("p"))
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, searchPlaysOnSpanDACOnly)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNoLibraryOrPlay(f)
    }

    /// A track of an album opened from search plays from the album's
    /// `.tracks` frame, which carries the search origin: refused too.
    func testOnTheMusicTUIOutputATrackOfASearchAlbumRefusesBeforeAnyAdd() {
        let f = fixture(output: .musicApp)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)                       // Album One
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.scene.trackRows.map(\.id) == Self.albumOneIDs })
        _ = f.scene.handle(.down)                       // a2
        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, searchPlaysOnSpanDACOnly)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNoLibraryOrPlay(f)
    }

    /// The control: an ordinary Discover rail song on the MusicTUI output
    /// with SpanDAC data still takes its old path (SpanDAC adds it, it plays).
    func testAnOrdinaryDiscoverPlayOnTheMusicTUIOutputStillTakesItsOldPath() {
        let f = fixture(output: .musicApp)
        f.rig.replies["slice.recommendations"] = """
        {"ok":true,"op":"slice.recommendations","rails":[{"title":"Songs For You","items":[
          {"id":"777","kind":"song","name":"Rail Song","subtitle":"Rail Artist"}]}]}
        """
        loadRails(f)
        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, "Playing Rail Song")
        XCTAssertEqual(f.mac.ops("slice.libraryAdd").first?["ids"] as? [String], ["777"])
    }

    /// A play pressed on the SpanDAC output, held behind another action,
    /// admitted after a switch to the MusicTUI output: refused, nothing added.
    /// The keypress stamp catches it first, before the search origin does.
    func testAHeldSearchPlayAdmittedAfterASwitchToTheMusicTUIOutputRefuses() throws {
        let f = fixture(output: .source)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.down)                       // Song One
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        _ = f.scene.handle(.enter)                      // queued behind the hold
        _ = try f.routing.switchMode(to: .musicApp, readiness: { .ready },
                                     pauseOutgoing: { _ in true }, dropQueue: { _ in })
        hold.signal()
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNoLibraryOrPlay(f)
    }

    /// The reverse: pressed on the MusicTUI output, admitted after a switch
    /// to a SpanDAC output, it obeys the keypress epoch and plays nothing.
    func testAHeldSearchPlayAdmittedAfterASwitchToASpanDACOutputPlaysNothing() throws {
        let f = fixture(output: .musicApp)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.down)                       // Song One
        let hold = DispatchSemaphore(value: 0)
        f.actions.run("hold") { _ = hold.wait(timeout: .now() + 5) }
        _ = f.scene.handle(.enter)
        _ = try f.routing.switchMode(to: .source, readiness: { .ready },
                                     pauseOutgoing: { _ in true }, dropQueue: { _ in })
        hold.signal()
        drain(f.actions)

        XCTAssertEqual(f.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(f.rig.sent("slice.queue").count, 0)
        assertNoLibraryOrPlay(f)
    }

    /// The coordinator itself: a search-origin play on the MusicTUI output
    /// never reaches its body, and admits no play; the same play without the
    /// flag reaches `.add` (control); on a SpanDAC output it reaches `source`.
    func testTheCoordinatorRefusesASearchOriginPlayOnTheMusicTUIOutputBeforeItsBody() throws {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let routing = rig.coordinator()
        var paths: [MusicTUIPlayPath] = []
        let serial = routing.playSerial

        XCTAssertThrowsError(try routing.perform(.discoverTrackPlay, expecting: routing.stamp,
                                                 origin: .spandacCatalogue, searchOrigin: true,
                                                 musicApp: { paths.append($0) },
                                                 source: { _ in XCTFail("source ran") }, unaffected: {})) {
            XCTAssertEqual(($0 as? ActionError)?.message, searchPlaysOnSpanDACOnly)
        }
        XCTAssertEqual(paths, [], "the MusicTUI body ran for a search play")
        XCTAssertEqual(routing.playSerial, serial, "a refused search play was admitted")

        try routing.perform(.discoverTrackPlay, expecting: routing.stamp, origin: .spandacCatalogue,
                            musicApp: { paths.append($0) }, source: { _ in }, unaffected: {})
        XCTAssertEqual(paths, [.add], "an ordinary Discover play lost its old path")

        let spandac = SceneDataRig(output: .source, accepted: true).coordinator()
        var sourced = 0
        try spandac.perform(.discoverPlayAll, expecting: spandac.stamp, origin: .spandacDiscoverContainer,
                            searchOrigin: true, musicApp: { _ in XCTFail("MusicTUI body ran") },
                            source: { _ in sourced += 1 }, unaffected: {})
        XCTAssertEqual(sourced, 1)
    }

    // MARK: - Web data

    /// MusicTUI's own data: `/` opens and says search needs SpanDAC; Enter
    /// reads nothing and no SpanDAC client is built.
    func testOnWebDataSlashOpensAndSaysSearchNeedsSpanDACWithNoSearch() {
        let f = fixture(output: .musicApp, accepted: false)
        settle(f, seconds: 0.1)
        _ = f.scene.handle(.char("/"))
        XCTAssertTrue(isSearch(f))
        let out = f.scene.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)
        XCTAssertTrue(out.contains(DiscoverScene.searchNeedsSpanDAC), "the box does not say why")

        type(f, "daft")
        _ = f.scene.handle(.enter)
        settle(f)

        XCTAssertEqual(f.rig.sent("slice.search").count, 0)
        XCTAssertEqual(f.rig.dataBuilt, 0, "a SpanDAC data client was built on web data")
        XCTAssertEqual(model(f)?.note, DiscoverScene.searchNeedsSpanDAC)
    }

    // MARK: - Drilling

    /// Enter on an album opens Discover's own `.tracks` level, read from
    /// SpanDAC on this Mac; Back returns to the results on the same row.
    func testEnterOnAnAlbumOpensItsTracksAndBackKeepsTheResultsCursor() {
        let f = fixture(output: .source)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)                       // Album One, row 3
        let cursor = model(f)?.cursor

        _ = f.scene.handle(.enter)
        guard case .tracks(let item) = f.scene.currentLevel else {
            return XCTFail("Enter on an album did not open its tracks: \(f.scene.currentLevel)")
        }
        XCTAssertEqual(item.id, "alb1")
        XCTAssertEqual(item.kind, .album)
        ticks(f, until: { f.scene.trackRows.map(\.id) == Self.albumOneIDs })
        XCTAssertEqual(f.rig.sent("slice.containerTracks").map(\.tag), ["mac-data"])
        XCTAssertFalse(f.scene.capturesAllInput)

        _ = f.scene.handle(.left)
        XCTAssertTrue(isSearch(f), "\(f.scene.currentLevel)")
        XCTAssertEqual(model(f)?.cursor, cursor)
        XCTAssertEqual(model(f)?.results?.albums.map(\.id), ["alb1"])
    }

    /// A track of a search album plays from here on a SpanDAC output.
    func testATrackOfASearchAlbumPlaysFromHereOnASpanDACOutput() {
        let f = fixture(output: .source)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.down)
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.scene.trackRows.map(\.id) == Self.albumOneIDs })
        _ = f.scene.handle(.down)                       // a2
        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.rig.sent("slice.queue").map { $0.body["ids"] as? [String] ?? [] }, [["a2", "a3"]])
        assertNoLibraryOrPlay(f)
    }

    /// Enter on an artist reads its albums; Esc goes back to the results,
    /// Esc again closes the search on the Discover level it was opened from.
    func testEnterOnAnArtistReadsItsAlbumsAndEscReturnsToTheOriginalLevel() {
        let f = fixture(output: .source)
        loadRails(f)
        _ = f.scene.handle(.down)                       // the second rail row
        let rootHint = f.scene.footerHint
        search(f)
        XCTAssertEqual(model(f)?.selectedHit?.id, "art1")

        _ = f.scene.handle(.enter)
        ticks(f, until: { self.model(f)?.artistAlbums != nil })
        let asks = f.rig.sent("slice.artistAlbums")
        XCTAssertEqual(asks.map(\.tag), ["mac-data"])
        XCTAssertEqual(asks.first?.body["id"] as? String, "art1")
        XCTAssertEqual(asks.first?.body["limit"] as? Int, 25)
        XCTAssertEqual(model(f)?.artistAlbums?.albums.map(\.id), ["alb2"])

        _ = f.scene.handle(.escape)                     // back to the results
        XCTAssertTrue(isSearch(f))
        XCTAssertNil(model(f)?.artist)
        _ = f.scene.handle(.escape)                     // closes the search
        XCTAssertEqual(f.scene.currentLevel, .root)
        XCTAssertNil(f.scene.searchPane)
        XCTAssertEqual(f.scene.footerHint, rootHint, "the root level lost its row")
        XCTAssertFalse(f.scene.capturesAllInput)
    }

    /// An album of an artist opens its tracks, and Back walks the chain:
    /// tracks, the artist's albums, the results.
    func testArtistAlbumTracksBackChainKeepsEachLevel() {
        let f = fixture(output: .source)
        loadRails(f)
        search(f)
        _ = f.scene.handle(.enter)                      // Artist One
        ticks(f, until: { self.model(f)?.artistAlbums != nil })
        _ = f.scene.handle(.enter)                      // Album Two
        ticks(f, until: { f.scene.trackRows.map(\.id) == ["b1", "b2"] })

        _ = f.scene.handle(.left)
        XCTAssertTrue(isSearch(f))
        XCTAssertEqual(model(f)?.artist?.id, "art1", "Back from the tracks lost the artist's albums")
        _ = f.scene.handle(.left)
        XCTAssertNil(model(f)?.artist)
        XCTAssertEqual(model(f)?.selectedHit?.id, "art1")
    }

    // MARK: - Answers that arrive late

    /// A data-source switch while a search is out: the search goes, its late
    /// answer is dropped, and he is told to search again.
    func testASearchResultFromBeforeADataSourceSwitchIsDroppedWithASentence() throws {
        let f = fixture(output: .source)
        loadRails(f)
        f.searchGate.hold(0)
        _ = f.scene.handle(.char("/"))
        type(f, "daft")
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.searchGate.arrived == 1 })

        _ = try f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = f.scene.tick(snapshot: idle)                // sees the new data source and reloads
        XCTAssertEqual(f.status.current()?.text, DiscoverScene.searchDataSourceChanged)
        f.searchGate.release(0)
        settle(f)

        XCTAssertFalse(isSearch(f), "the search survived a change of data source")
        XCTAssertNil(f.scene.searchPane?.model.results, "a result from the source just left was shown")
        XCTAssertFalse(f.scene.capturesAllInput)
    }

    /// A data-source switch while the box is open: the box goes with it, so
    /// it cannot keep eating the shell's keys.
    func testADataSourceSwitchWhileEditingReleasesTheKeys() throws {
        let f = fixture(output: .source)
        loadRails(f)
        _ = f.scene.handle(.char("/"))
        XCTAssertTrue(f.scene.capturesAllInput)

        _ = try f.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        _ = f.scene.tick(snapshot: idle)

        XCTAssertFalse(f.scene.capturesAllInput, "the box kept capturing after the data source changed")
        XCTAssertEqual(f.scene.currentLevel, .root)
    }

    /// Two searches, the first answered last: the second's results stay.
    func testTwoSearchesAnsweredOutOfOrderKeepTheNewer() {
        let f = fixture(output: .source)
        loadRails(f)
        f.searchGate.hold(0)
        _ = f.scene.handle(.char("/"))
        type(f, "first")
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.searchGate.arrived == 1 })

        _ = f.scene.handle(.char("/"))                  // reopens the box with "first"
        for _ in 0..<5 { _ = f.scene.handle(.char("\u{7F}")) }
        type(f, "second")
        _ = f.scene.handle(.enter)
        ticks(f, until: { self.model(f)?.results?.songs.map(\.id) == ["z2"] })

        f.searchGate.release(0)
        settle(f)
        XCTAssertEqual(model(f)?.results?.songs.map(\.id), ["z2"], "the older search's late answer replaced the newer")
        XCTAssertEqual(f.rig.sent("slice.search").count, 2)
    }

    /// Back (Esc) while a search is out: the search closes, and its late
    /// answer does not bring it back.
    func testBackDuringAPendingSearchClosesItAndTheLateAnswerIsDropped() {
        let f = fixture(output: .source)
        loadRails(f)
        f.searchGate.hold(0)
        _ = f.scene.handle(.char("/"))
        type(f, "daft")
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.searchGate.arrived == 1 })

        _ = f.scene.handle(.escape)
        XCTAssertEqual(f.scene.currentLevel, .root)
        f.searchGate.release(0)
        settle(f)

        XCTAssertEqual(f.scene.currentLevel, .root, "the late answer reopened the search")
        _ = f.scene.handle(.char("/"))
        XCTAssertNil(model(f)?.results, "a fresh box shows the abandoned search's results")
    }

    // MARK: - An older SpanDAC

    /// No `search.artist` + `slice.artistAlbums`: the request is today's,
    /// there is no Artists group, and the note says why.
    func testWithoutTheArtistCapabilityThereAreNoArtistsAndANote() {
        let f = fixture(output: .source, artists: false)
        loadRails(f)
        search(f)

        XCTAssertNil(f.rig.sent("slice.search").first?.body["artists"], "artists were asked of an older SpanDAC")
        XCTAssertEqual(model(f)?.results?.artists, [])
        XCTAssertFalse(model(f)?.rows.contains(.header("Artists")) ?? true)
        XCTAssertTrue(model(f)?.note?.contains(CatalogueSearchResults.artistsNeedNewerSpanDAC) ?? false,
                      model(f)?.note ?? "nil")
    }

    // MARK: - Hits as Discover rows

    func testAHitMapsToTheDiscoverRowItsPlayUses() {
        let album = CatalogueHit(kind: .album, id: "alb1", title: "Album One", subtitle: "Artist One", album: nil)
        let song = CatalogueHit(kind: .song, id: "s1", title: "Song One", subtitle: "Artist One", album: "Album One")
        let artist = CatalogueHit(kind: .artist, id: "art1", title: "Artist One", subtitle: nil, album: nil)

        XCTAssertEqual(DiscoverScene.discoverItem(for: album),
                       DiscoverItem(id: "alb1", name: "Album One", subtitle: "Artist One", url: nil, artworkURL: nil,
                                    detail: .album(trackCount: nil, year: nil, genre: nil)))
        XCTAssertEqual(DiscoverScene.discoverItem(for: song),
                       DiscoverItem(id: "s1", name: "Song One", subtitle: "Artist One", url: nil, artworkURL: nil,
                                    detail: .song))
        XCTAssertNil(DiscoverScene.discoverItem(for: artist), "an artist is not a Discover row")
    }

    // MARK: - Keys after close, and a feed that is not there

    /// Once the box closes, space and Tab are the shell's again, and
    /// Discover's own keys move its list.
    func testGlobalKeysWorkAgainAfterTheSearchCloses() {
        let f = fixture(output: .source)
        loadRails(f)
        _ = f.scene.handle(.char("/"))
        XCTAssertEqual(shellRoute(for: .space, sceneCapturing: f.scene.capturesAllInput), .scene)
        XCTAssertEqual(shellRoute(for: .ctrlC, sceneCapturing: f.scene.capturesAllInput), .quit)

        _ = f.scene.handle(.escape)                     // nothing searched: closes
        XCTAssertEqual(f.scene.currentLevel, .root)
        XCTAssertFalse(f.scene.capturesAllInput)
        XCTAssertEqual(shellRoute(for: .space, sceneCapturing: f.scene.capturesAllInput), .globals)
        XCTAssertEqual(shellRoute(for: .char("\t"), sceneCapturing: f.scene.capturesAllInput), .globals)
        let before = f.scene.footerHint
        _ = f.scene.handle(.down)
        XCTAssertNotEqual(f.scene.footerHint, before, "Discover's cursor did not move after the search closed")
    }

    /// The root feed failed: search still opens, finds, and an album from it
    /// opens and plays.
    func testSearchWorksWhileTheRootFeedHasFailed() {
        let f = fixture(output: .source)
        f.rig.replies["slice.recommendations"] =
            #"{"ok":false,"op":"slice.recommendations","error":{"kind":"unavailable","detail":"Apple Music isn't answering."}}"#
        ticks(f, until: { f.scene.loadFailure != nil })

        search(f)
        _ = f.scene.handle(.down)                       // Album One
        _ = f.scene.handle(.enter)
        ticks(f, until: { f.scene.trackRows.map(\.id) == Self.albumOneIDs })
        let out = f.scene.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)
        XCTAssertTrue(out.contains("Track a1"), "the album's tracks are hidden behind the feed's failure")
        _ = f.scene.handle(.enter)
        drain(f.actions)

        XCTAssertEqual(f.rig.sent("slice.queue").map { $0.body["ids"] as? [String] ?? [] }, [Self.albumOneIDs])
    }

    /// The root feed still loading: search opens and finds.
    func testSearchWorksWhileTheRootFeedIsLoading() {
        let f = fixture(output: .source)
        let feedHeld = DispatchSemaphore(value: 0)
        f.rig.during["slice.recommendations"] = { _ = feedHeld.wait(timeout: .now() + 5) }
        _ = f.scene.tick(snapshot: idle)                // starts the held feed read

        search(f)
        XCTAssertTrue(f.scene.rails.isEmpty, "the feed was not still loading")
        XCTAssertEqual(model(f)?.results?.songs.map(\.id), ["s1"])
        let out = f.scene.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)
        XCTAssertTrue(out.contains("Song One"), "the results are hidden behind the loading line")
        feedHeld.signal()
    }
}
