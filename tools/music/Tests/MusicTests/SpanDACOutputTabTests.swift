// tools/music/Tests/MusicTests/SpanDACOutputTabTests.swift
//
// SpanDACs on the network in the Output tab (the pairing design, 4.2 and
// 4.3): the rows and their notes, pairing as status-line prompts, forgetting,
// and a real pairing session over loopback TCP against a source written in
// the tests. No Bonjour, no real SpanDAC, no ~/.config/music, no Music.app.
import Network
import XCTest
@testable import music

// MARK: - Fakes

final class FakeSpanDACBrowser: SpanDACBrowsing {
    private let lock = NSLock()
    private var callback: (([SpanDACSighting]) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    var running: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }

    func start(_ results: @escaping ([SpanDACSighting]) -> Void) {
        lock.lock(); callback = results; starts += 1; lock.unlock()
    }
    func stop() { lock.lock(); callback = nil; stops += 1; lock.unlock() }
    func emit(_ sightings: [SpanDACSighting]) {
        lock.lock(); let cb = callback; lock.unlock()
        cb?(sightings)
    }
}

final class FakePairingHandle: SpanDACPairingHandle {
    private(set) var answers: [Bool] = []
    private(set) var cancelled = false
    func answer(matches: Bool) { answers.append(matches) }
    func cancel() { cancelled = true }
}

final class FakePairingDriver: SpanDACPairingDriving {
    struct Begun { let serviceName: String; let port: UInt16; let controllerID: String; let controllerName: String }
    private(set) var begun: [Begun] = []
    let handle = FakePairingHandle()
    var save: ((SpanDACPairResult) -> String?)?
    var events: ((SpanDACPairingEvent) -> Void)?

    func begin(serviceName: String, port: UInt16, controllerID: String, controllerName: String,
               save: @escaping (SpanDACPairResult) -> String?,
               events: @escaping (SpanDACPairingEvent) -> Void) -> SpanDACPairingHandle {
        begun.append(Begun(serviceName: serviceName, port: port, controllerID: controllerID, controllerName: controllerName))
        self.save = save
        self.events = events
        return handle
    }
}

final class SpanDACOutputTabTests: XCTestCase {

