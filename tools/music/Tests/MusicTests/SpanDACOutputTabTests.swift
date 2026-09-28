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
        XCTAssertEqual(note(), "pairing · tap Pair with MusicTUI on Kitchen iPad")
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
        XCTAssertEqual(rows.first { $0.sourceID == other }?.note, "asleep or closed · open SpanDAC on the device")
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
        XCTAssertEqual(posts.texts.last, "Open SpanDAC on Kitchen iPad and tap Pair with MusicTUI.")
        XCTAssertTrue(driver.begun.isEmpty, "no connection before the window is open")
        XCTAssertEqual(o.rows(selected: nil).first?.note, "pairing · tap Pair with MusicTUI on Kitchen iPad")

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
        XCTAssertEqual(posts.all.last?.0, "Codes differ; nothing was paired. Try again from SpanDAC.")
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
        waitUntil { posts.texts.last == "SpanDAC on Kitchen iPad did not open pairing; nothing was paired." }
        XCTAssertEqual(posts.texts.last, "SpanDAC on Kitchen iPad did not open pairing; nothing was paired.")
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
        XCTAssertEqual(posts.texts.last, "Forgot Studio iPad. Remove this Mac in SpanDAC on Studio iPad too.")
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

    // The scene's side of the SPANDAC section. Row states are set directly on
    // a fake (`FakeSpanDACOutputs`), the way discovery and pairing fill them;
    // pair-then-play is driven by calling `onPairedAndReady` directly. Every
    // switch here starts from a SpanDAC, so the outgoing pause goes through a
    // stub and never reaches Music.app.

    private final class Finished {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func bump() { lock.lock(); _count += 1; lock.unlock() }
    }

    private func watch(_ s: SpeakersScene) -> Finished {
        let finished = Finished()
        s.selectModeFinishedForTest = { finished.bump() }
        return finished
    }

    private func waitFor(_ finished: Finished, count: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while finished.count < count && Date() < deadline { usleep(10_000) }
        return finished.count >= count
    }

    private func scene(mode: PlaybackMode, outputs: SpanDACOutputsDriving?, status: StatusStore = StatusStore(),
                       speakers: [[String: Any]] = [],
                       macReply: @escaping () throws -> String = { outputTabReadyReply },
                       network: @escaping (String) -> SourceAppClient = { _ in
                           SourceAppClient(path: "/fake", transport: { _, _ in outputTabReadyReply })
                       },
                       clock: @escaping () -> Date = Date.init) -> SpeakersScene {
        let s = makeOutputTabScene(dir: dir, mode: mode, spandac: outputs, speakers: speakers, status: status,
                                   macReply: macReply, network: network, clock: clock)
        settleOutputTab(s, speakers: speakers.count)
        return s
    }

    private func put(_ s: SpeakersScene, at index: Int) {
        _ = s.handle(.home)
        for _ in 0..<index { _ = s.handle(.down) }
    }

    private func screen(_ s: SpeakersScene, width: Int = 100) -> [String] {
        screenText(s.render(frame: shellLayout(width: width, height: 30), snapshot: outputTabSnapshot()),
                   width: width, height: 30)
    }

    private func modeOnDisk() -> PlaybackMode { PlaybackModeStore(path: dir + "/mode.json").mode() }
    private func modeBytes() -> Data? { FileManager.default.contents(atPath: dir + "/mode.json") }

    private let unknownDAC = SourceOutputInfo(dac: .unknown, name: nil, maxRateHz: nil)
    private let ssl = SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192_000)

    func testSpanDACSectionComesFirstWithTheMacAsRowOne() {
        let fake = FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .ready)])
        let s = scene(mode: .source, outputs: fake, speakers: [["name": "Kitchen", "selected": true, "volume": 50]])
        let lines = screen(s)
        func line(_ needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        guard let header = line("SPANDAC"), let mac = line("1  Studio Mac"), let pad = line("2  Studio iPad"),
              let music = line("MUSIC.APP"), let kitchen = line("Kitchen") else {
            return XCTFail(lines.joined(separator: "\n"))
        }
        XCTAssertLessThan(header, mac)
        XCTAssertLessThan(mac, pad)
        XCTAssertLessThan(pad, music)
        XCTAssertLessThan(music, kitchen)
        XCTAssertTrue(lines[header].contains("lossless to your DAC \u{00B7} pick one and it plays there"))
        XCTAssertEqual(outputTabRows(speakerCount: 1, expanded: false, presetNames: [], spandacIDs: [ipad]).first,
                       .spandacMac)
        // The cursor starts on row 1, this Mac.
        XCTAssertEqual(s.footerHint, "\u{2191}\u{2193} Move   Enter Play here   e EQ   v Visualizer")
    }

    func testNetworkRowsAreKeyedBySourceIDNotName() {
        let fake = FakeSpanDACOutputs([spandacRow(ipad, "iPad", .ready), spandacRow(other, "iPad", .ready)])
        let s = scene(mode: .source, outputs: fake)
        XCTAssertEqual(screen(s).filter { $0.contains("  iPad ") }.count, 2, "same-name devices are never merged")

        // The cursor is on the second iPad; the rows swap; Enter still means
        // that one, by sourceID.
        put(s, at: 2)
        fake.set([spandacRow(other, "iPad", .ready), spandacRow(ipad, "iPad", .ready)])
        _ = s.tick(snapshot: outputTabSnapshot())
        let finished = watch(s)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(waitFor(finished, count: 1))
        XCTAssertEqual(modeOnDisk(), .networkSource(other))
    }

    func testNumberKeysAreNotConsumedByTheOutputTab() {
        let fake = FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .ready),
                                       spandacRow(other, "Kitchen iPad", .notPaired(pairable: true), paired: false)])
        let s = scene(mode: .source, outputs: fake)
        let before = modeBytes()
        let finished = watch(s)
        for n in 1...9 {
            XCTAssertEqual(resolveGlobalKey(.char(Character(String(n)))), .switchScene(n),
                           "number keys stay tab switching; the row numbers are labels")
            XCTAssertEqual(s.handle(.char(Character(String(n)))), .none)
        }
        usleep(300_000)
        XCTAssertEqual(finished.count, 0)
        XCTAssertEqual(fake.pairCalls, [])
        XCTAssertEqual(modeBytes(), before)
    }

    func testEnterOnAReadyRowSwitchesInOneAction() {
        let status = StatusStore()
        let fake = FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .ready)])
        let s = scene(mode: .source, outputs: fake, status: status)
        put(s, at: 1)
        let finished = watch(s)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(waitFor(finished, count: 1))
        XCTAssertEqual(modeOnDisk(), .networkSource(ipad))
        XCTAssertEqual(status.current()?.text, "Output: SpanDAC \u{00B7} Studio iPad")
        usleep(200_000)
        XCTAssertEqual(finished.count, 1, "one Enter, one switch: no separate mode row to choose first")
        XCTAssertEqual(fake.pairCalls, [])

        // Row 1, this Mac, the same way.
        put(s, at: 0)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(waitFor(finished, count: 2))
        XCTAssertEqual(modeOnDisk(), .source)
    }

    func testEnterOnANotReadyRowDoesNothing() {
        let status = StatusStore()
        let fake = FakeSpanDACOutputs()
        let s = scene(mode: .source, outputs: fake, status: status)
        let finished = watch(s)
        let states: [SpanDACRowState] = [
            .checking, .notReady("plug in your DAC"), .unreachable("asleep"), .connecting,
            .notPaired(pairable: false),
            .waitingForAllow(deadline: Date().addingTimeInterval(100)), .forgetPrompt,
        ]
        let before = modeBytes()
        for state in states {
            fake.set([spandacRow(ipad, "Studio iPad", state)])
            _ = s.tick(snapshot: outputTabSnapshot())
            put(s, at: 1)
            XCTAssertEqual(s.handle(.enter), .none, "\(state)")
        }
        usleep(300_000)
        XCTAssertEqual(finished.count, 0, "no switch was attempted")
        XCTAssertEqual(fake.pairCalls, [])
        XCTAssertEqual(modeBytes(), before, "mode.json unchanged")
        XCTAssertNil(status.current(), "no toast: the reason is on the row")

        // Row 1 when this Mac's SpanDAC is not running.
        let fake2 = FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .ready)])
        let s2 = scene(mode: .networkSource(ipad), outputs: fake2,
                       macReply: { throw SourceAppError.notRunning })
        let finished2 = watch(s2)
        let before2 = modeBytes()
        put(s2, at: 0)
        XCTAssertEqual(s2.handle(.enter), .none)
        usleep(300_000)
        XCTAssertEqual(finished2.count, 0)
        XCTAssertEqual(modeBytes(), before2)
    }

    func testAnUnknownDACRefusesEnterAndTheSwitch() throws {
        // A network row whose status said the DAC is unknown.
        let fake = FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .checking, output: unknownDAC)])
        let s = scene(mode: .source, outputs: fake)
        let finished = watch(s)
        let before = modeBytes()
        put(s, at: 1)
        XCTAssertEqual(s.handle(.enter), .none)
        XCTAssertTrue(screen(s).contains { $0.contains("Studio iPad") && $0.contains("checking the DAC") })

        // Row 1: this Mac's status says the DAC is unknown.
        fake.set([spandacRow(other, "Kitchen iPad", .ready)])
        _ = s.tick(snapshot: outputTabSnapshot())
        put(s, at: 1)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(waitFor(finished, count: 1))
        XCTAssertEqual(modeOnDisk(), .networkSource(other))
        let onKitchen = modeBytes()
        s.deliverMacStatusForTest(readiness: .ready, output: unknownDAC)
        _ = s.tick(snapshot: outputTabSnapshot())
        put(s, at: 0)
        XCTAssertEqual(s.handle(.enter), .none)
        XCTAssertTrue(screen(s).contains { $0.contains("Studio Mac") && $0.contains("checking the DAC") })
        usleep(300_000)
        XCTAssertEqual(finished.count, 1, "the unknown DAC was never switched to")
        XCTAssertEqual(modeBytes(), onKitchen)
        XCTAssertNotEqual(before, onKitchen)

        // The switch itself refuses that readiness, for either kind of SpanDAC.
        let routing = RoutingCoordinator(store: PlaybackModeStore(path: dir + "/mode.json"), surface: .tui,
                                         makeSourceFor: { _ in .failing(.notPaired) })
        for target in [PlaybackMode.source, .networkSource(ipad)] {
            XCTAssertThrowsError(try routing.switchMode(
                to: target,
                readiness: { .unavailable("SpanDAC is still checking for a DAC") },
                pauseOutgoing: { _ in XCTFail("nothing may be paused"); return false },
                dropQueue: { _ in XCTFail("nothing may be dropped") }))
        }
        XCTAssertEqual(modeBytes(), onKitchen, "mode.json unchanged")
    }

    func testEnterOnAPairableRowPairsAndSwitchesOnlyAfterPairedAndReady() {
        let status = StatusStore()
        let fake = FakeSpanDACOutputs([spandacRow(other, "Kitchen iPad", .notPaired(pairable: true), paired: false)])
        let s = scene(mode: .source, outputs: fake, status: status)
        let finished = watch(s)
        put(s, at: 1)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertEqual(fake.pairCalls, [other])
        usleep(300_000)
        XCTAssertEqual(finished.count, 0, "pairing alone never switches")
        XCTAssertEqual(modeOnDisk(), .source)

        fake.onPairedAndReady?(other, "Kitchen iPad")
        XCTAssertTrue(waitFor(finished, count: 1))
        XCTAssertEqual(modeOnDisk(), .networkSource(other), "exactly that sourceID")
        XCTAssertEqual(status.current()?.text, "Output: SpanDAC \u{00B7} Kitchen iPad")

        // A forgotten or broken pair pairs again the same way, and a device
        // that just refused gets one more try per Enter (pairing itself
        // decides whether the device still invites it).
        for state in [SpanDACRowState.forgotten, .needsRepair("pairing broken"),
                      .notPairableNow("busy"), .notPairableNow("too_many"), .notPairableNow("closed")] {
            fake.set([spandacRow(ipad, "Studio iPad", state)])
            _ = s.tick(snapshot: outputTabSnapshot())
            put(s, at: 1)
            XCTAssertEqual(s.handle(.enter), .redraw, "\(state)")
        }
        XCTAssertEqual(fake.pairCalls, [other] + Array(repeating: ipad, count: 5))
    }

    func testPairedAndReadyDoesNotSwitchIfTheOutputChangedMeanwhile() {
        let status = StatusStore()
        let fake = FakeSpanDACOutputs([spandacRow(other, "Kitchen iPad", .notPaired(pairable: true), paired: false),
                                       spandacRow(ipad, "Studio iPad", .ready)])
        let s = scene(mode: .source, outputs: fake, status: status)
        let finished = watch(s)
        put(s, at: 1)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertEqual(fake.pairCalls, [other])

        // Meanwhile the person picks another SpanDAC.
        put(s, at: 2)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(waitFor(finished, count: 1))
        XCTAssertEqual(modeOnDisk(), .networkSource(ipad))

        fake.onPairedAndReady?(other, "Kitchen iPad")
        XCTAssertTrue(waitFor(finished, count: 2))
        XCTAssertEqual(modeOnDisk(), .networkSource(ipad), "the later choice stands")
        XCTAssertEqual(status.current()?.text, "Paired with Kitchen iPad. Press Enter to play there.")

        // A pair this tab did not start never switches either.
        fake.onPairedAndReady?(other, "Kitchen iPad")
        usleep(200_000)
        XCTAssertEqual(modeOnDisk(), .networkSource(ipad))
        XCTAssertEqual(status.current()?.text, "Paired with Kitchen iPad. Press Enter to play there.")
    }

    func testEnterOnASpeakerWhileSpanDACIsSelectedSwitchesToMusicAppOnly() {
        let status = StatusStore()
        let s = scene(mode: .source, outputs: FakeSpanDACOutputs(), status: status,
                      speakers: [["name": "Kitchen", "selected": false, "volume": 40]])
        XCTAssertTrue(screen(s).contains { $0.contains("MUSIC.APP") && $0.contains("Enter on a speaker switches back") })
        let finished = watch(s)
        put(s, at: 1)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(waitFor(finished, count: 1))
        XCTAssertEqual(modeOnDisk(), .musicApp)
        XCTAssertEqual(status.current()?.text, "Output: Music.app")
        XCTAssertEqual(s.speakerRowsForTest.map(\.active), [false], "the speaker was not toggled too")
    }

    func testEnterOnASpeakerInMusicAppTogglesItAsBefore() {
        let s = scene(mode: .musicApp, outputs: FakeSpanDACOutputs(),
                      speakers: [["name": "Kitchen", "selected": false, "volume": 40]])
        XCTAssertFalse(screen(s).contains { $0.contains("switches back") })
        let finished = watch(s)
        let before = modeBytes()
        put(s, at: 1)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertEqual(s.speakerRowsForTest.map(\.active), [true])
        usleep(300_000)
        XCTAssertEqual(finished.count, 0, "a speaker toggle is not a switch")
        XCTAssertEqual(modeBytes(), before)
    }

    func testMusicAppIsReachableWithNoSpeakers() {
        let s = scene(mode: .source, outputs: FakeSpanDACOutputs())
        XCTAssertEqual(outputTabRows(speakerCount: 0, expanded: false, presetNames: []),
                       [.spandacMac, .musicApp, .eqPower, .eq, .visualizer])
        XCTAssertTrue(screen(s).contains { $0.contains("Music.app") && $0.contains("this Mac") })
        let finished = watch(s)
        put(s, at: 1)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(waitFor(finished, count: 1))
        XCTAssertEqual(modeOnDisk(), .musicApp)
    }

    func testTheOldModeRowsAndPairHintAreGone() {
        let fake = FakeSpanDACOutputs([spandacRow(other, "Kitchen iPad", .notPaired(pairable: true), paired: false)])
        let s = scene(mode: .source, outputs: fake, speakers: [["name": "Kitchen", "selected": true, "volume": 50]])
        for width in [100, 60] {
            let text = screen(s, width: width).joined(separator: "\n")
            XCTAssertFalse(text.contains("SpanDAC (this Mac)"), text)
            XCTAssertFalse(text.contains("Select a SpanDAC and press Enter to pair"), text)
            XCTAssertFalse(text.contains("AirPlay Outputs"), text)
            XCTAssertFalse(text.contains("tap Pair"), text)
        }
        let rows = outputTabRows(speakerCount: 1, expanded: false, presetNames: [], spandacIDs: [other])
        XCTAssertEqual(rows.prefix(3), [.spandacMac, .spandac(other), .speaker(0)])
    }

    func testTopLineNamesTheActiveSpeakersOrTheSpanDACPath() {
        let speakers: [[String: Any]] = [
            ["name": "Kitchen", "selected": true, "volume": 50],
            ["name": "Office", "selected": false, "volume": 50],
            ["name": "Living Room", "selected": true, "volume": 50],
        ]
        let music = scene(mode: .musicApp, outputs: FakeSpanDACOutputs(), speakers: speakers)
        XCTAssertEqual(screen(music).first { !$0.isEmpty }?.trimmingCharacters(in: .whitespaces),
                       "Playing through  Music.app \u{2192} Kitchen, Living Room")

        let fake = FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .ready, output: ssl)])
        let network = scene(mode: .networkSource(ipad), outputs: fake)
        XCTAssertEqual(screen(network).first { !$0.isEmpty }?.trimmingCharacters(in: .whitespaces),
                       "Playing through  SpanDAC \u{2192} Studio iPad \u{2192} SSL 2+ \u{00B7} 192 kHz")

        // No rate known: that part is left out.
        fake.set([spandacRow(ipad, "Studio iPad", .ready,
                             output: SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: nil))])
        _ = network.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(screen(network).first { !$0.isEmpty }?.trimmingCharacters(in: .whitespaces),
                       "Playing through  SpanDAC \u{2192} Studio iPad \u{2192} SSL 2+")

        // Not ready: the line says why, and the output stays where it is.
        fake.set([spandacRow(ipad, "Studio iPad", .notReady("plug in your DAC"),
                             output: SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil))])
        _ = network.tick(snapshot: outputTabSnapshot())
        let top = screen(network).first { !$0.isEmpty } ?? ""
        XCTAssertTrue(top.contains("SpanDAC \u{2192} Studio iPad"), top)
        XCTAssertTrue(top.contains("not ready  plug in your DAC"), top)
        XCTAssertEqual(modeOnDisk(), .networkSource(ipad))

        // This Mac's SpanDAC, from its own status.
        let mac = scene(mode: .source, outputs: FakeSpanDACOutputs())
        mac.deliverMacStatusForTest(readiness: .ready, output: ssl)
        _ = mac.tick(snapshot: outputTabSnapshot())
        XCTAssertEqual(screen(mac).first { !$0.isEmpty }?.trimmingCharacters(in: .whitespaces),
                       "Playing through  SpanDAC \u{2192} Studio Mac \u{2192} SSL 2+ \u{00B7} 192 kHz")
    }

    func testNoFallbackWhenTheSelectedSpanDACBecomesUnavailable() {
        let fake = FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .ready)])
        let s = scene(mode: .networkSource(ipad), outputs: fake)
        let finished = watch(s)
        let before = modeBytes()
        fake.set([spandacRow(ipad, "Studio iPad", .unreachable("asleep"))])
        for _ in 0..<20 { _ = s.tick(snapshot: outputTabSnapshot()); usleep(20_000) }
        XCTAssertTrue((screen(s).first { !$0.isEmpty } ?? "").contains("not seen"))
        XCTAssertEqual(finished.count, 0, "nothing switched on its own")
        XCTAssertEqual(modeBytes(), before)

        // This Mac's SpanDAC stops answering while selected: the same.
        var clock = Date()
        let lock = NSLock()
        var running = true
        let mac = scene(mode: .source, outputs: FakeSpanDACOutputs(),
                        macReply: {
                            lock.lock(); defer { lock.unlock() }
                            if running { return outputTabReadyReply }
                            throw SourceAppError.notRunning
                        },
                        clock: { clock })
        XCTAssertEqual(mac.bridgeReadinessForTest, .ready)
        let macFinished = watch(mac)
        let macBefore = modeBytes()
        lock.lock(); running = false; lock.unlock()
        clock = clock.addingTimeInterval(SpeakersScene.macReprobeInterval)
        let deadline = Date().addingTimeInterval(3)
        while mac.bridgeReadinessForTest == .ready && Date() < deadline {
            _ = mac.tick(snapshot: outputTabSnapshot()); usleep(10_000)
        }
        XCTAssertEqual(mac.bridgeReadinessForTest, .notRunning)
        XCTAssertEqual(macFinished.count, 0)
        XCTAssertEqual(modeBytes(), macBefore)
        XCTAssertEqual(modeOnDisk(), .source)
    }

    func testFooterFollowsTheRowUnderTheCursor() {
        let fake = FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .ready),
                                       spandacRow(other, "Kitchen iPad", .notPaired(pairable: true), paired: false)])
        let s = scene(mode: .source, outputs: fake, speakers: [["name": "Kitchen", "selected": true, "volume": 50]])
        let move = "\u{2191}\u{2193} Move", always = "e EQ   v Visualizer"
        put(s, at: 0)
        XCTAssertEqual(s.footerHint, "\(move)   Enter Play here   \(always)")
        put(s, at: 1)
        XCTAssertEqual(s.footerHint, "\(move)   Enter Play here   f Forget   \(always)", "f only when paired")
        put(s, at: 2)
        XCTAssertEqual(s.footerHint, "\(move)   Enter Play here   \(always)")
        put(s, at: 3)
        XCTAssertEqual(s.footerHint, "\(move)   Enter Use Music.app   \u{2190}\u{2192} Volume   \(always)")
        fake.isPairing = true
        XCTAssertEqual(s.footerHint, "Esc Cancel pairing")
        fake.isPairing = false
        fake.awaitingAnswer = true
        XCTAssertEqual(s.footerHint, "y Yes  n No  Esc Cancel")

        let music = scene(mode: .musicApp, outputs: FakeSpanDACOutputs(),
                          speakers: [["name": "Kitchen", "selected": true, "volume": 50]])
        put(music, at: 1)
        XCTAssertEqual(music.footerHint, "\(move)   Enter Toggle   \u{2190}\u{2192} Volume   \(always)")
    }
}
