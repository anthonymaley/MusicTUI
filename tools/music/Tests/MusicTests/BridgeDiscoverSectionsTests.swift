// tools/music/Tests/MusicTests/BridgeDiscoverSectionsTests.swift
//
// Discover's self-named sections under SpanDAC data (score
// "SpanDAC serves Discover's self-named sections", step C1): the client side
// of `slice.recentlyAdded`, `slice.recentStations` and `slice.charts`.
//
// A section appears only when SpanDAC advertises its op; otherwise nothing is
// sent and it is absent. Never a web request under SpanDAC data. The same one
// shared deadline and append-when-it-lands behaviour as the web service's
// sections. Albums still refuse (3.18.1).
//
// Fakes only: a scripted transport that answers by op and records every
// request. The reply bodies follow the score's wire contract (section 2)
// character for character. No socket, no network, no Music.app, no
// `~/.config/music`.
import XCTest
@testable import music

/// Replies by op, records every request (thread-safe: the section reads run
/// at once). An op with no reply answers `unknown_op`, as an older SpanDAC.
final class SectionWire {
    private let lock = NSLock()
    private var stored: [[String: Any]] = []
    private var replies: [String: String]
    private var gates: [String: DispatchSemaphore] = [:]

    init(_ replies: [String: String]) { self.replies = replies }

    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return stored }
    var ops: [String] { requests.compactMap { $0["op"] as? String } }
    func sent(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }

    /// Hold every request of `op` until the returned gate is signalled.
    func hold(_ op: String) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); gates[op] = gate; lock.unlock()
        return gate
    }

    func transport(_ path: String, _ line: String) throws -> String {
        let body = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
        let op = body["op"] as? String ?? ""
        lock.lock(); stored.append(body); let gate = gates[op]; let reply = replies[op]; lock.unlock()
        if let gate { _ = gate.wait(timeout: .now() + 10); gate.signal() }
        return reply ?? #"{"ok":false,"op":"\#(op)","error":{"kind":"unknown_op","detail":"unknown op"}}"#
    }

    var control: SourceAppControl { SourceAppControl(path: "/nonexistent", transport: transport) }
}

/// The contract's replies (score section 2).
enum SectionReplies {
    static let allOps = ["slice.recentlyAdded", "slice.recentStations", "slice.charts"]

    static func status(_ capabilities: [String]?) -> String {
        let caps = capabilities.map { ",\"capabilities\":[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? ""
        return #"{"ok":true,"op":"slice.status","status":{"playback":"idle","authorization":"authorized","contract":3\#(caps)}}"#
    }

    static let recommendations = """
    {"ok":true,"op":"slice.recommendations","rails":[{"title":"Stations For You","items":[
      {"id":"ra.978194965","kind":"station","name":"Apple Music 1"},
      {"id":"pl.u-abc","kind":"playlist","name":"Boom Bap","subtitle":"Apple Music Hip-Hop"}]}]}
    """

    static let recentlyAdded = """
    {"ok":true,"op":"slice.recentlyAdded","items":[
         {"id":"1440761000","kind":"album","name":"Aja","subtitle":"Steely Dan","artwork_url":"https://example.com/aja/512x512bb.jpg"},
         {"id":"pl.u-abc","kind":"playlist","name":"Deep House Lab","subtitle":"Apple Music Dance","artwork_url":null}]}
    """

    static let recentStations = """
    {"ok":true,"op":"slice.recentStations","stations":[
         {"id":"ra.978194965","name":"Apple Music 1","url":"https://music.apple.com/us/station/apple-music-1/ra.978194965","is_live":true,"artwork_url":"https://example.com/am1/512x512bb.jpg"}]}
    """

    static let charts = """
    {"ok":true,"op":"slice.charts","charts":{
         "songs":[{"id":"1706428462","kind":"song","name":"Song One","subtitle":"Artist One","artwork_url":"https://example.com/s1/512x512bb.jpg","duration_ms":215000},
                  {"id":"1706428463","kind":"song","name":"Song Two","subtitle":"Artist Two","artwork_url":null,"duration_ms":null}],
         "albums":[{"id":"1440000001","kind":"album","name":"Album One","subtitle":"Artist A"}],
         "playlists":[{"id":"pl.f4d106fed2bd41149aaacabb233eb5eb","kind":"playlist","name":"Today's Hits","subtitle":"Apple Music Pop"}]}}
    """

    static func wire(capabilities: [String]? = allOps, overrides: [String: String] = [:]) -> SectionWire {
        var replies = ["slice.status": status(capabilities), "slice.recommendations": recommendations,
                       "slice.recentlyAdded": recentlyAdded, "slice.recentStations": recentStations,
                       "slice.charts": charts]
        replies.merge(overrides) { _, new in new }
        return SectionWire(replies)
    }

    static let upstream = #"{"ok":false,"error":{"kind":"upstream","upstream_kind":"other","detail":"Apple Music didn't answer"}}"#
}

final class BridgeDiscoverSectionsTests: XCTestCase {

