import XCTest
@testable import music

/// Slice 3, Part 2, P3: Discover folded onto the provider seam.
///
/// Discover used to reach Bridge around the seam (`$0.discover`,
/// `$0.control.queue(catalogIDs:)`, `$0.control.playStation`). It now chooses a
/// `DiscoverProviding` with `routing.choose` — an `OpenMusicProvider` wrapped
/// around the feed it already receives, or a `BridgeMusicProvider` — and plays
/// through the provider's `playStation`/`playCatalogue`. **No visible change**
/// (D2): every request, toast and error sentence is what it was, and Music.app
/// mode makes exactly the feed and opener calls it made before, with no wire.
///
/// Real coordinator on a temp mode store; the wire, the feed, the opener and
/// the lifecycle's side effects are counting doubles. **No sleeps**: ActionRunner
/// work is awaited with a barrier on its own serial queue; the scene's
/// background fetches are drained by ticking until they land, bounded.
final class DiscoverProviderFoldTests: XCTestCase {

    // MARK: - Harness

    /// Answers by op; records every request line.
    private final class Wire {
        private let lock = NSLock()
        private var stored: [String] = []
        private var scripted: [String: String] = [
            "slice.recommendations": """
            {"ok":true,"op":"slice.recommendations","rails":[{"title":"Stations For You","items":[
              {"id":"ra.978194965","kind":"station","name":"Apple Music 1"}]}]}
            """,
            "slice.containerTracks": """
            {"ok":true,"op":"slice.containerTracks","items":[
              {"id":"901","kind":"song","name":"T1","subtitle":"A"},
              {"id":"902","kind":"song","name":"T2","subtitle":"A"}]}
            """,
            "slice.queue": #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T1","artist":"A"}}"#,
            "slice.playStation": #"{"ok":true,"op":"slice.playStation","status":{"playback":"playing","title":"Apple Music 1","artist":""}}"#,
        ]

        func reply(_ op: String, _ json: String) { lock.lock(); scripted[op] = json; lock.unlock() }

        var transport: (String, String) throws -> String {
            { [self] _, line in
                lock.lock(); defer { lock.unlock() }
                stored.append(line)
                let op = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["op"] as? String ?? ""
                return scripted[op] ?? #"{"ok":false,"op":"?","error":{"kind":"bad_request","detail":"unexpected op"}}"#
            }
        }

        var requests: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return stored.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func sent(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }
    }

    /// The web-service feed's stand-in: records what it was asked.
    private final class Feed: DiscoverFeedReading {
        private let lock = NSLock()
        private var railCalls: [Int] = []
        private var trackCalls: [String] = []
        let railsAnswer: [DiscoverRail]
        let tracksAnswer: [DiscoverItem]

        init(rails: [DiscoverRail], tracks: [DiscoverItem]) { railsAnswer = rails; tracksAnswer = tracks }

        func rails(limit: Int) throws -> [DiscoverRail] {
            lock.lock(); railCalls.append(limit); lock.unlock()
            return railsAnswer
        }
        func tracks(for item: DiscoverItem) throws -> [DiscoverItem] {
            lock.lock(); trackCalls.append(item.id); lock.unlock()
            return tracksAnswer
        }
        var railLimits: [Int] { lock.lock(); defer { lock.unlock() }; return railCalls }
        var trackItems: [String] { lock.lock(); defer { lock.unlock() }; return trackCalls }
    }

