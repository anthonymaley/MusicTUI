import XCTest
@testable import music

/// Slice 3, Part 2, P5: the Radio tab folded onto the provider seam.
///
/// Live, Personal, `/` search, station play and add-by-URL enrichment each
/// choose a `StationProviding` with `routing.choose` — the REST catalogue and
/// opener wrapped in an `OpenMusicProvider`, or a `BridgeMusicProvider` — and
/// every async result carries the epoch its provider was chosen at. A result
/// from before a committed output switch is dropped when it drains; Live and
/// Personal refetch from the new output. Favourites stay local.
///
/// Real coordinator on a temp mode store; the wire, the REST fetch and the
/// opener are counting doubles. **No sleeps**: a held reply is a semaphore
/// barrier, and the scene's background work is drained by ticking until it
/// lands, bounded so a hang is a failure rather than a pass.
final class RadioProviderTests: XCTestCase {

    // MARK: - Harness

    /// Answers by op; records every request line; can hold one op's reply
    /// until the test releases it.
    private final class Wire {
        private let lock = NSLock()
        private var stored: [String] = []
        private var scripted: [String: String] = [
            "slice.liveStations": #"{"ok":true,"op":"slice.liveStations","stations":[\#(Wire.station("ra.b1", "Bridge Live", live: true))]}"#,
            "slice.personalStations": #"{"ok":true,"op":"slice.personalStations","stations":[\#(Wire.station("ra.b2", "Bridge Personal", live: false))]}"#,
            "slice.searchStations": #"{"ok":true,"op":"slice.searchStations","stations":[\#(Wire.station("ra.b3", "Bridge Jazz", live: false))]}"#,
            "slice.station": #"{"ok":true,"op":"slice.station","station":\#(Wire.station("ra.978194965", "Apple Music 1 (Bridge)", live: true))}"#,
            "slice.playStation": #"{"ok":true,"op":"slice.playStation","status":{"playback":"playing","title":"Apple Music 1","artist":""}}"#,
        ]
        private var held: [String: (entered: DispatchSemaphore, release: DispatchSemaphore)] = [:]

        static func station(_ id: String, _ name: String, live: Bool) -> String {
            #"{"id":"\#(id)","name":"\#(name)","url":"https://music.apple.com/us/station/x/\#(id)","is_live":\#(live),"artwork_url":null}"#
        }

        func reply(_ op: String, _ json: String) { lock.lock(); scripted[op] = json; lock.unlock() }

        /// The next `op` request blocks inside the transport until `release`.
        func hold(_ op: String) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
            let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
            lock.lock(); held[op] = gate; lock.unlock()
            return gate
        }

        var transport: (String, String) throws -> String {
            { [self] _, line in
                let op = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["op"] as? String ?? ""
                lock.lock()
                stored.append(line)
                let gate = held.removeValue(forKey: op)
                lock.unlock()
                if let gate {
                    gate.entered.signal()
                    _ = gate.release.wait(timeout: .now() + 5)
                }
                lock.lock(); defer { lock.unlock() }
                return scripted[op] ?? #"{"ok":false,"op":"?","error":{"kind":"bad_request","detail":"unexpected op"}}"#
            }
        }