    private typealias R = SectionReplies
    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    private func sections(_ wire: SectionWire, deadline: TimeInterval = 5) -> [DiscoverRail] {
        BridgeMusicProvider(control: wire.control, sectionDeadline: deadline).discoverSections()
    }

    // MARK: - The capability gate

    /// SpanDAC advertises none of the ops (or predates capabilities): no
    /// section op goes on the wire and there are no sections.
    func testNoCapabilityMeansNoSectionOpAndNoSection() {
        for caps in [[], nil, ["slice.recommendations", "library.catalog_playlist"]] as [[String]?] {
            let wire = R.wire(capabilities: caps)
            XCTAssertEqual(sections(wire), [], "\(String(describing: caps))")
            XCTAssertEqual(wire.ops, ["slice.status"], "\(String(describing: caps))")
        }
    }

    /// A status that cannot be read: no section op, no section.
    func testAStatusReadFailureSendsNoSectionOp() {
        for status in [R.upstream, "not json", #"{"ok":false,"error":{"kind":"unauthorized","detail":"x"}}"#] {
            let wire = R.wire(overrides: ["slice.status": status])
            XCTAssertEqual(sections(wire), [])
            XCTAssertEqual(wire.ops, ["slice.status"])
        }
    }

    /// All three advertised: every section, in `DiscoverSection` order, with
    /// its section and rail id; each op sent once, in the contract's bytes.
    func testAllAdvertisedGivesEverySectionInOrder() throws {
        let wire = R.wire()
        let rails = sections(wire)
        XCTAssertEqual(rails.map(\.section), DiscoverSection.allCases)
        XCTAssertEqual(rails.map(\.id), DiscoverSection.allCases.map(\.railID))
        XCTAssertEqual(rails.map(\.title), DiscoverSection.allCases.map(\.title))
        XCTAssertEqual(rails.map(\.resourceTypes), DiscoverSection.allCases.map(\.resourceTypes))

        XCTAssertEqual(wire.ops.first, "slice.status", "the capabilities are read first")
        XCTAssertEqual(Set(wire.ops.dropFirst()), Set(R.allOps))
        XCTAssertEqual(wire.ops.count, 4)
        let added = try XCTUnwrap(wire.sent("slice.recentlyAdded").first)
        XCTAssertEqual(added.keys.sorted(), ["op"], "no request fields")
        let stations = try XCTUnwrap(wire.sent("slice.recentStations").first)
        XCTAssertEqual(stations.keys.sorted(), ["limit", "op"])
        XCTAssertEqual(stations["limit"] as? Int, 10)
        let charts = try XCTUnwrap(wire.sent("slice.charts").first)
        XCTAssertEqual(charts.keys.sorted(), ["op"], "no request fields")
    }

