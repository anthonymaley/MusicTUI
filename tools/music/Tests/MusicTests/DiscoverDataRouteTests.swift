// tools/music/Tests/MusicTests/DiscoverDataRouteTests.swift
//
// Discover, Radio and Now on two axes (score: data route and output, step 5).
// Where MusicTUI's music DATA comes from and where its SOUND goes are separate
// selections: Discover's rails and Radio's lists follow the DATA selection
// (always SpanDAC on this Mac once accepted, whatever the output), while Now,
// the poller and transport follow the OUTPUT only.
//
// Every store is an explicit temp path and every client a fake that answers by
// op and records which client it is. No test reaches a real player, Apple's
// Music app, the network, the library or ~/.config/music (`HOME=` would not
// isolate it: NSHomeDirectory ignores it).
import XCTest
@testable import music

/// A coordinator with a real data store over temp files, and counting client
/// factories whose transports answer by op. `mac-data` is the DATA client
/// (SpanDAC on this Mac); `output:<mode>` is an OUTPUT client.
final class SceneDataRig {
    static let ipad = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"

    let dir: String
    let modes: PlaybackModeStore
    let data: DataProviderStore

    private let lock = NSLock()
    private var _outputBuilt: [PlaybackMode] = []
    private var _dataBuilt = 0
    private var _sent: [(tag: String, op: String, body: [String: Any])] = []
    var outputBuilt: [PlaybackMode] { lock.lock(); defer { lock.unlock() }; return _outputBuilt }
    var dataBuilt: Int { lock.lock(); defer { lock.unlock() }; return _dataBuilt }
    var sent: [(tag: String, op: String, body: [String: Any])] {
        lock.lock(); defer { lock.unlock() }; return _sent
    }
    func sent(_ op: String) -> [(tag: String, op: String, body: [String: Any])] { sent.filter { $0.op == op } }

    /// Replies by op. Missing ops answer with a refusal naming the op.
    var replies: [String: String] = [
        "slice.recommendations": """
        {"ok":true,"op":"slice.recommendations","rails":[{"title":"Stations For You","items":[
          {"id":"ra.978194965","kind":"station","name":"Apple Music 1"},
          {"id":"pl.u-abc","kind":"playlist","name":"Boom Bap","subtitle":"Apple Music Hip-Hop"}]}]}
        """,
        "slice.containerTracks": """
        {"ok":true,"op":"slice.containerTracks","items":[
          {"id":"901","kind":"song","name":"T1","subtitle":"A"},
          {"id":"902","kind":"song","name":"T2","subtitle":"A"}]}
        """,
        "slice.station": """
        {"ok":true,"op":"slice.station","station":{"id":"ra.978194965","name":"Apple Music 1",
          "url":"https://music.apple.com/us/station/apple-music-1/ra.978194965"}}
        """,
        "slice.liveStations": """
        {"ok":true,"op":"slice.liveStations","stations":[{"id":"ra.978194965","name":"Apple Music 1",
          "url":"https://music.apple.com/us/station/apple-music-1/ra.978194965","is_live":true}]}
        """,
        "slice.personalStations": #"{"ok":true,"op":"slice.personalStations","stations":[]}"#,
        "slice.status": #"{"ok":true,"op":"slice.status","status":{"playback":"playing","title":"On SpanDAC","artist":"A","authorization":"authorized","contract":3,"capabilities":[]}}"#,
        "slice.queue": #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T1","artist":"A"}}"#,
        "slice.playStation": #"{"ok":true,"op":"slice.playStation","status":{"playback":"playing","title":"Apple Music 1","artist":""}}"#,
    ]
    /// Runs inside the transport before it answers `op`, on the caller's
    /// thread: how a test lands a switch in the middle of a round trip.
    var during: [String: () -> Void] = [:]

    init(output: PlaybackMode, accepted: Bool) {
        dir = NSTemporaryDirectory() + "music-scene-data-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        modes = PlaybackModeStore(path: (dir as NSString).appendingPathComponent("mode.json"))
        modes.set(output)
        data = DataProviderStore(path: (dir as NSString).appendingPathComponent("data.json"))
        if accepted { XCTAssertTrue(data.accept()) }
    }

    func coordinator() -> RoutingCoordinator {
        RoutingCoordinator(store: modes, surface: .tui, dataStore: data,
                           makeSourceFor: { self.makeOutput($0) },
                           makeDataClient: { self.makeData() },
                           starter: NeverStartsMacSpanDAC())
    }

    func makeOutput(_ mode: PlaybackMode) -> SourceAppClient {
        lock.lock(); _outputBuilt.append(mode); lock.unlock()
        return client(mode.networkSourceID.map { "output:\($0)" } ?? "output:\(mode.storedValue)")
    }

