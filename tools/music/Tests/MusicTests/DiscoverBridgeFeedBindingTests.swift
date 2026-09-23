import XCTest
@testable import music

/// Step 3's Discover half: the READS follow the Output tab.
///
/// **What these prove that `BridgeDiscoverFeedTests` cannot.** That file pins
/// the translation. It passes whether or not any call site ever asks the
/// coordinator which feed to read - the shape that left nine call sites unwired
/// until 2026-09-18. Each test here drives the MODE and fails if a read ignores
/// it.
///
/// **Bridge mode is driven with NO KEYS AT ALL**: no web-service feed and no
/// REST backend. That is the state DoD 6 promises works, and it is the one that
/// exposes a Music.app precondition checked outside the Music.app branch.
final class DiscoverBridgeFeedBindingTests: XCTestCase {

    // MARK: - Harness

    /// Answers by op, because one Discover action now spends more than one
    /// request (a track read, then a queue).
    private final class Wire {
        private let lock = NSLock()
        private var stored: [String] = []
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
            "slice.queue": #"{"ok":true,"op":"slice.queue","status":{"playback":"playing","title":"T1","artist":"A"}}"#,
            "slice.playStation": #"{"ok":true,"op":"slice.playStation","status":{"playback":"playing","title":"Apple Music 1","artist":""}}"#,
        ]

        var transport: (String, String) throws -> String {
            { [self] _, line in
                lock.lock(); stored.append(line); lock.unlock()
                let op = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["op"] as? String ?? ""
                return replies[op] ?? #"{"ok":false,"op":"?","error":{"kind":"bad_request","detail":"unexpected op"}}"#
            }
        }