    /// Each op is gated on its OWN name.
    func testEachSectionIsGatedOnItsOwnCapability() {
        let wire = R.wire(capabilities: ["slice.charts"])
        XCTAssertEqual(sections(wire).map(\.section), [.topSongs, .topAlbums, .topPlaylists])
        XCTAssertEqual(wire.ops, ["slice.status", "slice.charts"])

        let stationsOnly = R.wire(capabilities: ["slice.recentStations"])
        XCTAssertEqual(sections(stationsOnly).map(\.section), [.recentStations])
        XCTAssertEqual(stationsOnly.ops, ["slice.status", "slice.recentStations"])
    }

    // MARK: - Failures drop only their own section

    /// upstream, unknown_op (advertised but refused) and an unreadable reply:
    /// only that section is absent. A charts failure drops all three charts.
    func testOneFailingOpDropsOnlyItsSection() {
        let refusals = [R.upstream,
                        #"{"ok":false,"error":{"kind":"unknown_op","detail":"unknown op"}}"#,
                        #"{"ok":true,"op":"x"}"#]
        for refusal in refusals {
            XCTAssertEqual(sections(R.wire(overrides: ["slice.recentlyAdded": refusal])).map(\.section),
                           [.recentStations, .topSongs, .topAlbums, .topPlaylists], refusal)
            XCTAssertEqual(sections(R.wire(overrides: ["slice.recentStations": refusal])).map(\.section),
                           [.recentlyAdded, .topSongs, .topAlbums, .topPlaylists], refusal)
            XCTAssertEqual(sections(R.wire(overrides: ["slice.charts": refusal])).map(\.section),
                           [.recentlyAdded, .recentStations], refusal)
        }
    }

    /// A charts reply missing one of its three keys is unreadable as a whole.
    func testAChartsReplyMissingATypeIsUnreadable() {
        let missing = #"{"ok":true,"op":"slice.charts","charts":{"songs":[],"albums":[]}}"#
        XCTAssertThrowsError(try R.wire(overrides: ["slice.charts": missing]).control.charts())
        XCTAssertEqual(sections(R.wire(overrides: ["slice.charts": missing])).map(\.section),
                       [.recentlyAdded, .recentStations])
    }

    /// Empty arrays are an answer: no rail, no error, the other charts stay.
    func testAnEmptyChartIsAnAnswer() throws {
        let empty = #"{"ok":true,"op":"slice.charts","charts":{"songs":[],"albums":[],"playlists":[{"id":"pl.1","kind":"playlist","name":"P"}]}}"#
        let charts = try R.wire(overrides: ["slice.charts": empty]).control.charts()
        XCTAssertEqual(charts.songs, [])
        XCTAssertEqual(charts.playlists.map(\.id), ["pl.1"])
        XCTAssertEqual(sections(R.wire(capabilities: ["slice.charts"], overrides: ["slice.charts": empty]))
            .map(\.section), [.topPlaylists])
    }

    /// An unknown row kind is dropped; a row missing its id or name fails
    /// that section's read.
    func testRowRules() throws {
        let unknown = """
        {"ok":true,"op":"slice.recentlyAdded","items":[
          {"id":"v1","kind":"music-video","name":"A Video"},
          {"id":"1440761000","kind":"album","name":"Aja","subtitle":"Steely Dan"}]}
        """
        XCTAssertEqual(try R.wire(overrides: ["slice.recentlyAdded": unknown]).control.recentlyAdded().map(\.id),
                       ["1440761000"])
        let noName = #"{"ok":true,"op":"slice.recentlyAdded","items":[{"id":"1","kind":"album"}]}"#
        XCTAssertThrowsError(try R.wire(overrides: ["slice.recentlyAdded": noName]).control.recentlyAdded())
        XCTAssertFalse(sections(R.wire(overrides: ["slice.recentlyAdded": noName]))
            .contains { $0.section == .recentlyAdded })
    }

    // MARK: - Decoding

    func testRecentlyAddedDecodesCatalogueRows() throws {
        let items = try R.wire().control.recentlyAdded()
        XCTAssertEqual(items.map(\.id), ["1440761000", "pl.u-abc"])
        XCTAssertEqual(items.map(\.kind), [.album, .playlist])
        XCTAssertEqual(items[0].subtitle, "Steely Dan")
        XCTAssertEqual(items[0].artworkURL, "https://example.com/aja/512x512bb.jpg")
        XCTAssertNil(items[1].artworkURL, "artwork_url null")
    }

    /// A song row carries its length (number or null), so play from here over
    /// a chart has lengths; other kinds carry none.
    func testSongRowsCarryTheirLength() throws {
        let charts = try R.wire().control.charts()
        XCTAssertEqual(charts.songs.map(\.length), [.milliseconds(215000), .null])
        XCTAssertEqual(charts.albums.map(\.length), [.absent])
        XCTAssertEqual(charts.playlists.map(\.kind), [.playlist])
    }

    /// A station keeps its share URL (a station play on the MusicTUI output
    /// needs it) and its live flag.
    func testAStationKeepsItsURL() throws {
        let stations = try R.wire().control.recentStations(limit: 10)
        XCTAssertEqual(stations.map(\.id), ["ra.978194965"])
        XCTAssertEqual(stations[0].url, "https://music.apple.com/us/station/apple-music-1/ra.978194965")
        XCTAssertEqual(stations[0].detail, .station(isLive: true))
        XCTAssertEqual(stations[0].artworkURL, "https://example.com/am1/512x512bb.jpg")
        let noURL = #"{"ok":true,"op":"slice.recentStations","stations":[{"id":"ra.1","name":"X"}]}"#
        XCTAssertThrowsError(try R.wire(overrides: ["slice.recentStations": noURL]).control.recentStations(limit: 10))
    }

    /// A charts row of another kind is not shown under that chart.
    func testAChartKeepsOnlyItsOwnKind() throws {
        let stray = #"{"ok":true,"op":"slice.charts","charts":{"songs":[{"id":"a","kind":"album","name":"A"},{"id":"s","kind":"song","name":"S","duration_ms":1000}],"albums":[],"playlists":[]}}"#
        XCTAssertEqual(try R.wire(overrides: ["slice.charts": stray]).control.charts().songs.map(\.id), ["s"])
    }

    // MARK: - One shared deadline

    /// A held op misses the deadline and is absent; the others land and the
    /// call returns at the deadline, not when the held op answers.
    func testAHeldSectionIsAbsentAndHoldsNothingPastTheDeadline() {
        let wire = R.wire()
        let gate = wire.hold("slice.charts")
        defer { gate.signal() }
        let start = Date()
        let rails = sections(wire, deadline: 0.4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(rails.map(\.section), [.recentlyAdded, .recentStations])
        XCTAssertLessThan(elapsed, 1.4)
    }

    /// The capability read is inside the deadline: a held status gives no
    /// sections, by the deadline.
    func testAHeldStatusReadIsInsideTheDeadline() {
        let wire = R.wire()
        let gate = wire.hold("slice.status")
        defer { gate.signal() }
        let start = Date()
        XCTAssertEqual(sections(wire, deadline: 0.3), [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.3)
    }

    // MARK: - The scene under SpanDAC data

    private struct Scene {
        let scene: DiscoverScene
        let status: StatusStore
        let actions: ActionRunner
        let web: SectionWebService
    }

    /// SpanDAC data on `output`, with a web feed present that must never be
    /// asked, and a signed-in REST backend that must never be reached.
    private func scene(_ rig: SceneDataRig) -> Scene {
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let web = SectionWebService()
        let scene = DiscoverScene(feed: web.feed(), status: status, actions: actions,
                                  api: RESTAPIBackend(developerToken: "d", userToken: "u", storefront: "us"),
                                  lifecycle: lifecycle(), routing: rig.coordinator(),
                                  opener: SceneRecordingOpener())
        return Scene(scene: scene, status: status, actions: actions, web: web)
    }

    private func lifecycle() -> DiscoverLifecycleCoordinator {
        enum Stop: Error { case stop }
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in }, create: { _, _ in throw Stop.stop }, readCount: { _ in 0 },
            play: { _ in }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }))
        let c = DiscoverLifecycleCoordinator(seams: seams)
        c.completeLaunchSweep(.swept)
        return c
    }