    private func makeData() -> SourceAppClient {
        lock.lock(); _dataBuilt += 1; lock.unlock()
        return client("mac-data")
    }

    private func client(_ tag: String) -> SourceAppClient {
        SourceAppClient(path: "/nonexistent/\(tag)", transport: { [self] _, line in
            let body = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
            let op = body["op"] as? String ?? ""
            lock.lock(); _sent.append((tag, op, body)); let hook = during[op]; lock.unlock()
            hook?()
            lock.lock(); let reply = replies[op]; lock.unlock()
            return reply ?? #"{"ok":false,"op":"?","error":{"kind":"bad_request","detail":"unexpected op"}}"#
        })
    }
}

/// Records what a station play opened.
final class SceneRecordingOpener: Opener {
    private let lock = NSLock()
    private var _opened: [String] = []
    var opened: [String] { lock.lock(); defer { lock.unlock() }; return _opened }
    func open(_ url: String) throws { lock.lock(); _opened.append(url); lock.unlock() }
}

/// Counts what reached the Discover lifecycle's seams.
final class SceneLifecycleLog {
    private let lock = NSLock()
    private var _created: [[String]] = []
    var created: [[String]] { lock.lock(); defer { lock.unlock() }; return _created }
    func create(_ ids: [String]) { lock.lock(); _created.append(ids); lock.unlock() }
}