        var requests: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return stored.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func sent(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }
    }

    /// The REST catalogue's fetch: records every URL, answers by kind.
    private final class REST {
        private let lock = NSLock()
        private var stored: [String] = []
        private var held: [(entered: DispatchSemaphore, release: DispatchSemaphore, match: String)] = []
        /// A transport-level failure (`RadioCatalogError.fetchFailed`).
        var fails = false
        /// The status the Personal filter answers with — 403 pins the
        /// 2026-09-25 gate finding (a developer-token-only Personal read).
        var personalStatus = 200
        var personalErrorTitle: String? = nil
        var hasUserToken = false

        static func body(_ id: String, _ name: String) -> Data {
            Data(#"{"data":[{"id":"\#(id)","attributes":{"name":"\#(name)","url":"https://music.apple.com/us/station/x/\#(id)","isLive":true}}]}"#.utf8)
        }

        func hold(matching fragment: String) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
            let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0), match: fragment)
            lock.lock(); held.append(gate); lock.unlock()
            return (gate.entered, gate.release)
        }

        func fetch(_ url: String) -> RadioCatalogResponse? {
            lock.lock()
            stored.append(url)
            var gate: (entered: DispatchSemaphore, release: DispatchSemaphore, match: String)?
            if let i = held.firstIndex(where: { url.contains($0.match) }) { gate = held.remove(at: i) }
            let failing = fails
            let pStatus = personalStatus
            let pTitle = personalErrorTitle
            lock.unlock()
            if let gate {
                gate.entered.signal()
                _ = gate.release.wait(timeout: .now() + 5)
            }
            if failing { return nil }
            if url.contains("filter[featured]") { return RadioCatalogResponse(status: 200, data: Self.body("ra.r1", "REST Live")) }
            if url.contains("filter[identity]") {
                guard pStatus == 200 else {
                    let body = pTitle.map { Data(#"{"errors":[{"title":"\#($0)"}]}"#.utf8) } ?? Data()
                    return RadioCatalogResponse(status: pStatus, data: body)
                }
                return RadioCatalogResponse(status: 200, data: Self.body("ra.r2", "REST Personal"))
            }
            if url.contains("/search?") {
                return RadioCatalogResponse(status: 200, data: Data(#"{"results":{"stations":{"data":[{"id":"ra.r3","attributes":{"name":"REST Jazz","url":"https://music.apple.com/us/station/x/ra.r3"}}]}}}"#.utf8))
            }
            if url.contains("ids=") { return RadioCatalogResponse(status: 200, data: Self.body("ra.978194965", "Apple Music 1 (REST)")) }
            return nil
        }

        var urls: [String] { lock.lock(); defer { lock.unlock() }; return stored }
        func count(_ fragment: String) -> Int { urls.filter { $0.contains(fragment) }.count }
    }

    private final class CountingOpener: Opener {
        private let lock = NSLock()
        private var stored: [String] = []
        func open(_ url: String) throws { lock.lock(); stored.append(url); lock.unlock() }
        var opened: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Counts how many times the coordinator built a source client.
    private final class Counter {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private struct Rig {
        let scene: RadioScene
        let routing: RoutingCoordinator
        let wire: Wire
        let rest: REST
        let opener: CountingOpener
        let store: StationStore
        let sourceBuilt: Counter
    }

    private func rig(mode: PlaybackMode, catalog withCatalog: Bool) -> Rig {
        let wire = Wire()
        let rest = REST()
        let opener = CountingOpener()
        let built = Counter()
        let modeStore = PlaybackModeStore(path: NSTemporaryDirectory() + "mode-\(UUID().uuidString).json")
        modeStore.set(mode)
        let routing = RoutingCoordinator(store: modeStore, surface: .tui,
                                         makeSource: {
                                             built.bump()
                                             return SourceAppClient(path: "/nonexistent", transport: wire.transport)
                                         })
        let catalog = withCatalog
            ? RadioCatalog(storefront: "us", token: { "dev" }, fetch: { rest.fetch($0) },
                          hasUserToken: { rest.hasUserToken })
            : nil
        let store = StationStore(path: NSTemporaryDirectory() + "stations-\(UUID().uuidString).json")
        let scene = RadioScene(routing: routing, store: store, catalog: catalog, opener: opener)
        return Rig(scene: scene, routing: routing, wire: wire, rest: rest, opener: opener, store: store,
                   sourceBuilt: built)
    }

    private let idle = NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: [])
    private let frame = shellLayout(width: 100, height: 30)

    /// Ticks until `check` holds. No sleep: the loop only drains the inbox, and
    /// the bound turns a hang into a failure.
    @discardableResult
    private func tickUntil(_ s: RadioScene, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { _ = s.tick(snapshot: idle) }
        return check()
    }

    private func loadBoth(_ r: Rig) {
        XCTAssertTrue(tickUntil(r.scene) { r.scene.liveLoaded && r.scene.personalLoaded },
                      "Live and Personal never both landed")
    }

    /// After a switch: the first tick must have cleared both lists (the old
    /// output's rows go at once), then both land again from the new output.
    ///
    /// The new output's two reads are held across that first tick, so "cleared"
    /// cannot be confused with "already replaced".
    private func refetch(_ r: Rig) {
        let gates: [(entered: DispatchSemaphore, release: DispatchSemaphore)] = r.routing.mode == .source
            ? [r.wire.hold("slice.liveStations"), r.wire.hold("slice.personalStations")]
            : [r.rest.hold(matching: "filter[featured]"), r.rest.hold(matching: "filter[identity]")]
        _ = r.scene.tick(snapshot: idle)
        XCTAssertEqual(r.scene.live, [], "the old output's Live rows survived the switch")
        XCTAssertEqual(r.scene.personal, [], "the old output's Personal rows survived the switch")
        XCTAssertFalse(r.scene.liveLoaded)
        XCTAssertFalse(r.scene.personalLoaded)
        for g in gates { wait(g.entered, "the new output's read"); g.release.signal() }
        loadBoth(r)
    }

    private func switchTo(_ mode: PlaybackMode, _ routing: RoutingCoordinator) throws {
        let result = try routing.switchMode(to: mode, readiness: { .ready },
                                            pauseOutgoing: { _ in true }, dropQueue: { _ in })
        XCTAssertEqual(result, .switched(to: mode))
    }

    private func wait(_ s: DispatchSemaphore, _ what: String) {
        XCTAssertEqual(s.wait(timeout: .now() + 5), .success, "\(what) never happened")
    }

    private func type(_ text: String, _ scene: RadioScene) {
        for c in text { _ = scene.handle(.char(c)) }
    }

    private func search(_ scene: RadioScene, _ term: String) {
        _ = scene.handle(.char("/")); type(term, scene); _ = scene.handle(.enter)
    }

    private static let am1URL = "https://music.apple.com/us/station/apple-music-1/ra.978194965"

    private func addURL(_ scene: RadioScene, _ url: String = am1URL) {
        _ = scene.handle(.char("a")); type(url, scene); _ = scene.handle(.enter)
    }

    private func favouriteName(_ r: Rig, id: String = "ra.978194965") -> String? {
        r.store.favorites().first { $0.id == id }?.name
    }

    private static let station = Station(id: "ra.978194965", name: "Apple Music 1", url: am1URL,
                                         isLive: true, artworkURL: nil)

    // MARK: - Music.app mode: the REST catalogue, exactly as ships, no wire

    func testMusicAppWithCatalogReadsLiveAndPersonalOnceEachFromRESTAndNoWire() {
        let r = rig(mode: .musicApp, catalog: true)
        loadBoth(r)

        XCTAssertEqual(r.scene.live.map(\.name), ["REST Live"])
        XCTAssertEqual(r.scene.personal.map(\.name), ["REST Personal"])
        XCTAssertEqual(r.rest.count("filter[featured]=apple-music-live-radio"), 1)
        XCTAssertEqual(r.rest.count("filter[identity]=personal"), 1)
        XCTAssertTrue(r.wire.requests.isEmpty, "Music.app mode sent a Bridge request")
        XCTAssertEqual(r.sourceBuilt.value, 0, "Music.app mode built a Bridge client")
        XCTAssertNil(r.scene.message)
    }

    /// personal-radio defect fix: Music.app mode used to swallow every REST
    /// failure into an empty, loaded list with no message (`(try? read()) ??
    /// []`). Both lists still land empty on a transport failure, but the
    /// person now sees why instead of a silently empty tab.
    func testMusicAppRESTFailureIsAnEmptyLoadedListWithAMessage() {
        let r = rig(mode: .musicApp, catalog: true)
        r.rest.fails = true
        loadBoth(r)

        XCTAssertEqual(r.scene.live, [])
        XCTAssertEqual(r.scene.personal, [])
        XCTAssertNotNil(r.scene.message, "a REST failure was silently swallowed again")
    }

    /// The defect itself, live-gated 2026-09-25: a developer-token-only
    /// Personal read gets 403. With no Music-User-Token on hand, the person
    /// sees a message telling them to authorize — not an empty list — and
    /// Live is unaffected.
    func testMusicAppPersonal403WithNoUserTokenTellsThePersonToRunAuth() {
        let r = rig(mode: .musicApp, catalog: true)
        r.rest.personalStatus = 403
        r.rest.personalErrorTitle = "Forbidden"
        r.rest.hasUserToken = false
        loadBoth(r)

        XCTAssertEqual(r.scene.personal, [])
        XCTAssertEqual(r.scene.live.map(\.name), ["REST Live"], "Live must be unaffected by the Personal 403")
        XCTAssertEqual(r.scene.message, "✗ Personal stations need a Music User Token. Run: music auth")
    }

    /// Same 403, but a Music-User-Token IS on hand (expired/invalid rather
    /// than missing) — the "run auth" message would be the wrong advice, so
    /// Apple's own words are shown instead.
    func testMusicAppPersonal403WithUserTokenShowsAppleWordsNotTheAuthMessage() {
        let r = rig(mode: .musicApp, catalog: true)
        r.rest.personalStatus = 403
        r.rest.personalErrorTitle = "Forbidden"
        r.rest.hasUserToken = true
        loadBoth(r)

        XCTAssertEqual(r.scene.personal, [])
        XCTAssertEqual(r.scene.message, "✗ Forbidden (status 403).")
    }

    /// A 401 is a developer-token problem (Apple's docs), which `music auth`
    /// would not fix, so even with no user token the person sees Apple's own
    /// words and status, not the auth advice.
    func testMusicAppPersonal401KeepsAppleWordsEvenWithNoUserToken() {
        let r = rig(mode: .musicApp, catalog: true)
        r.rest.personalStatus = 401
        r.rest.personalErrorTitle = "Unauthorized"
        r.rest.hasUserToken = false
        loadBoth(r)

        XCTAssertEqual(r.scene.personal, [])
        XCTAssertEqual(r.scene.message, "✗ Unauthorized (status 401).")
    }

    func testMusicAppWithoutCatalogFetchesNothingFavouritesRenderAndSearchRefusesAsShipped() throws {
        let r = rig(mode: .musicApp, catalog: false)
        try r.store.add(Self.station)
        for _ in 0..<50 { _ = r.scene.tick(snapshot: idle) }

        let out = r.scene.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("Apple Music 1"), "favourites did not render: \(out)")
        XCTAssertFalse(r.scene.liveLoaded)
        XCTAssertFalse(r.scene.personalLoaded)

        search(r.scene, "jazz")
        XCTAssertEqual(r.scene.message, "✗ Search needs auth (music auth setup)")

        // The Live sub-view reads "(no live stations)", not a spinner that
        // never ends: nothing will load without a key.
        _ = r.scene.handle(.char("]"))
        XCTAssertTrue(r.scene.render(frame: frame, snapshot: idle).contains("(no live stations)"))

        XCTAssertTrue(r.rest.urls.isEmpty)
        XCTAssertTrue(r.wire.requests.isEmpty)
        XCTAssertEqual(r.sourceBuilt.value, 0)
    }

    func testMusicAppSearchAndAddReachRESTAndNoWire() {
        let r = rig(mode: .musicApp, catalog: true)
        loadBoth(r)

        search(r.scene, "jazz")
        XCTAssertTrue(tickUntil(r.scene) { r.scene.message?.contains("1 result") == true })
        XCTAssertTrue(r.scene.render(frame: frame, snapshot: idle).contains("REST Jazz"))

        addURL(r.scene)
        XCTAssertEqual(favouriteName(r), "Apple Music 1", "the slug favourite is saved first")
        XCTAssertTrue(tickUntil(r.scene) { self.favouriteName(r) == "Apple Music 1 (REST)" })

        XCTAssertEqual(r.rest.count("/search?term=jazz"), 1)
        XCTAssertEqual(r.rest.count("ids=ra.978194965"), 1)
        XCTAssertTrue(r.wire.requests.isEmpty)
    }

    // MARK: - Bridge mode: Bridge only, even with a key present

    func testBridgeWithCatalogPresentReadsLiveAndPersonalFromBridgeAndNoREST() {
        let r = rig(mode: .source, catalog: true)
        loadBoth(r)

        XCTAssertEqual(r.scene.live.map(\.name), ["Bridge Live"])
        XCTAssertEqual(r.scene.personal.map(\.name), ["Bridge Personal"])
        XCTAssertEqual(r.wire.sent("slice.liveStations").count, 1)
        XCTAssertEqual(r.wire.sent("slice.personalStations").count, 1)
        XCTAssertTrue(r.rest.urls.isEmpty, "Bridge mode reached the REST catalogue: \(r.rest.urls)")
        XCTAssertEqual(r.opener.opened, [])
    }

    func testBridgeLiveFailureShowsItsSentenceAndAnEmptyLoadedList() {
        let r = rig(mode: .source, catalog: true)
        r.wire.reply("slice.liveStations",
                     #"{"ok":false,"op":"slice.liveStations","error":{"kind":"unknown_op","detail":"no such op"}}"#)
        loadBoth(r)

        XCTAssertEqual(r.scene.live, [])
        XCTAssertEqual(r.scene.message, "✗ This Bridge build can't list live stations — update Bridge")
        XCTAssertEqual(r.scene.personal.map(\.name), ["Bridge Personal"])
        XCTAssertTrue(r.rest.urls.isEmpty, "a Bridge failure fell back to REST")
    }

    func testBridgeWithNoCatalogShowsLoadingUntilTheListLands() {
        let r = rig(mode: .source, catalog: false)
        let gate = r.wire.hold("slice.liveStations")
        _ = r.scene.handle(.char("]"))   // the Live sub-view
        _ = r.scene.tick(snapshot: idle)
        wait(gate.entered, "the Live read")

        XCTAssertTrue(r.scene.render(frame: frame, snapshot: idle).contains("Loading\u{2026}"))
        gate.release.signal()
        XCTAssertTrue(tickUntil(r.scene) { r.scene.liveLoaded })
        XCTAssertTrue(r.scene.render(frame: frame, snapshot: idle).contains("Bridge Live"))
    }

    func testBridgeSearchIsTheShippedRequestAndNoREST() {
        let r = rig(mode: .source, catalog: true)
        search(r.scene, "jazz")
        XCTAssertTrue(tickUntil(r.scene) { r.scene.message?.contains("1 result") == true })

        XCTAssertTrue(r.scene.render(frame: frame, snapshot: idle).contains("Bridge Jazz"))
        let sent = r.wire.sent("slice.searchStations")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["term"] as? String, "jazz")
        XCTAssertEqual(sent.first?["limit"] as? Int, 25)
        XCTAssertEqual(r.rest.count("/search?"), 0)
    }

    func testBridgeAddLooksTheStationUpOnBridgeAndNoREST() {
        let r = rig(mode: .source, catalog: true)
        addURL(r.scene)
        XCTAssertEqual(favouriteName(r), "Apple Music 1", "the slug favourite is saved first")
        XCTAssertTrue(tickUntil(r.scene) { self.favouriteName(r) == "Apple Music 1 (Bridge)" })

        XCTAssertEqual(r.wire.sent("slice.station").first?["id"] as? String, "ra.978194965")
        XCTAssertEqual(r.rest.count("ids="), 0, "Bridge mode resolved the station over REST")
    }

    func testBridgeAddWhenBridgeCannotLookUpKeepsTheSlugName() {
        let r = rig(mode: .source, catalog: true)
        r.wire.reply("slice.station", #"{"ok":true,"op":"slice.station","station":null}"#)
        addURL(r.scene)
        XCTAssertTrue(tickUntil(r.scene) { !r.wire.sent("slice.station").isEmpty })
        for _ in 0..<20 { _ = r.scene.tick(snapshot: idle) }

        XCTAssertEqual(favouriteName(r), "Apple Music 1")
        XCTAssertEqual(r.rest.count("ids="), 0)
    }

    // MARK: - Station play: exactly one op or one opener call

    func testBridgeStationPlayIsOnePlayStationAndNoOpener() {
        let r = rig(mode: .source, catalog: true)
        r.scene.execute(.play(Self.station))

        XCTAssertEqual(r.wire.sent("slice.playStation").count, 1)
        XCTAssertEqual(r.wire.sent("slice.playStation").first?["id"] as? String, "ra.978194965")
        XCTAssertEqual(r.opener.opened, [])
        XCTAssertEqual(r.scene.message, "▶ Apple Music 1")
    }

    func testMusicAppStationPlayIsOneOpenerCallAndNoWire() {
        let r = rig(mode: .musicApp, catalog: true)
        r.scene.execute(.play(Self.station))

        XCTAssertEqual(r.opener.opened, ["music://music.apple.com/us/station/apple-music-1/ra.978194965"])
        XCTAssertTrue(r.wire.requests.isEmpty)
        XCTAssertEqual(r.scene.message, "▶ Apple Music 1")
    }

    // MARK: - Epochs

    func testASwitchAfterLoadRefetchesFromTheNewOutput() throws {
        let r = rig(mode: .source, catalog: true)
        loadBoth(r)
        XCTAssertEqual(r.scene.live.map(\.name), ["Bridge Live"])

        try switchTo(.musicApp, r.routing)
        refetch(r)
        XCTAssertEqual(r.scene.live.map(\.name), ["REST Live"])
        XCTAssertEqual(r.scene.personal.map(\.name), ["REST Personal"])
        XCTAssertEqual(r.rest.count("filter[featured]"), 1)
        XCTAssertEqual(r.wire.sent("slice.liveStations").count, 1, "Bridge was read again after leaving it")

        try switchTo(.source, r.routing)
        refetch(r)
        XCTAssertEqual(r.scene.live.map(\.name), ["Bridge Live"])
        XCTAssertEqual(r.wire.sent("slice.liveStations").count, 2)
        XCTAssertEqual(r.rest.count("filter[featured]"), 1)
    }

    func testALiveResultHeldAcrossASwitchIsDropped() throws {
        let r = rig(mode: .source, catalog: true)
        let bridgeLive = r.wire.hold("slice.liveStations")
        _ = r.scene.tick(snapshot: idle)
        wait(bridgeLive.entered, "the Bridge Live read")

        // The switch commits while Bridge's Live answer is in flight: the
        // read holds no lock, so the switch is not delayed by it.
        try switchTo(.musicApp, r.routing)
        // Hold the REST Live read, so the only Live result that can land
        // before it is the stale Bridge one.
        let restLive = r.rest.hold(matching: "filter[featured]")
        bridgeLive.release.signal()

        XCTAssertTrue(tickUntil(r.scene) { r.scene.staleDrops.contains("live") },
                      "the Bridge Live result was never drained as stale")
        XCTAssertEqual(r.scene.live, [], "a Live result from the output just left was shown")
        XCTAssertFalse(r.scene.liveLoaded)

        wait(restLive.entered, "the REST Live refetch")
        restLive.release.signal()
        XCTAssertTrue(tickUntil(r.scene) { r.scene.liveLoaded })
        XCTAssertEqual(r.scene.live.map(\.name), ["REST Live"])
    }

    func testAStaleSearchShowsTheSentenceAndNoHits() throws {
        let r = rig(mode: .source, catalog: true)
        let gate = r.wire.hold("slice.searchStations")
        search(r.scene, "jazz")
        wait(gate.entered, "the Bridge search")
        try switchTo(.musicApp, r.routing)
        gate.release.signal()

        XCTAssertTrue(tickUntil(r.scene) { r.scene.staleDrops.contains("search") })
        XCTAssertEqual(r.scene.message, "✗ Output changed while searching; search again.")
        let out = r.scene.render(frame: frame, snapshot: idle)
        XCTAssertFalse(out.contains("Bridge Jazz"), "stale hits were shown: \(out)")
        XCTAssertFalse(out.contains("Search Results"))
    }

    func testAStaleEnrichmentKeepsTheSlugName() throws {
        let r = rig(mode: .source, catalog: false)
        let gate = r.wire.hold("slice.station")
        addURL(r.scene)
        wait(gate.entered, "the Bridge lookup")
        try switchTo(.musicApp, r.routing)
        gate.release.signal()

        XCTAssertTrue(tickUntil(r.scene) { r.scene.staleDrops.contains("lookup") })
        XCTAssertEqual(favouriteName(r), "Apple Music 1", "a lookup from the output just left renamed the favourite")
    }

    /// The choice runs on the fetch thread: a playback action holding the
    /// ordering lock must not stall `tick`, which is the shell's paint loop.
    func testTickDoesNotWaitOnTheOrderingLock() {
        let r = rig(mode: .musicApp, catalog: true)
        let inside = DispatchSemaphore(value: 0)
        let letGo = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? r.routing.perform(.radioStationPlay,
                                   musicApp: { inside.signal(); _ = letGo.wait(timeout: .now() + 5) },
                                   source: { _ in }, unaffected: {})
        }
        wait(inside, "the held playback action")

        let ticked = DispatchSemaphore(value: 0)
        Thread.detachNewThread { _ = r.scene.tick(snapshot: self.idle); ticked.signal() }
        XCTAssertEqual(ticked.wait(timeout: .now() + 2), .success,
                       "tick waited on the ordering lock: the choice ran on the paint thread")

        letGo.signal()
        loadBoth(r)
        XCTAssertEqual(r.scene.live.map(\.name), ["REST Live"])
    }

    // MARK: - Epoch-monotonic inboxes: a stale post never replaces a fresh one
    //
    // Codex, Part 2 review: each inbox is one slot. When the new output's post
    // is written FIRST and the old output's lands after it, a last-writer-wins
    // slot kept the stale one, the drain dropped it, and the fetch flags stayed
    // set — the fresh result was lost with no retry. Each test pins that order
    // with `postsOffered` (no tick runs between the two writes), then ticks once.

    /// Waits, without ticking, until `check` holds. Bounded; no sleep.
    private func waitWithoutTicking(_ what: String, _ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline {}
        XCTAssertTrue(check(), "\(what) never happened")
    }

    func testAFreshBrowsePostWrittenBeforeAStaleOneStillLands() throws {
        let r = rig(mode: .source, catalog: true)
        let bridgeLive = r.wire.hold("slice.liveStations")
        let bridgePersonal = r.wire.hold("slice.personalStations")
        _ = r.scene.tick(snapshot: idle)
        wait(bridgeLive.entered, "the Bridge Live read")
        wait(bridgePersonal.entered, "the Bridge Personal read")

        try switchTo(.musicApp, r.routing)
        let restLive = r.rest.hold(matching: "filter[featured]")
        let restPersonal = r.rest.hold(matching: "filter[identity]")
        _ = r.scene.tick(snapshot: idle)            // resets; starts the REST reads
        wait(restLive.entered, "the REST Live read")
        wait(restPersonal.entered, "the REST Personal read")

        // Fresh first, and written before anything drains.
        restLive.release.signal(); restPersonal.release.signal()
        waitWithoutTicking("the fresh posts") {
            r.scene.postsOffered("live") == 1 && r.scene.postsOffered("personal") == 1
        }
        // Then the stale ones, also written before anything drains.
        bridgeLive.release.signal(); bridgePersonal.release.signal()
        waitWithoutTicking("the stale posts") {
            r.scene.postsOffered("live") == 2 && r.scene.postsOffered("personal") == 2
        }

        _ = r.scene.tick(snapshot: idle)
        XCTAssertEqual(r.scene.live.map(\.name), ["REST Live"], "the fresh Live result was lost")
        XCTAssertEqual(r.scene.personal.map(\.name), ["REST Personal"], "the fresh Personal result was lost")
        XCTAssertTrue(r.scene.liveLoaded)
        XCTAssertTrue(r.scene.personalLoaded)
    }

    func testAFreshSearchWrittenBeforeAStaleOneStillShowsItsHits() throws {
        let r = rig(mode: .source, catalog: true)
        let bridgeSearch = r.wire.hold("slice.searchStations")
        search(r.scene, "jazz")
        wait(bridgeSearch.entered, "the Bridge search")

        try switchTo(.musicApp, r.routing)
        search(r.scene, "jazz")                     // the REST search, not held
        waitWithoutTicking("the fresh search post") { r.scene.postsOffered("search") == 1 }
        bridgeSearch.release.signal()
        waitWithoutTicking("the stale search post") { r.scene.postsOffered("search") == 2 }

        _ = r.scene.tick(snapshot: idle)
        XCTAssertEqual(r.scene.message,
                       "Search \u{201C}jazz\u{201D} \u{2014} 1 result(s) \u{00B7} f favorite \u{00B7} Esc clear")
        let out = r.scene.render(frame: frame, snapshot: idle)
        XCTAssertTrue(out.contains("REST Jazz"), "the fresh hits were lost: \(out)")
        XCTAssertFalse(out.contains("Bridge Jazz"))
    }

    func testAFreshLookupWrittenBeforeAStaleOneStillRenamesTheFavourite() throws {
        let r = rig(mode: .source, catalog: true)
        let bridgeLookup = r.wire.hold("slice.station")
        addURL(r.scene)
        wait(bridgeLookup.entered, "the Bridge lookup")

        try switchTo(.musicApp, r.routing)
        addURL(r.scene)                             // the REST lookup, not held
        waitWithoutTicking("the fresh lookup post") { r.scene.postsOffered("lookup") == 1 }
        bridgeLookup.release.signal()
        waitWithoutTicking("the stale lookup post") { r.scene.postsOffered("lookup") == 2 }

        _ = r.scene.tick(snapshot: idle)
        XCTAssertEqual(favouriteName(r), "Apple Music 1 (REST)", "the fresh lookup was lost")
    }

    // MARK: - Structural: the scene no longer reaches around the seam

    func testTheSceneNoLongerNamesTheBespokeMembersOrTheCatalogueDirectly() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TUI/Shell/RadioScene.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for bespoke in ["$0.stationSearch", "$0.control.playStation", "catalog.liveStations",
                        "catalog.personalStation", "catalog.resolve", "catalog.search"] {
            XCTAssertFalse(text.contains(bespoke), "RadioScene still reaches around the seam through \(bespoke)")
        }
        XCTAssertTrue(text.contains("routing.choose("), "stations are not chosen through the seam")
    }
}