    private let ipad = "D2C4A6E8-1B3D-4F5A-8C7E-9A0B2C4D6E8F"
    private let other = "6B1F3C2E-8D4A-4F0B-9C7E-2A5D1E0F3B91"
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "spandac-tab-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func sighting(_ id: String, name: String, pairPort: UInt16? = nil) -> SpanDACSighting {
        var txt = ["v": "1", "contract": "3", "id": id, "name": name]
        if let pairPort { txt["pair"] = "1"; txt["pairport"] = String(pairPort) }
        return SpanDACSighting(serviceName: id, txt: SpanDACTXT(txt)!)
    }

    private func record(_ id: String, name: String) -> SpanDACPairRecord {
        SpanDACPairRecord(sourceID: id, sourceName: name, pskID: String(repeating: "ab", count: 16),
                          pairKey: Data(repeating: 1, count: 32), serviceName: id, pairedAt: Date())
    }

    private let ready = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[]}}"#

    private final class Posts {
        private let lock = NSLock()
        private var _all: [(String, Bool)] = []
        var all: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return _all }
        var texts: [String] { all.map(\.0) }
        func add(_ t: String, _ e: Bool) { lock.lock(); _all.append((t, e)); lock.unlock() }
    }

    private func outputs(pairs: SpanDACPairedStore, browser: FakeSpanDACBrowser = FakeSpanDACBrowser(),
                         driver: FakePairingDriver = FakePairingDriver(), posts: Posts = Posts(),
                         registry: SpanDACLinkRegistry = SpanDACLinkRegistry(),
                         clock: @escaping () -> Date = Date.init,
                         reply: @escaping (String) -> String? = { _ in nil }) -> SpanDACOutputs {
        SpanDACOutputs(pairs: pairs, browser: browser,
                       makeClient: { id in
                           SourceAppClient(path: "spandac:\(id)", transport: { _, _ in
                               guard let r = reply(id) else { throw SourceAppError.link(.asleep) }
                               return r
                           })
                       },
                       driver: driver, registry: registry, controllerName: "MusicTUI on Test Mac",
                       now: clock, post: { text, error, _ in posts.add(text, error) })
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(10_000) }
    }

    // MARK: - Rows

    /// Paired first, then seen-but-not-paired; each with its note. Readiness
    /// comes only from an authenticated answer, never from Bonjour.
    func testRowsMergePairsSightingsAndProbes() {
        let rows = spandacOutputRows(
            paired: [record(ipad, name: "Studio iPad")],
            seen: [sighting(other, name: "Kitchen iPad"), sighting(ipad, name: "Studio iPad")],
            probes: [:], pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(rows.map(\.name), ["Studio iPad", "Kitchen iPad"])
        XCTAssertEqual(rows.map(\.note), ["checking…", "not paired · Enter to pair"])
        XCTAssertEqual(rows.map(\.ready), [false, false], "seen on the network is never ready")

        let probed = spandacOutputRows(paired: [record(ipad, name: "Studio iPad")], seen: [],
                                       probes: [ipad: .ready], pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(probed.first?.note, "ready")
        XCTAssertEqual(probed.first?.ready, true)

        let refused = spandacOutputRows(paired: [record(ipad, name: "Studio iPad")], seen: [],
                                        probes: [ipad: .unavailable(SpanDACLinkFailure.refused(-9864).note)],
                                        pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(refused.first?.note, "SpanDAC no longer recognises this Mac; pair again")
    }

    func testThePairingAndForgetNotesFollowSection43() {
        var state = SpanDACOutputs.PairingState(sourceID: other, name: "Kitchen iPad", phase: .waitingForWindow)
        func note() -> String? {
            spandacOutputRows(paired: [], seen: [sighting(other, name: "Kitchen iPad")], probes: [:],
                              pairing: state, forgetPrompt: nil, selected: nil).first?.note
        }
        XCTAssertEqual(note(), "pairing · tap Pair with MusicTUI on the iPad")
        state.phase = .confirming
        XCTAssertEqual(note(), "pairing · tap Allow on Kitchen iPad")
        let forgetting = spandacOutputRows(paired: [record(ipad, name: "Studio iPad")], seen: [], probes: [ipad: .ready],
                                           pairing: nil, forgetPrompt: ipad, selected: nil)
        XCTAssertEqual(forgetting.first?.note, "forget? y / n")
        XCTAssertEqual(forgetting.first?.ready, false)
    }

    /// The selected SpanDAC keeps a row even when it is neither paired nor
    /// seen, so the selection never vanishes from the tab.
    func testTheSelectedSpanDACAlwaysHasARow() {
        let rows = spandacOutputRows(paired: [], seen: [], probes: [:], pairing: nil, forgetPrompt: nil, selected: ipad)
        XCTAssertEqual(rows.map(\.sourceID), [ipad])
        XCTAssertEqual(rows.first?.note, "not paired · not found on this network")
    }

    /// With nothing paired and nothing seen, the tab is exactly as before.
    func testWithNoSpanDACsTheTabRowsAreUnchanged() {
        XCTAssertEqual(speakersDisplayRows(speakerCount: 2, expanded: false, presetNames: []),
                       speakersDisplayRows(speakerCount: 2, expanded: false, presetNames: [], spandacIDs: []))
        XCTAssertEqual(speakersDisplayRows(speakerCount: 1, expanded: false, presetNames: [], spandacIDs: [ipad]),
                       [.mode(.musicApp), .mode(.source), .spandac(ipad), .speaker(0), .eqPower, .eq, .visualizer])
    }

    // MARK: - Probes

    func testOpeningTheTabAsksEachPairedSpanDACOnce() {
        let pairs = SpanDACPairedStore(path: dir + "/spandac/paired.json")
        try! pairs.save(record(ipad, name: "Studio iPad"))
        try! pairs.save(record(other, name: "Kitchen iPad"))
        let o = outputs(pairs: pairs, reply: { $0 == self.ipad ? self.ready : nil })
        o.activated()
        waitUntil { o.rows(selected: nil).allSatisfy { $0.note != "checking…" } }
        let rows = o.rows(selected: nil)
        XCTAssertEqual(rows.first { $0.sourceID == ipad }?.note, "ready")
        XCTAssertEqual(rows.first { $0.sourceID == other }?.note, "asleep or closed on the iPad · open it there")
    }

    // MARK: - Pairing as status-line prompts

    /// Enter on an unpaired SpanDAC: ask the person to open the window, wait
    /// for `pair=1`, connect to its pairing port, show the code, take y, and
    /// save the pair the session hands back.
    func testPairingWaitsForTheWindowThenAsksAndSaves() throws {
        let pairs = SpanDACPairedStore(path: dir + "/spandac/paired.json")
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver(), posts = Posts()
        let o = outputs(pairs: pairs, browser: browser, driver: driver, posts: posts, reply: { _ in self.ready })
        o.touch()
        browser.emit([sighting(other, name: "Kitchen iPad")])
        o.pair(other)
        XCTAssertEqual(posts.texts.last, "Open SpanDAC on the iPad and tap Pair with MusicTUI.")
        XCTAssertTrue(driver.begun.isEmpty, "no connection before the window is open")
        XCTAssertEqual(o.rows(selected: nil).first?.note, "pairing · tap Pair with MusicTUI on the iPad")

        browser.emit([sighting(other, name: "Kitchen iPad", pairPort: 51456)])
        XCTAssertEqual(driver.begun.count, 1)
        XCTAssertEqual(driver.begun.first?.port, 51456)
        XCTAssertEqual(driver.begun.first?.serviceName, other)
        XCTAssertEqual(driver.begun.first?.controllerName, "MusicTUI on Test Mac")
        XCTAssertEqual(driver.begun.first?.controllerID, try pairs.controllerID())

        driver.events?(.code("482 913", sourceName: "Kitchen iPad"))
        XCTAssertEqual(driver.handle.answers, [true], "MusicTUI answers its own confirmation automatically, with no prompt")
        XCTAssertFalse(o.awaitingAnswer, "nothing is asked on this Mac any more")
        driver.events?(.confirming)
        XCTAssertEqual(posts.texts.last, "Tap Allow on Kitchen iPad.")
        XCTAssertEqual(o.rows(selected: nil).first?.note, "pairing · tap Allow on Kitchen iPad")

        let result = SpanDACPairResult(sourceID: other, sourceName: "Kitchen iPad",
                                       pskID: String(repeating: "cd", count: 16), pairKey: Data(repeating: 3, count: 32))
        XCTAssertNil(driver.save?(result), "the save succeeds")
        driver.events?(.finished(.success(result)))
        XCTAssertEqual(posts.texts.last, "Paired with Kitchen iPad.")
        XCTAssertEqual(pairs.pairs().map(\.sourceID), [other])
        XCTAssertEqual(pairs.pairs().first?.serviceName, other)
        XCTAssertFalse(o.isPairing)
        waitUntil { o.rows(selected: nil).first?.note == "ready" }
        XCTAssertEqual(o.rows(selected: nil).first?.note, "ready", "a new pair is asked how it is at once")
    }

    /// The device's person taps Don't allow, or the key confirmation
    /// mismatches: MusicTUI still answered its own side automatically, but
    /// nothing is saved and the failure is said in words.
    func testARejectionOrAMismatchSavesNothingAndSaysSo() {
        let pairs = SpanDACPairedStore(path: dir + "/spandac/paired.json")
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver(), posts = Posts()
        let o = outputs(pairs: pairs, browser: browser, driver: driver, posts: posts)
        o.touch()
        browser.emit([sighting(other, name: "Kitchen iPad", pairPort: 51456)])
        o.pair(other)
        driver.events?(.code("482 913", sourceName: "Kitchen iPad"))
        XCTAssertEqual(driver.handle.answers, [true], "MusicTUI answers its own confirmation automatically")
        driver.events?(.finished(.failure(.codesDiffer)))
        XCTAssertEqual(posts.all.last?.0, "Codes differ; nothing was paired. Try again from the iPad.")
        XCTAssertEqual(posts.all.last?.1, true)
        XCTAssertEqual(pairs.pairs(), [])
    }

    func testAWindowThatNeverOpensEndsThePairingInWords() {
        var clock = Date()
        let pairs = SpanDACPairedStore(path: dir + "/spandac/paired.json")
        let browser = FakeSpanDACBrowser(), posts = Posts()
        let o = outputs(pairs: pairs, browser: browser, posts: posts, clock: { clock })
        o.touch()
        browser.emit([sighting(other, name: "Kitchen iPad")])
        o.pair(other)
        clock = clock.addingTimeInterval(121)
        XCTAssertTrue(o.tick())
        XCTAssertFalse(o.isPairing)
        waitUntil { posts.texts.last == "The iPad's pairing window did not open; nothing was paired." }
        XCTAssertEqual(posts.texts.last, "The iPad's pairing window did not open; nothing was paired.")
    }

    func testEscCancelsAPairingInProgress() {
        let pairs = SpanDACPairedStore(path: dir + "/spandac/paired.json")
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver(), posts = Posts()
        let o = outputs(pairs: pairs, browser: browser, driver: driver, posts: posts)
        o.touch()
        browser.emit([sighting(other, name: "Kitchen iPad", pairPort: 51456)])
        o.pair(other)
        XCTAssertTrue(o.cancel())
        XCTAssertTrue(driver.handle.cancelled)
    }

    // MARK: - Forget

    /// `f`, then y: this Mac's copy goes, and any connection this process has
    /// open to it is cancelled. n keeps it.
    func testForgetAsksThenDeletesAndCancelsOpenConnections() {
        let pairs = SpanDACPairedStore(path: dir + "/spandac/paired.json")
        try! pairs.save(record(ipad, name: "Studio iPad"))
        let registry = SpanDACLinkRegistry(), posts = Posts()
        var cancelled = 0
        _ = registry.register(ipad) { cancelled += 1 }
        let o = outputs(pairs: pairs, posts: posts, registry: registry)
        o.activated()
        o.askToForget(ipad)
        XCTAssertTrue(o.awaitingAnswer)
        XCTAssertEqual(posts.texts.last, "Forget Studio iPad? y / n")
        o.answer(false)
        XCTAssertEqual(pairs.pairs().count, 1)
        XCTAssertEqual(cancelled, 0)

        o.askToForget(ipad)
        o.answer(true)
        XCTAssertEqual(pairs.pairs(), [])
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(posts.texts.last, "Forgot Studio iPad. Remove this Mac on the iPad too.")
    }

    // MARK: - Discovery runs only while it is wanted

    func testTheBrowserStopsWhenTheTabIsNoLongerTouched() {
        let browser = FakeSpanDACBrowser()
        let o = outputs(pairs: SpanDACPairedStore(path: dir + "/spandac/paired.json"), browser: browser)
        o.touch()
        o.touch()
        XCTAssertEqual(browser.starts, 1)
        XCTAssertTrue(browser.running)
        waitUntil(5) { !browser.running }
        XCTAssertFalse(browser.running, "the browser must stop once the Output tab stops touching it")
        o.touch()
        XCTAssertEqual(browser.starts, 2)
    }

    // MARK: - The Output tab scene

    private func scene(mode: PlaybackMode, outputs: SpanDACOutputs, status: StatusStore = StatusStore(),
                       network: @escaping (String) -> SourceAppClient) -> SpeakersScene {
        let store = PlaybackModeStore(path: dir + "/mode.json")
        store.set(mode)
        let local = { SourceAppClient(path: "/nonexistent", transport: { _, _ in self.ready }) }
        let routing = RoutingCoordinator(store: store, surface: .tui, makeSourceFor: { m in
            m.networkSourceID.map(network) ?? local()
        })
        return SpeakersScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                             status: status, actions: ActionRunner(status: status), routing: routing,
                             makeSourceClient: local, makeNetworkClient: network, spandac: outputs,
                             fetchSpeakers: { [] },
                             fetchEQ: { _ in EQSnapshot(enabled: false, current: nil, presets: []) },
                             fetchVisualizer: { _ in false })
    }

    private func frame() -> ShellFrame {
        shellLayout(width: 100, height: 30)
    }

    private func snapshot() -> NowPlayingSnapshot { NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []) }

    /// A paired, ready SpanDAC is listed under its heading, and Enter on it
    /// switches the Output to it (from the Mac's own SpanDAC, so the outgoing
    /// pause goes through a stub and never reaches Music.app).
    func testTheTabListsASpanDACAndEnterSelectsIt() throws {
        let pairs = SpanDACPairedStore(path: dir + "/spandac/paired.json")
        try pairs.save(record(ipad, name: "Studio iPad"))
        let status = StatusStore()
        let o = outputs(pairs: pairs, reply: { _ in self.ready })
        let s = scene(mode: .source, outputs: o, status: status,
                      network: { _ in SourceAppClient(path: "/fake", transport: { _, _ in self.ready }) })
        _ = s.tick(snapshot: snapshot())
        waitUntil { o.rows(selected: nil).first?.note == "ready" }
        _ = s.tick(snapshot: snapshot())
        let text = s.render(frame: frame(), snapshot: snapshot())
        XCTAssertTrue(text.contains("SpanDAC on the network"), text)
        XCTAssertTrue(text.contains("Studio iPad"), text)

        _ = s.handle(.down); _ = s.handle(.down)   // Music.app, Bridge, then the iPad
        let done = DispatchSemaphore(value: 0)
        s.selectModeFinishedForTest = { done.signal() }
        _ = s.handle(.enter)
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(PlaybackModeStore(path: dir + "/mode.json").mode(), .networkSource(ipad))
        XCTAssertEqual(status.current()?.text, "Output: SpanDAC · Studio iPad")
    }

    /// Enter on a SpanDAC that is seen but not paired starts pairing; it never
    /// switches the Output.
    func testEnterOnAnUnpairedSpanDACPairsAndDoesNotSwitch() {
        let pairs = SpanDACPairedStore(path: dir + "/spandac/paired.json")
        let browser = FakeSpanDACBrowser(), status = StatusStore()
        let o = outputs(pairs: pairs, browser: browser)
        let s = scene(mode: .source, outputs: o, status: status, network: { _ in .failing(.notPaired) })
        _ = s.tick(snapshot: snapshot())
        browser.emit([sighting(other, name: "Kitchen iPad")])
        _ = s.tick(snapshot: snapshot())
        _ = s.handle(.down); _ = s.handle(.down)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(o.isPairing)
        XCTAssertEqual(PlaybackModeStore(path: dir + "/mode.json").mode(), .source)
        XCTAssertEqual(s.footerHint, "Esc Cancel pairing")
    }
}