    private final class CountingOpener: Opener {
        private let lock = NSLock()
        private var stored: [String] = []
        func open(_ url: String) throws { lock.lock(); stored.append(url); lock.unlock() }
        var opened: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private final class Recorder {
        private let lock = NSLock()
        private var stored: [[String]] = []
        func add(_ v: [String]) { lock.lock(); stored.append(v); lock.unlock() }
        var created: [[String]] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private enum StopAfterCreate: Error { case stop }

    /// Records the ids the Music.app transaction was asked to create, then
    /// stops (see `DiscoverBridgeCollectionTests.lifecycle` for why it throws).
    private func lifecycle(_ recorder: Recorder) -> DiscoverLifecycleCoordinator {
        let seams = DiscoverLifecycleCoordinator.Seams(
            runSweep: { _ in },
            create: { _, ids in recorder.add(ids); throw StopAfterCreate.stop },
            readCount: { _ in 0 }, play: { _ in }, confirmRead: { _ in "" }, post: { _ in },
            scheduler: DiscoverScheduler(now: { Date() }, deadline: { _ in Date() }, delay: { _ in }))
        let c = DiscoverLifecycleCoordinator(seams: seams)
        c.completeLaunchSweep(.swept)
        return c
    }

    private struct Rig {
        let scene: DiscoverScene
        let wire: Wire
        let feed: Feed?
        let opener: CountingOpener
        let status: StatusStore
        let actions: ActionRunner
        let created: Recorder
    }

    private static let stationURL = "https://music.apple.com/us/station/apple-music-1/ra.978194965"

    private static func station(url: String?) -> DiscoverItem {
        DiscoverItem(id: "ra.978194965", name: "Apple Music 1", subtitle: nil, url: url, artworkURL: nil,
                     detail: .station(isLive: true))
    }

    private static let playlistRow = DiscoverItem(id: "pl.u-abc", name: "Boom Bap", subtitle: nil, url: nil,
                                                  artworkURL: nil, detail: .playlist(description: nil))

    private static func webFeed(stationURL: String? = stationURL) -> Feed {
        Feed(rails: [DiscoverRail(id: "r1", title: "Stations for You", items: [station(url: stationURL)],
                                  isRecentlyPlayed: false, resourceTypes: ["stations"])],
             tracks: [DiscoverItem(id: "801", name: "S1", subtitle: "A", url: nil, artworkURL: nil, detail: .song),
                      DiscoverItem(id: "802", name: "S2", subtitle: "A", url: nil, artworkURL: nil, detail: .song)])
    }

    private func rig(mode: PlaybackMode, feed: Feed?, api: Bool = true) -> Rig {
        let wire = Wire()
        let opener = CountingOpener()
        let status = StatusStore()
        let actions = ActionRunner(status: status)
        let created = Recorder()
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(mode)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                       transport: wire.transport) })
        let scene = DiscoverScene(
            feed: feed, status: status, actions: actions,
            api: api ? RESTAPIBackend(developerToken: "d", userToken: "u", storefront: "us") : nil,
            lifecycle: lifecycle(created), routing: routing, opener: opener,
            bridgeSelected: { routing.mode == .source })
        return Rig(scene: scene, wire: wire, feed: feed, opener: opener, status: status, actions: actions,
                   created: created)
    }

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    /// Ticks until the scene's own background fetch has landed. No sleep: the
    /// loop only drains the inbox, and the bound turns a hang into a failure.
    private func tickUntil(_ s: DiscoverScene, _ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { _ = s.tick(snapshot: idle) }
    }

    private func loadRails(_ r: Rig) {
        tickUntil(r.scene) { !r.scene.rails.isEmpty || r.scene.loadFailure != nil }
    }

    /// ActionRunner's queue is serial: a marker enqueued after the play runs
    /// only once the play has finished.
    private func drain(_ actions: ActionRunner) {
        let done = DispatchSemaphore(value: 0)
        actions.run("barrier") { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "ActionRunner never drained")
    }

    /// The sentence the OLD call site showed for a reply: `SourceAppControl`'s
    /// own error, read straight off the shipped adapter.
    private func shippedMessage(for reply: String, _ call: (SourceAppControl) throws -> Void) -> String? {
        let control = SourceAppControl(path: "/nonexistent", transport: { _, _ in reply })
        do { try call(control); return nil } catch let e as SourceAppError { return e.message } catch { return nil }
    }

    // MARK: - Music.app mode: the feed and opener, exactly as before, no wire

    func testMusicAppRailsAreOneFeedReadAtThirtyAndNoWire() {
        let r = rig(mode: .musicApp, feed: Self.webFeed())
        loadRails(r)

        XCTAssertEqual(r.scene.rails.map(\.title), ["Stations for You"])
        XCTAssertEqual(r.feed?.railLimits, [30])
        XCTAssertEqual(r.feed?.trackItems, [])
        XCTAssertTrue(r.wire.requests.isEmpty, "Music.app mode sent a Bridge request")
    }

    func testMusicAppDrillInIsOneFeedTrackReadAndNoWire() {
        let r = rig(mode: .musicApp, feed: Self.webFeed())
        r.scene.drillIn(Self.playlistRow)
        tickUntil(r.scene) { !r.scene.trackRows.isEmpty }

        XCTAssertEqual(r.scene.trackRows.map(\.id), ["801", "802"])
        XCTAssertEqual(r.feed?.trackItems, ["pl.u-abc"])
        XCTAssertTrue(r.wire.requests.isEmpty)
    }

    func testMusicAppStationEnterOpensTheSchemeURLOnceWithTheShippedToast() {
        let r = rig(mode: .musicApp, feed: Self.webFeed())
        loadRails(r)

        _ = r.scene.handle(.enter)

        XCTAssertEqual(r.opener.opened, ["music://music.apple.com/us/station/apple-music-1/ra.978194965"])
        XCTAssertEqual(r.status.current()?.text, "Playing Apple Music 1")
        XCTAssertEqual(r.status.current()?.isError, false)
        XCTAssertTrue(r.wire.requests.isEmpty)
    }

    func testMusicAppStationWithNoURLKeepsTheShippedRefusal() {
        let r = rig(mode: .musicApp, feed: Self.webFeed(stationURL: nil))
        loadRails(r)

        _ = r.scene.handle(.enter)

        XCTAssertEqual(r.status.current()?.text, "That station has no play URL.")
        XCTAssertEqual(r.status.current()?.isError, true)
        XCTAssertEqual(r.opener.opened, [])
        XCTAssertTrue(r.wire.requests.isEmpty)
    }

    func testMusicAppPlayAllReadsTheFeedAndBuildsTheContainer() {
        let r = rig(mode: .musicApp, feed: Self.webFeed())
        r.scene.playAllFromRail(Self.playlistRow)
        drain(r.actions)

        XCTAssertEqual(r.feed?.trackItems, ["pl.u-abc"])
        XCTAssertEqual(r.created.created, [["801", "802"]])
        XCTAssertTrue(r.wire.requests.isEmpty)
    }

    func testMusicAppSliceBuildsTheContainerAndWithoutKeysSaysSignInToPlay() {
        let r = rig(mode: .musicApp, feed: Self.webFeed())
        r.scene.playCatalogSlice(catalogIDs: ["802"], containerTitle: "Boom Bap", trackName: "S2")
        drain(r.actions)
        XCTAssertEqual(r.created.created, [["802"]])
        XCTAssertTrue(r.wire.requests.isEmpty)

        let keyless = rig(mode: .musicApp, feed: Self.webFeed(), api: false)
        keyless.scene.playCatalogSlice(catalogIDs: ["802"], containerTitle: "Boom Bap", trackName: "S2")
        drain(keyless.actions)
        XCTAssertEqual(keyless.status.current()?.text, DiscoverScene.signInToPlay)
        XCTAssertEqual(keyless.created.created, [])
        XCTAssertTrue(keyless.wire.requests.isEmpty)
    }

    /// Music.app mode with no feed: `feedAvailable` false gives the shipped
    /// sentence, byte for byte, and nothing is asked of anything.
    func testMusicAppWithNoFeedIsTheShippedSignInSentence() {
        let r = rig(mode: .musicApp, feed: nil)
        loadRails(r)

        XCTAssertEqual(r.scene.loadFailure, "Sign in to see your Discover feed (music auth setup).")
        XCTAssertEqual(r.scene.loadFailure, DiscoverScene.signInToBrowse)
        XCTAssertTrue(r.wire.requests.isEmpty)
        XCTAssertEqual(r.opener.opened, [])

        // `p` reads the feed first, and with none it refuses in the same words.
        r.scene.playAllFromRail(Self.playlistRow)
        drain(r.actions)
        XCTAssertEqual(r.status.current()?.text, DiscoverScene.signInToBrowse)
        XCTAssertEqual(r.created.created, [])
    }

    // MARK: - Bridge mode: the provider's ops, today's toasts and sentences

    /// A web-service feed is present and is never asked (no fallback).
    func testBridgeRailsAreOneRecommendationsRequestAtThirty() {
        let r = rig(mode: .source, feed: Self.webFeed())
        loadRails(r)

        XCTAssertEqual(r.scene.rails.map(\.title), ["Stations For You"])
        XCTAssertEqual(r.wire.sent("slice.recommendations").count, 1)
        XCTAssertEqual(r.wire.sent("slice.recommendations").first?["limit"] as? Int, 30)
        XCTAssertEqual(r.feed?.railLimits, [])
    }

    func testBridgeRailFailureKeepsBridgesSentence() {
        let reply = #"{"ok":false,"op":"slice.recommendations","error":{"kind":"bad_request","detail":"Discover is unavailable right now."}}"#
        let r = rig(mode: .source, feed: nil)
        r.wire.reply("slice.recommendations", reply)
        loadRails(r)

        // The shipped feed's own words for the same reply.
        var expected: String?
        do { _ = try BridgeDiscoverFeed(path: "/nonexistent", transport: { _, _ in reply }).rails(limit: 30) }
        catch let e as SourceAppError { expected = e.message } catch {}
        XCTAssertNotNil(expected)
        XCTAssertEqual(r.scene.loadFailure, expected)
    }

    func testBridgeDrillInIsOneContainerTracksRequestWithItsKind() {
        let r = rig(mode: .source, feed: Self.webFeed())
        r.scene.drillIn(Self.playlistRow)
        tickUntil(r.scene) { !r.scene.trackRows.isEmpty }

        XCTAssertEqual(r.scene.trackRows.map(\.id), ["901", "902"])
        let sent = r.wire.sent("slice.containerTracks")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["id"] as? String, "pl.u-abc")
        XCTAssertEqual(sent.first?["kind"] as? String, "playlist")
        XCTAssertEqual(r.feed?.trackItems, [])
    }

    /// Bridge plays by id: the row's share URL is not sent and the opener is
    /// never touched.
    func testBridgeStationEnterIsOnePlayStationWithTheShippedToast() {
        let r = rig(mode: .source, feed: nil)
        loadRails(r)

        _ = r.scene.handle(.enter)

        let sent = r.wire.sent("slice.playStation")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["id"] as? String, "ra.978194965")
        XCTAssertEqual(sent.first?["name"] as? String, "Apple Music 1")
        XCTAssertEqual(sent.first?.keys.sorted(), ["id", "name", "op"])
        XCTAssertEqual(r.status.current()?.text, "Playing Apple Music 1")
        XCTAssertEqual(r.status.current()?.isError, false)
        XCTAssertEqual(r.opener.opened, [])
    }

    func testBridgeStationRefusalIsTheShippedSentence() {
        let reply = #"{"ok":false,"op":"slice.playStation","error":{"kind":"unresolvable","detail":"Apple Music doesn't carry Apple Music 1."}}"#
        let r = rig(mode: .source, feed: nil)
        r.wire.reply("slice.playStation", reply)
        loadRails(r)

        _ = r.scene.handle(.enter)

        let expected = shippedMessage(for: reply) { try $0.playStation(id: "ra.978194965", named: "Apple Music 1") }
        XCTAssertNotNil(expected)
        XCTAssertEqual(r.status.current()?.text, expected)
        XCTAssertEqual(r.status.current()?.isError, true)
    }

    func testBridgeSliceIsOneCatalogueQueueWithTheShippedToasts() {
        let r = rig(mode: .source, feed: nil, api: false)
        r.scene.playCatalogSlice(catalogIDs: ["802", "803"], containerTitle: "Boom Bap", trackName: "S2")
        drain(r.actions)

        let queued = r.wire.sent("slice.queue")
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?["ids"] as? [String], ["802", "803"])
        XCTAssertNil(queued.first?["library_ids"], "a catalogue queue must never send library ids")
        XCTAssertEqual(queued.first?.keys.sorted(), ["ids", "op"])
        XCTAssertEqual(r.status.current()?.text, "Playing S2 on Bridge — 2 tracks.")

        r.scene.playCatalogSlice(catalogIDs: ["803"], containerTitle: "Boom Bap", trackName: "S3")
        drain(r.actions)
        XCTAssertEqual(r.status.current()?.text, "Playing S3 on Bridge.")
        XCTAssertEqual(r.created.created, [])
    }

    func testBridgePlayAllReadsThenQueuesWithTheShippedToast() {
        let r = rig(mode: .source, feed: Self.webFeed(), api: false)
        r.scene.playAllFromRail(Self.playlistRow)
        drain(r.actions)

        XCTAssertEqual(r.wire.requests.compactMap { $0["op"] as? String },
                       ["slice.containerTracks", "slice.queue"])
        XCTAssertEqual(r.wire.sent("slice.queue").first?["ids"] as? [String], ["901", "902"])
        XCTAssertEqual(r.status.current()?.text, "Playing 'Boom Bap' on Bridge — 2 tracks.")
        XCTAssertEqual(r.feed?.trackItems, [])
        XCTAssertEqual(r.created.created, [])
    }

    func testBridgeQueueRefusalIsTheShippedSentence() {
        let reply = #"{"ok":false,"op":"slice.queue","error":{"kind":"bad_request","detail":"That's more than 100 songs."}}"#
        let r = rig(mode: .source, feed: nil, api: false)
        r.wire.reply("slice.queue", reply)
        r.scene.playCatalogSlice(catalogIDs: ["802"], containerTitle: "Boom Bap", trackName: "S2")
        drain(r.actions)

        let expected = shippedMessage(for: reply) { try $0.queue(catalogIDs: ["802"]) }
        XCTAssertNotNil(expected)
        XCTAssertEqual(r.status.current()?.text, expected)
        XCTAssertEqual(r.status.current()?.isError, true)
    }

    // MARK: - Structural: the scene no longer reaches around the seam

    func testTheSceneNoLongerNamesTheBespokeBridgeMembers() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TUI/Shell/DiscoverScene.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for bespoke in ["$0.discover", "$0.control.queue(catalogIDs:", "$0.control.playStation"] {
            XCTAssertFalse(text.contains(bespoke), "DiscoverScene still reaches Bridge through \(bespoke)")
        }
        XCTAssertTrue(text.contains("try routing.choose("), "the feed is not chosen through the seam")
    }
}