    private func advertisingRig(output: PlaybackMode) -> SceneDataRig {
        let rig = SceneDataRig(output: output, accepted: true)
        rig.replies["slice.status"] = #"{"ok":true,"op":"slice.status","status":{"playback":"playing","title":"On SpanDAC","artist":"A","authorization":"authorized","contract":3,"capabilities":["slice.recentlyAdded","slice.recentStations","slice.charts"]}}"#
        rig.replies["slice.recentlyAdded"] = R.recentlyAdded
        rig.replies["slice.recentStations"] = R.recentStations
        rig.replies["slice.charts"] = R.charts
        return rig
    }

    private func settle(_ s: DiscoverScene, seconds: Double = 5, until check: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !check() && Date() < deadline {
            _ = s.tick(snapshot: idle)
            usleep(2_000)
        }
    }

    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    /// SpanDAC advertises the ops: the sections follow SpanDAC's rails, from
    /// SpanDAC on this Mac, on every output, and the web service is never asked.
    func testSpanDACDataShowsAdvertisedSectionsAndNeverAsksTheWebService() {
        for output in [PlaybackMode.musicApp, .source, .networkSource(SceneDataRig.ipad)] {
            let rig = advertisingRig(output: output)
            let s = scene(rig)
            settle(s.scene) { s.scene.rails.contains { $0.section != nil } }

            XCTAssertEqual(s.scene.rails.map(\.title),
                           ["Stations For You"] + DiscoverSection.allCases.map(\.title), "\(output)")
            XCTAssertEqual(s.web.urls, [], "SpanDAC data reached the web service (\(output))")
            for op in SectionReplies.allOps {
                XCTAssertEqual(rig.sent(op).map(\.tag), ["mac-data"], "\(op) (\(output))")
            }
            XCTAssertEqual(rig.outputBuilt, [], "a read built an output client (\(output))")
            let out = s.scene.render(frame: shellLayout(width: 120, height: 80), snapshot: idle)
            XCTAssertTrue(out.contains("Top Songs"), "\(output)")
        }
    }