        var requests: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return stored.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func sent(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }
    }

    /// Counts what the web-service feed was asked, so "Music.app mode is
    /// unchanged" is an observation rather than an absence.
    private final class WebService {
        private let lock = NSLock()
        private var stored: [String] = []
        var urls: [String] { lock.lock(); defer { lock.unlock() }; return stored }
        func feed() -> DiscoverFeed {
            DiscoverFeed(storefront: "us", token: { "t" }, fetch: { [self] url in
                lock.lock(); stored.append(url); lock.unlock()
                return Data(#"{"data":[]}"#.utf8)
            })
        }
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

    private func scene(mode: PlaybackMode, wire: Wire, status: StatusStore = StatusStore(),
                       feed: DiscoverFeed? = nil, api: RESTAPIBackend? = nil) -> DiscoverScene {
        let store = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        store.set(mode)
        let routing = RoutingCoordinator(store: store, surface: .tui,
                                         makeSource: { SourceAppClient(path: "/nonexistent",
                                                                       transport: wire.transport) })
        return DiscoverScene(feed: feed, status: status, actions: ActionRunner(status: status),
                             api: api, lifecycle: lifecycle(), routing: routing,
                             bridgeSelected: { routing.mode == .source })
    }

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])

    /// DoD 6's rename-away control, 2026-09-22: with `config.json` and
    /// `user-token` moved aside and Bridge selected, the tab rendered "Sign in
    /// to see your Discover feed" over rails the app was serving perfectly well.
    /// The tab's own door already followed the mode (`discoverTabAdmitted`);
    /// this second, render-time door did not — a fourth Music.app precondition
    /// checked outside the Music.app branch, after the three step 3 removed.
    func testBridgeModeNeverShowsTheSignInLineWithNoWebFeed() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire, feed: nil, api: nil)
        settle(s, until: { !s.render(frame: shellLayout(width: 120, height: 40), snapshot: self.idle)
            .contains("Loading") })
        let out = s.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)
        XCTAssertFalse(out.contains("Sign in to see your Discover feed"),
                       "Bridge serves this feed with no key at all")
        XCTAssertTrue(out.contains("Stations For You"), "the app's rails must render: \(out.prefix(300))")
    }

    /// The line still belongs to Music.app mode with no sign-in, which is the
    /// only state with no feed at all.
    func testMusicAppModeWithNoFeedStillSaysSignIn() {
        let s = scene(mode: .musicApp, wire: Wire(), feed: nil, api: nil)
        _ = s.tick(snapshot: idle)
        XCTAssertTrue(s.render(frame: shellLayout(width: 120, height: 40), snapshot: idle)
            .contains("Sign in to see your Discover feed"))
    }

    /// Ticks while it waits: the scene only drains its inbox inside `tick`.
    private func settle(_ s: DiscoverScene, seconds: Double = 2.0, until check: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = s.tick(snapshot: idle)
            if check() { return }
            usleep(10_000)
        }
    }

    private var playlistRow: DiscoverItem {
        DiscoverItem(id: "pl.u-abc", name: "Boom Bap", subtitle: nil, url: nil, artworkURL: nil,
                     detail: .playlist(description: nil))
    }

    // MARK: - Rails

    /// The binding, and DoD 6: with Bridge selected and no keys anywhere, the
    /// rails load from Bridge.
    func testInBridgeModeWithNoKeysTheRailsComeFromBridge() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire)

        settle(s) { !s.rails.isEmpty }

        XCTAssertEqual(s.rails.map(\.title), ["Stations For You"])
        XCTAssertEqual(wire.sent("slice.recommendations").count, 1)
    }

    /// And Music.app mode still reads the web service, so the test above cannot
    /// pass with the mode ignored.
    func testInMusicAppModeTheRailsStillComeFromTheWebService() {
        let wire = Wire()
        let web = WebService()
        let s = scene(mode: .musicApp, wire: wire, feed: web.feed())

        settle(s) { !web.urls.isEmpty }

        XCTAssertTrue(web.urls.first?.contains("/v1/me/recommendations") ?? false)
        XCTAssertTrue(wire.requests.isEmpty, "Music.app mode sent a Bridge request")
    }

    /// No automatic fallback either way: Bridge selected means Bridge is read,
    /// even when a perfectly good web-service feed is sitting right there.
    func testBridgeModeDoesNotFallBackToAnAvailableWebService() {
        let wire = Wire()
        wire.replies["slice.recommendations"] =
            #"{"ok":false,"op":"slice.recommendations","error":{"kind":"bad_request","detail":"Discover is unavailable right now."}}"#
        let web = WebService()
        let s = scene(mode: .source, wire: wire, feed: web.feed())

        settle(s) { s.loadFailure != nil }

        XCTAssertTrue(web.urls.isEmpty, "a Bridge failure fell back to the web service")
        XCTAssertTrue(s.loadFailure?.contains("Discover is unavailable right now.") ?? false,
                      "Bridge's own reason was lost; got: \(s.loadFailure ?? "nil")")
    }

    /// Music.app mode with no sign-in must say so. Before this it sat on
    /// "Loading…" forever, which only the tab's door had been hiding.
    func testMusicAppModeWithNoSignInSaysSoInsteadOfLoadingForever() {
        let s = scene(mode: .musicApp, wire: Wire())

        settle(s) { s.loadFailure != nil }

        XCTAssertTrue(s.loadFailure?.contains("music auth setup") ?? false)
    }

    // MARK: - Opening a container

    /// A playlist opens on Bridge, asked for AS a playlist.
    func testInBridgeModeAPlaylistOpensFromBridge() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire)

        s.drillIn(playlistRow)
        settle(s) { !s.trackRows.isEmpty }

        XCTAssertEqual(s.trackRows.map(\.id), ["901", "902"])
        XCTAssertEqual(wire.sent("slice.containerTracks").first?["kind"] as? String, "playlist")
    }

    /// A refusal to open reaches the person in Bridge's words. It used to be
    /// swallowed into an empty list that rendered as "No tracks."
    func testARefusalToOpenIsShownNotSwallowed() {
        let wire = Wire()
        wire.replies["slice.containerTracks"] =
            #"{"ok":false,"op":"slice.containerTracks","error":{"kind":"unresolvable","detail":"That playlist isn't in Apple Music's catalogue."}}"#
        let status = StatusStore()
        let s = scene(mode: .source, wire: wire, status: status)

        s.drillIn(playlistRow)
        settle(s) { status.current() != nil }

        XCTAssertTrue(status.current()?.text.contains("That playlist isn't in Apple Music's catalogue.") ?? false,
                      "got: \(status.current()?.text ?? "nil")")
    }

    /// The counterpart, and the standing rule at the read this change touched:
    /// with Music.app selected a container still opens from the web service and
    /// Bridge is never asked (Codex S4).
    func testInMusicAppModeAContainerStillOpensFromTheWebService() {
        let wire = Wire()
        let web = WebService()
        let s = scene(mode: .musicApp, wire: wire, feed: web.feed())

        s.drillIn(playlistRow)
        settle(s) { web.urls.contains { $0.contains("/playlists/pl.u-abc") } }

        XCTAssertTrue(web.urls.contains { $0.contains("/playlists/pl.u-abc?include=tracks") },
                      "got: \(web.urls)")
        XCTAssertTrue(wire.requests.isEmpty, "Music.app mode sent a Bridge request")
    }

    // MARK: - Play, with no keys

    /// `p` on a rail row: the read AND the play both reach Bridge, with no REST
    /// backend present. The "Sign in to play" door is a Music.app precondition.
    func testPlayAllInBridgeModeNeedsNoKeys() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire)

        s.playAllFromRail(playlistRow)
        settle(s) { !wire.sent("slice.queue").isEmpty }

        XCTAssertEqual(wire.sent("slice.queue").first?["ids"] as? [String], ["901", "902"])
    }

    /// Track-level Enter through the PRODUCTION door, with no keys: open the
    /// playlist, move to its second track, press Enter. Calling
    /// `playCatalogSlice` directly would pass with `playFromHere`'s old
    /// unconditional sign-in guard reinstated (Codex S3).
    func testEnterOnATrackRowInBridgeModeNeedsNoKeys() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire)
        settle(s) { !s.rails.isEmpty }

        _ = s.handle(.down)    // the playlist row
        _ = s.handle(.enter)   // opens it
        settle(s) { !s.trackRows.isEmpty }
        _ = s.handle(.down)    // its second track
        _ = s.handle(.enter)   // play from here
        settle(s) { !wire.sent("slice.queue").isEmpty }

        XCTAssertEqual(wire.sent("slice.queue").first?["ids"] as? [String], ["902"])
    }

    /// Enter on a station row Bridge sent. Such a row carries no share URL, and
    /// the URL is only how MUSIC.APP plays a station.
    func testAStationRowFromBridgePlaysOnBridge() {
        let wire = Wire()
        let s = scene(mode: .source, wire: wire)
        settle(s) { !s.rails.isEmpty }

        _ = s.handle(.enter)   // the cursor opens on the first row: the station

        XCTAssertEqual(wire.sent("slice.playStation").first?["id"] as? String, "ra.978194965")
    }
}