final class DiscoverDataRouteTests: XCTestCase {

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func lifecycle(_ log: SceneLifecycleLog) -> DiscoverLifecycleCoordinator {
        enum Stop: Error { case stop }
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, ids in log.create(ids); throw Stop.stop }, readCount: { _ in 0 },
            play: { _ in }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }))
        let c = DiscoverLifecycleCoordinator(seams: seams)
        c.completeLaunchSweep(.swept)
        return c
    }

    private struct Scene {
        let scene: DiscoverScene
        let routing: RoutingCoordinator
        let status: StatusStore
        let actions: ActionRunner
        let opener: SceneRecordingOpener
        let log: SceneLifecycleLog
    }

    /// No web-service feed and no REST backend: SpanDAC data needs no key.
    private func scene(_ rig: SceneDataRig) -> Scene {
        let routing = rig.coordinator()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let opener = SceneRecordingOpener()
        let log = SceneLifecycleLog()
        let scene = DiscoverScene(feed: nil, status: status, actions: actions, api: nil,
                                  lifecycle: lifecycle(log), routing: routing, opener: opener)
        return Scene(scene: scene, routing: routing, status: status, actions: actions, opener: opener, log: log)
    }

    private func loadRails(_ s: Scene) {
        let deadline = Date().addingTimeInterval(5)
        while s.scene.rails.isEmpty && s.scene.loadFailure == nil && Date() < deadline {
            _ = s.scene.tick(snapshot: idle)
            usleep(2_000)
        }
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    private var playlistRow: DiscoverItem {
        DiscoverItem(id: "pl.u-abc", name: "Boom Bap", subtitle: nil, url: nil, artworkURL: nil,
                     detail: .playlist(description: nil))
    }

    // MARK: - The door

    /// The tab opens on accepted SpanDAC data with no user token, whatever the
    /// output; a blocked output and open data still need the sign-in.
    func testDiscoverOpensWithSpanDACDataWithoutAUserToken() {
        XCTAssertTrue(discoverTabAdmitted(selection: .consistent(data: .spandacMac, output: .musicApp),
                                          hasUserToken: false))
        XCTAssertTrue(discoverTabAdmitted(selection: .consistent(data: .spandacMac, output: .source),
                                          hasUserToken: false))
        XCTAssertTrue(discoverTabAdmitted(selection: .consistent(data: .spandacMac,
                                                                 output: .networkSource(SceneDataRig.ipad)),
                                          hasUserToken: false))
        XCTAssertFalse(discoverTabAdmitted(selection: .consistent(data: .open, output: .musicApp),
                                           hasUserToken: false))
        XCTAssertFalse(discoverTabAdmitted(selection: .outputBlocked(stored: .source), hasUserToken: false),
                       "a blocked output reads open data, which needs the sign-in")
        XCTAssertTrue(discoverTabAdmitted(selection: .outputBlocked(stored: .source), hasUserToken: true))
        XCTAssertTrue(discoverTabAdmitted(selection: .consistent(data: .open, output: .musicApp),
                                          hasUserToken: true))
    }

    // MARK: - Reads follow the data

    /// With accepted data the rails come from SpanDAC on this Mac, on the
    /// MusicTUI output and on a network SpanDAC output alike; no output client
    /// is built for a read, and the scene never shows the sign-in line.
    func testDiscoverRailsComeFromTheMacWhateverTheOutput() {
        for output in [PlaybackMode.musicApp, .source, .networkSource(SceneDataRig.ipad)] {
            let rig = SceneDataRig(output: output, accepted: true)
            let s = scene(rig)
            loadRails(s)

            XCTAssertEqual(s.scene.rails.map(\.title), ["Stations For You"], "\(output)")
            XCTAssertEqual(rig.sent("slice.recommendations").map(\.tag), ["mac-data"], "\(output)")
            XCTAssertEqual(rig.outputBuilt, [], "a read built an output client (\(output))")
            let out = s.scene.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)
            XCTAssertFalse(out.contains("Sign in to see your Discover feed"), "\(output)")
        }
    }

    /// A blocked output reads the open column: no SpanDAC client of either
    /// kind is built, and with no feed the scene asks for the sign-in.
    func testABlockedOutputReadsOpenAndBuildsNoSpanDACClient() {
        let rig = SceneDataRig(output: .source, accepted: false)
        let s = scene(rig)
        for _ in 0..<20 { _ = s.scene.tick(snapshot: idle); usleep(2_000) }
        let out = s.scene.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)

        XCTAssertTrue(out.contains("Sign in to see your Discover feed"))
        XCTAssertEqual(rig.dataBuilt, 0)
        XCTAssertEqual(rig.outputBuilt, [])
        XCTAssertTrue(rig.sent.isEmpty)
    }

    /// Accepting SpanDAC data after the rails were read reloads them from the
    /// Mac, so a list from before the switch does not stay on screen.
    func testRailsReadBeforeTheSwitchReloadFromTheMac() {
        let rig = SceneDataRig(output: .musicApp, accepted: false)
        let s = scene(rig)
        for _ in 0..<20 { _ = s.scene.tick(snapshot: idle); usleep(2_000) }
        XCTAssertEqual(rig.sent.count, 0)

        XCTAssertNotNil(s.scene.loadFailure, "MusicTUI's own data with no feed says why")

        XCTAssertEqual(try s.routing.acceptSpanDACData(readiness: { .ready }), .switched(to: .spandacMac))
        _ = s.scene.tick(snapshot: idle)   // sees the new data source and reloads
        XCTAssertNil(s.scene.loadFailure)
        loadRails(s)

        XCTAssertEqual(s.scene.rails.map(\.title), ["Stations For You"])
        XCTAssertEqual(rig.sent("slice.recommendations").map(\.tag), ["mac-data"])
    }

    // MARK: - Plays on the MusicTUI output with SpanDAC data

    /// A Discover album, playlist or play-from-here slice on the MusicTUI
    /// output with SpanDAC data takes the container path. Until that path
    /// lands (a later step gives the lifecycle a SpanDAC create), it refuses
    /// with the score's sentence: nothing is created by the web service, and
    /// nothing is queued on any SpanDAC.
    func testDiscoverPlayOnMusicTUIOutputRefusesUntilTheContainerPathLands() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let s = scene(rig)
        loadRails(s)

        s.scene.playAllFromRail(playlistRow)
        drain(s.actions)
        XCTAssertEqual(s.status.current()?.text, pickASpanDACOutput)
        XCTAssertEqual(s.status.current()?.isError, true)

        s.scene.playCatalogSlice(catalogIDs: ["901", "902"], containerTitle: "Boom Bap", trackName: "T1")
        drain(s.actions)
        XCTAssertEqual(s.status.current()?.text, pickASpanDACOutput)

        XCTAssertEqual(s.log.created, [], "the web-service container path ran with SpanDAC data")
        XCTAssertEqual(rig.sent("slice.queue").count, 0)
        XCTAssertEqual(rig.outputBuilt, [])
        XCTAssertEqual(s.opener.opened, [])
    }

    /// The read's stamp is checked before anything plays: a play whose data
    /// source changed after its tracks were read plays nothing, on any path.
    func testADiscoverPlayWhoseReadCrossedASwitchPlaysNothing() {
        let rig = SceneDataRig(output: .source, accepted: true)
        let s = scene(rig)
        loadRails(s)
        // Stop using SpanDAC while the container's tracks are being read.
        rig.during["slice.containerTracks"] = {
            _ = try? s.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        }

        s.scene.playAllFromRail(playlistRow)
        drain(s.actions)

        XCTAssertEqual(s.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(rig.sent("slice.queue").count, 0)
        XCTAssertEqual(s.log.created, [])
    }

    /// On a SpanDAC output with SpanDAC data, a Discover play still queues on
    /// the OUTPUT client, with the ids read from the Mac.
    func testDiscoverPlayOnASpanDACOutputQueuesOnTheOutput() {
        let rig = SceneDataRig(output: .networkSource(SceneDataRig.ipad), accepted: true)
        let s = scene(rig)
        loadRails(s)

        s.scene.playAllFromRail(playlistRow)
        drain(s.actions)

        XCTAssertEqual(rig.sent("slice.containerTracks").map(\.tag), ["mac-data"])
        XCTAssertEqual(rig.sent("slice.queue").map(\.tag), ["output:\(SceneDataRig.ipad)"])
        XCTAssertEqual(rig.sent("slice.queue").first?.body["ids"] as? [String], ["901", "902"])
    }

    // MARK: - Stations

    /// A Discover station row from SpanDAC carries no URL. On the MusicTUI
    /// output it is looked up BY ID through the data provider (the Mac), then
    /// opened by the URL that lookup returned; SpanDAC is never asked to play.
    func testADiscoverStationWithoutAURLIsLookedUpByIDThenOpened() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let s = scene(rig)
        loadRails(s)

        _ = s.scene.handle(.enter)   // the first row: Apple Music 1, no URL
        drain(s.actions)

        XCTAssertEqual(rig.sent("slice.station").map(\.tag), ["mac-data"])
        XCTAssertEqual(rig.sent("slice.station").first?.body["id"] as? String, "ra.978194965")
        XCTAssertEqual(s.opener.opened, ["music://music.apple.com/us/station/apple-music-1/ra.978194965"])
        XCTAssertEqual(rig.sent("slice.playStation").count, 0)
        XCTAssertEqual(rig.outputBuilt, [])
        XCTAssertEqual(s.status.current()?.text, "Playing Apple Music 1")
    }

    /// Apple not carrying the station is an answer, and it refuses: never a
    /// guess by name, never another output.
    func testADiscoverStationThatCannotBeLookedUpRefuses() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        rig.replies["slice.station"] = #"{"ok":true,"op":"slice.station","station":null}"#
        let s = scene(rig)
        loadRails(s)

        _ = s.scene.handle(.enter)
        drain(s.actions)

        XCTAssertEqual(s.status.current()?.text, pickASpanDACOutput)
        XCTAssertEqual(s.status.current()?.isError, true)
        XCTAssertEqual(s.opener.opened, [])
        XCTAssertEqual(rig.sent("slice.playStation").count, 0)
        XCTAssertEqual(rig.outputBuilt, [])
    }

    /// A switch that lands while the lookup is in flight: the lookup's stamp
    /// has moved by the time the play runs, so nothing is opened.
    func testAStationLookupThatCrossedASwitchPlaysNothing() {
        let rig = SceneDataRig(output: .musicApp, accepted: true)
        let s = scene(rig)
        loadRails(s)
        rig.during["slice.station"] = {
            _ = try? s.routing.stopUsingSpanDACData(pauseOutgoing: { _ in true }, dropQueue: { _ in })
        }

        _ = s.scene.handle(.enter)
        drain(s.actions)

        XCTAssertEqual(rig.sent("slice.station").count, 1)
        XCTAssertEqual(s.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(s.opener.opened, [])

        // An OUTPUT switch in flight: the data source is unchanged, so only the
        // stamp can tell, and the station is not played on the new output.
        let rig2 = SceneDataRig(output: .musicApp, accepted: true)
        let s2 = scene(rig2)
        loadRails(s2)
        rig2.during["slice.station"] = {
            _ = try? s2.routing.switchMode(to: .source, readiness: { .ready },
                                           pauseOutgoing: { _ in true }, dropQueue: { _ in })
        }

        _ = s2.scene.handle(.enter)
        drain(s2.actions)

        XCTAssertEqual(s2.routing.mode, .source, "the switch itself must have landed")
        XCTAssertEqual(s2.status.current()?.text, sourceChangedNothingPlayed)
        XCTAssertEqual(s2.opener.opened, [])
        XCTAssertEqual(rig2.sent("slice.playStation").count, 0)
    }

    /// On a SpanDAC output the station still plays there, by id, as before.
    func testADiscoverStationOnASpanDACOutputPlaysThereByID() {
        let rig = SceneDataRig(output: .source, accepted: true)
        let s = scene(rig)
        loadRails(s)

        _ = s.scene.handle(.enter)

        XCTAssertEqual(rig.sent("slice.playStation").map(\.tag), ["output:musictui_source"])
        XCTAssertEqual(rig.sent("slice.station").count, 0)
        XCTAssertEqual(s.opener.opened, [])
    }
}