    /// SpanDAC's curated rails show while its section ops are still held.
    func testSpanDACCuratedRailsNeverWaitOnTheSections() {
        let rig = advertisingRig(output: .source)
        let gate = DispatchSemaphore(value: 0)
        for op in SectionReplies.allOps { rig.during[op] = { _ = gate.wait(timeout: .now() + 10); gate.signal() } }
        defer { gate.signal() }
        let s = scene(rig)
        settle(s.scene, seconds: 2) { !s.scene.rails.isEmpty }
        XCTAssertEqual(s.scene.rails.map(\.title), ["Stations For You"], "the rails waited on the sections")

        gate.signal()
        settle(s.scene) { s.scene.rails.contains { $0.section != nil } }
        XCTAssertEqual(s.scene.rails.compactMap(\.section), DiscoverSection.allCases)
    }

    /// A recommendations failure: no section op is sent.
    func testARecommendationsFailureSendsNoSectionOp() {
        let rig = advertisingRig(output: .source)
        rig.replies["slice.recommendations"] = SectionReplies.upstream
        let s = scene(rig)
        settle(s.scene) { s.scene.loadFailure != nil }
        for _ in 0..<50 { _ = s.scene.tick(snapshot: idle); usleep(2_000) }
        XCTAssertNotNil(s.scene.loadFailure)
        for op in SectionReplies.allOps { XCTAssertEqual(rig.sent(op).count, 0, op) }
        XCTAssertEqual(s.web.urls, [])
    }

    /// The 3.18.1 refusal holds for a section album under SpanDAC data on the
    /// MusicTUI output: `p` on a Top Albums row and on a Recently Added album
    /// refuses, with no library op and no queue sent to any SpanDAC.
    func testASectionAlbumStillRefusesOnTheMusicTUIOutput() throws {
        let rig = advertisingRig(output: .musicApp)
        rig.replies["slice.containerTracks"] = """
        {"ok":true,"op":"slice.containerTracks","items":[
          {"id":"901","kind":"song","name":"T1","subtitle":"A","duration_ms":1000},
          {"id":"902","kind":"song","name":"T2","subtitle":"A","duration_ms":1000}]}
        """
        let s = scene(rig)
        settle(s.scene) { s.scene.rails.contains { $0.section == .topPlaylists } }
        let topAlbum = try XCTUnwrap(s.scene.rails.first { $0.section == .topAlbums }?.items.first)
        let addedAlbum = try XCTUnwrap(s.scene.rails.first { $0.section == .recentlyAdded }?.items
            .first { $0.kind == .album })

        for album in [topAlbum, addedAlbum] {
            s.scene.playAllFromRail(album)
            drain(s.actions)
            XCTAssertEqual(s.status.current()?.text, DiscoverScene.albumPlayRefused(album.name), album.id)
        }
        let mutations = rig.sent.filter { $0.op.hasPrefix("slice.library") || $0.op == "slice.queue" }
        XCTAssertEqual(mutations.map(\.op), [], "the album reached the library or a queue")
        XCTAssertEqual(s.web.urls, [])
    }
}

// MARK: - `music discover` under SpanDAC

final class BridgeDiscoverSectionsCLITests: XCTestCase {
    private typealias H = CLIBridgeCommandHarness

    private func readyStatus(_ capabilities: [String]) -> String {
        #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":\#(sourceContractVersion),"capabilities":["#
            + capabilities.map { "\"\($0)\"" }.joined(separator: ",") + "]}}"
    }

    private func discover(_ h: H, limit: Int) -> (error: Error?, calls: [ExternalCall]) {
        var thrown: Error?
        let calls = withTripwire {
            do {
                try runDiscover(limit: limit, perRail: 6, recent: false, json: false, all: false, env: h.env,
                                musicApp: { XCTFail("Music.app ran") })
            } catch { thrown = error }
        }.calls
        return (thrown, calls)
    }

    /// The sections print after the curated rails and count toward `--limit`.
    func testMusicDiscoverPrintsTheSectionsAndCountsThemTowardTheLimit() {
        let status = readyStatus(SectionReplies.allOps)
        let replies: [String: [String]] = [
            "slice.status": [status, status],
            "slice.recommendations": [CLIBridgeListingsReplies.rails],
            "slice.recentlyAdded": [SectionReplies.recentlyAdded],
            "slice.recentStations": [SectionReplies.recentStations],
            "slice.charts": [SectionReplies.charts],
        ]
        let all = H(.source, replies)
        let (error, calls) = discover(all, limit: 10)
        XCTAssertNil(error)
        XCTAssertEqual(calls, [], "no REST, no AppleScript")
        let headers = all.io.out.filter { $0.hasPrefix("\n") }
        XCTAssertEqual(headers, ["\nRecently Played", "\nMade for You", "\nRecently Added", "\nRecent Stations",
                                 "\nTop Songs", "\nTop Albums", "\nTop Playlists"])

        let limited = H(.source, replies)
        XCTAssertNil(discover(limited, limit: 3).error)
        XCTAssertEqual(limited.io.out.filter { $0.hasPrefix("\n") },
                       ["\nRecently Played", "\nMade for You", "\nRecently Added"])
    }

    /// A recommendations failure throws and sends no section op.
    func testARecommendationsFailureSendsNoSectionOp() {
        let status = readyStatus(SectionReplies.allOps)
        let h = H(.source, ["slice.status": [status, status], "slice.recommendations": [SectionReplies.upstream]])
        XCTAssertNotNil(discover(h, limit: 8).error)
        XCTAssertFalse(h.seen.ops.contains { SectionReplies.allOps.contains($0) }, "\(h.seen.ops)")
    }
}
