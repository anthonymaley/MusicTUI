// tools/music/Tests/MusicTests/SpanDACOutputTabTests.swift
//
// SpanDACs on the network in the Output tab: the rows, their state and notes,
// pairing at once when the device advertises it, the forgotten and broken
// states (the pair is never deleted by a TLS alert), the re-probe while the
// tab is shown, forgetting, and a real pairing session over loopback TCP
// against a source written in the tests. No Bonjour, no real SpanDAC, no
// ~/.config/music, no Music.app. Clocks are injected; nothing sleeps for a
// re-probe interval.
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

/// A clock a test moves by hand.
final class TestClock {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(_ seconds: TimeInterval) { lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock() }
}

/// Counts status requests per SpanDAC, and how many run at once.
final class ProbeLog {
    private let lock = NSLock()
    private var _calls: [String: Int] = [:]
    private var running = 0
    private(set) var maxRunning = 0
    func calls(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return _calls[id] ?? 0 }
    func begin(_ id: String) { lock.lock(); _calls[id, default: 0] += 1; running += 1; maxRunning = max(maxRunning, running); lock.unlock() }
    func end() { lock.lock(); running -= 1; lock.unlock() }
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
    private let readyWithDAC = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[],"output":{"dac":"connected","name":"SSL 2+","max_rate_hz":192000}}}"#
    private let noDAC = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[],"output":{"dac":"not_connected"}}}"#

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
        outputsAnswering(pairs: pairs, browser: browser, driver: driver, posts: posts, registry: registry,
                         clock: clock, answer: { id in
                             guard let r = reply(id) else { throw SourceAppError.link(.asleep) }
                             return r
                         })
    }

    /// As `outputs`, with a status answer that may throw any error.
    private func outputsAnswering(pairs: SpanDACPairedStore, browser: FakeSpanDACBrowser = FakeSpanDACBrowser(),
                                  driver: FakePairingDriver = FakePairingDriver(), posts: Posts = Posts(),
                                  registry: SpanDACLinkRegistry = SpanDACLinkRegistry(),
                                  clock: @escaping () -> Date = Date.init,
                                  answer: @escaping (String) throws -> String) -> SpanDACOutputs {
        SpanDACOutputs(pairs: pairs, browser: browser,
                       makeClient: { id in
                           SourceAppClient(path: "spandac:\(id)", transport: { _, _ in try answer(id) })
                       },
                       driver: driver, registry: registry, controllerName: "MusicTUI on Test Mac",
                       now: clock, post: { text, error, _ in posts.add(text, error) })
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(10_000) }
    }

    private func store() -> SpanDACPairedStore { SpanDACPairedStore(path: dir + "/spandac/paired.json") }

    private func pairResult(_ id: String, name: String, key: UInt8 = 3) -> SpanDACPairResult {
        SpanDACPairResult(sourceID: id, sourceName: name, pskID: String(repeating: "cd", count: 16),
                          pairKey: Data(repeating: key, count: 32))
    }

    private func row(_ o: SpanDACOutputs, _ id: String) -> SpanDACOutputRow? {
        o.rows(selected: nil).first { $0.sourceID == id }
    }

    // MARK: - Rows

    /// Paired first, then seen-but-not-paired; each with its note and state.
    /// Readiness comes only from an authenticated answer, never from Bonjour.
    func testRowsMergePairsSightingsAndProbes() {
        let rows = spandacOutputRows(
            paired: [record(ipad, name: "Studio iPad")],
            seen: [sighting(other, name: "Kitchen iPad"), sighting(ipad, name: "Studio iPad")],
            probes: [:], pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(rows.map(\.name), ["Studio iPad", "Kitchen iPad"])
        XCTAssertEqual(rows.map(\.note), ["checking…", "not paired · open SpanDAC on it to pair"])
        XCTAssertEqual(rows.map(\.state), [.checking, .notPaired(pairable: false)])
        XCTAssertEqual(rows.map(\.ready), [false, false], "seen on the network is never ready")

        let pairable = spandacOutputRows(paired: [], seen: [sighting(other, name: "Kitchen iPad", pairPort: 51456)],
                                         probes: [:], pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(pairable.first?.state, .notPaired(pairable: true))
        XCTAssertEqual(pairable.first?.note, "not paired · Enter to pair")

        let dac = SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192000)
        let probed = spandacOutputRows(paired: [record(ipad, name: "Studio iPad")], seen: [],
                                       probes: [ipad: .ready], outputs: [ipad: dac],
                                       pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(probed.first?.note, "ready")
        XCTAssertEqual(probed.first?.state, .ready)
        XCTAssertEqual(probed.first?.ready, true)
        XCTAssertEqual(probed.first?.output, dac)

        let notReady = spandacOutputRows(paired: [record(ipad, name: "Studio iPad")], seen: [],
                                         probes: [ipad: .unavailable("plug in your DAC")],
                                         outputs: [ipad: SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil)],
                                         pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(notReady.first?.state, .notReady("plug in your DAC"))
        XCTAssertEqual(notReady.first?.ready, false)

        let asleep = spandacOutputRows(paired: [record(ipad, name: "Studio iPad")], seen: [],
                                       probes: [ipad: .unreachable(SpanDACLinkFailure.asleep.note)],
                                       pairing: nil, forgetPrompt: nil, selected: nil)
        XCTAssertEqual(asleep.first?.state, .unreachable("asleep or closed · open SpanDAC on the device"))
    }

    /// `ready` is exactly `state == .ready`, for every state a row can take.
    func testReadyIsExactlyTheReadyState() {
        let probes: [SpanDACOutputs.Probe] = [.checking, .ready, .unavailable("x"), .unreachable("y"),
                                              .forgotten, .needsRepair("pairing broken  Enter to pair again")]
        for probe in probes {
            let row = spandacOutputRows(paired: [record(ipad, name: "Studio iPad")], seen: [], probes: [ipad: probe],
                                        pairing: nil, forgetPrompt: nil, selected: nil).first!
            XCTAssertEqual(row.ready, row.state == .ready, "\(probe)")
        }
    }

    func testThePairingAndForgetNotesAndStates() {
        let deadline = Date(timeIntervalSinceReferenceDate: 800_000_120)
        var state = SpanDACOutputs.PairingState(sourceID: other, name: "Kitchen iPad", phase: .connecting)
        func first() -> SpanDACOutputRow? {
            spandacOutputRows(paired: [], seen: [sighting(other, name: "Kitchen iPad", pairPort: 51456)], probes: [:],
                              pairing: state, forgetPrompt: nil, selected: nil).first
        }
        XCTAssertEqual(first()?.note, "pairing…")
        XCTAssertEqual(first()?.state, .connecting)
        state.phase = .confirming(deadline: deadline)
        XCTAssertEqual(first()?.note, "pairing · tap Allow on Kitchen iPad")
        XCTAssertEqual(first()?.state, .waitingForAllow(deadline: deadline))
        let forgetting = spandacOutputRows(paired: [record(ipad, name: "Studio iPad")], seen: [], probes: [ipad: .ready],
                                           pairing: nil, forgetPrompt: ipad, selected: nil)
        XCTAssertEqual(forgetting.first?.note, "forget? y / n")
        XCTAssertEqual(forgetting.first?.state, .forgetPrompt)
        XCTAssertEqual(forgetting.first?.ready, false)
    }

    /// The selected SpanDAC keeps a row even when it is neither paired nor
    /// seen, so the selection never vanishes from the tab.
    func testTheSelectedSpanDACAlwaysHasARow() {
        let rows = spandacOutputRows(paired: [], seen: [], probes: [:], pairing: nil, forgetPrompt: nil, selected: ipad)
        XCTAssertEqual(rows.map(\.sourceID), [ipad])
        XCTAssertEqual(rows.first?.note, "not paired · not found on this network")
        XCTAssertEqual(rows.first?.state, .unreachable("not found on this network"))
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
        let pairs = store()
        try! pairs.save(record(ipad, name: "Studio iPad"))
        try! pairs.save(record(other, name: "Kitchen iPad"))
        let o = outputs(pairs: pairs, reply: { $0 == self.ipad ? self.readyWithDAC : nil })
        o.activated()
        waitUntil { o.rows(selected: nil).allSatisfy { $0.note != "checking…" } }
        XCTAssertEqual(row(o, ipad)?.note, "ready")
        XCTAssertEqual(row(o, ipad)?.output, SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192000))
        XCTAssertEqual(row(o, other)?.note, "asleep or closed · open SpanDAC on the device")
        XCTAssertEqual(row(o, other)?.state, .unreachable("asleep or closed · open SpanDAC on the device"))
    }

    /// A SpanDAC that answers with no DAC on its cable is not ready, with the
    /// reason on the row.
    func testANoDACAnswerIsNotReadyOnTheRow() {
        let pairs = store()
        try! pairs.save(record(ipad, name: "Studio iPad"))
        let o = outputs(pairs: pairs, reply: { _ in self.noDAC })
        o.activated()
        waitUntil { self.row(o, self.ipad)?.state != .checking }
        XCTAssertEqual(row(o, ipad)?.state, .notReady("plug in your DAC"))
        XCTAssertEqual(row(o, ipad)?.output?.dac, .notConnected)
    }

    /// C-FORGOT: a TLS -9864 on a probe means the SpanDAC no longer knows this
    /// Mac. The row says so, and the local pair stays exactly as it was: a TLS
    /// alert is not authenticated, so it never deletes anything.
    func testUnknownIdentityShowsForgottenAndKeepsThePair() throws {
        let pairs = store()
        try pairs.save(record(ipad, name: "Studio iPad"))
        let path = dir + "/spandac/paired.json"
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let o = outputsAnswering(pairs: pairs, answer: { _ in throw SourceAppError.link(.refused(-9864)) })
        o.activated()
        waitUntil { self.row(o, self.ipad)?.state == .forgotten }
        XCTAssertEqual(row(o, ipad)?.state, .forgotten)
        XCTAssertEqual(row(o, ipad)?.note, "forgot this Mac  Enter to pair again")
        XCTAssertEqual(row(o, ipad)?.paired, true)
        XCTAssertEqual(row(o, ipad)?.ready, false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "paired.json is byte-identical")
    }

    func testSecretMismatchShowsNeedsRepair() throws {
        for status: OSStatus in [-9820, -9846] {
            let pairs = SpanDACPairedStore(path: dir + "/spandac-\(-status)/paired.json")
            try pairs.save(record(ipad, name: "Studio iPad"))
            let o = outputsAnswering(pairs: pairs, answer: { _ in throw SourceAppError.link(.refused(status)) })
            o.activated()
            waitUntil { self.row(o, self.ipad)?.state != .checking }
            XCTAssertEqual(row(o, ipad)?.state, .needsRepair("pairing broken  Enter to pair again"), "\(status)")
            XCTAssertEqual(row(o, ipad)?.note, "pairing broken  Enter to pair again")
            XCTAssertEqual(pairs.pairs().map(\.sourceID), [ipad], "the pair is kept")
        }
    }

    /// A reply that never comes (or a close mid-request) stays "did not
    /// answer": it is not read as forgotten.
    func testNoAnswerIsNotForgotten() {
        let pairs = store()
        try! pairs.save(record(ipad, name: "Studio iPad"))
        let o = outputsAnswering(pairs: pairs, answer: { _ in throw SourceAppError.link(.noAnswer) })
        o.activated()
        waitUntil { self.row(o, self.ipad)?.state != .checking }
        XCTAssertEqual(row(o, ipad)?.state, .unreachable("did not answer in time"))
    }

    /// While the tab is shown (the scene touches every tick), each paired
    /// SpanDAC is asked again once its last answer is 5 s old. With no touch,
    /// no probe, however much time passes.
    func testPairedSpanDACsReprobeWhileTouchedAndStopWhenNot() {
        let pairs = store()
        try! pairs.save(record(ipad, name: "Studio iPad"))
        let clock = TestClock(), log = ProbeLog()
        let o = outputsAnswering(pairs: pairs, clock: { clock.now }, answer: { id in
            log.begin(id); defer { log.end() }
            return self.ready
        })
        o.activated()
        waitUntil { self.row(o, self.ipad)?.state == .ready }
        XCTAssertEqual(log.calls(ipad), 1)

        o.touch()
        clock.advance(4.9); o.touch()
        XCTAssertEqual(log.calls(ipad), 1, "not before 5 s")
        clock.advance(0.1); o.touch()
        waitUntil { log.calls(self.ipad) == 2 }
        XCTAssertEqual(log.calls(ipad), 2)
        waitUntil { !o.isProbing(self.ipad) }

        clock.advance(60)
        usleep(100_000)
        XCTAssertEqual(log.calls(ipad), 2, "no probes while the tab is not touched")
        o.touch()
        waitUntil { log.calls(self.ipad) == 3 }
        XCTAssertEqual(log.calls(ipad), 3)
        XCTAssertEqual(SpanDACOutputs.reprobeInterval, 5)
    }

    /// One probe in flight per SpanDAC: a slow answer is never overlapped by
    /// the next re-probe.
    func testReprobeNeverOverlapsForOneSpanDAC() {
        let pairs = store()
        try! pairs.save(record(ipad, name: "Studio iPad"))
        let clock = TestClock(), log = ProbeLog()
        let gate = DispatchSemaphore(value: 0)
        let o = outputsAnswering(pairs: pairs, clock: { clock.now }, answer: { id in
            log.begin(id); defer { log.end() }
            _ = gate.wait(timeout: .now() + 5)
            return self.ready
        })
        o.activated()
        waitUntil { log.calls(self.ipad) == 1 }
        XCTAssertEqual(log.calls(ipad), 1)
        XCTAssertTrue(o.isProbing(ipad))
        for _ in 0..<5 { clock.advance(10); o.touch() }
        o.activated()   // a fresh ask while one is in flight waits for it
        usleep(100_000)
        XCTAssertEqual(log.calls(ipad), 1, "nothing starts while one is in flight")
        gate.signal()
        waitUntil { log.calls(self.ipad) == 2 }
        XCTAssertEqual(log.calls(ipad), 2, "the fresh ask runs after the first answer")
        gate.signal()
        waitUntil { !o.isProbing(self.ipad) }
        XCTAssertFalse(o.isProbing(ipad))
        XCTAssertEqual(log.maxRunning, 1)
        XCTAssertEqual(row(o, ipad)?.state, .ready)
    }

    // MARK: - Pairing at once

    /// Enter on a SpanDAC that advertises `pair=1` connects at once: no
    /// waiting, no instruction to tap anything first. MusicTUI answers its
    /// own confirmation; the row counts down while the device asks Allow.
    func testAPairableSightingPairsAtOnce() throws {
        let pairs = store()
        let clock = TestClock()
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver(), posts = Posts()
        let o = outputs(pairs: pairs, browser: browser, driver: driver, posts: posts, clock: { clock.now },
                        reply: { _ in self.ready })
        o.touch()
        browser.emit([sighting(other, name: "Kitchen iPad", pairPort: 51456)])
        o.pair(other)
        XCTAssertEqual(driver.begun.count, 1, "connects at once")
        XCTAssertEqual(driver.begun.first?.port, 51456)
        XCTAssertEqual(driver.begun.first?.serviceName, other)
        XCTAssertEqual(driver.begun.first?.controllerName, "MusicTUI on Test Mac")
        XCTAssertEqual(driver.begun.first?.controllerID, try pairs.controllerID())
        XCTAssertEqual(row(o, other)?.state, .connecting)
        XCTAssertTrue(o.isPairing)

        driver.events?(.code("482 913", sourceName: "Kitchen iPad"))
        XCTAssertEqual(driver.handle.answers, [true], "MusicTUI answers its own confirmation automatically, with no prompt")
        XCTAssertFalse(o.awaitingAnswer, "nothing is asked on this Mac")
        driver.events?(.confirming)
        XCTAssertEqual(posts.texts.last, "Tap Allow on Kitchen iPad.")
        XCTAssertEqual(row(o, other)?.state,
                       .waitingForAllow(deadline: clock.now.addingTimeInterval(SpanDACPairingController.confirmTimeout)))

        XCTAssertNil(driver.save?(pairResult(other, name: "Kitchen iPad")), "the save succeeds")
        driver.events?(.finished(.success(pairResult(other, name: "Kitchen iPad"))))
        XCTAssertEqual(posts.texts.last, "Paired with Kitchen iPad.")
        XCTAssertEqual(pairs.pairs().map(\.sourceID), [other])
        XCTAssertFalse(o.isPairing)
        waitUntil { self.row(o, self.other)?.state == .ready }
        XCTAssertEqual(row(o, other)?.note, "ready", "a new pair is asked how it is at once")
    }

    /// `pairingPort == nil`: the device is not advertising pairing. Enter does
    /// nothing, and nothing tells the person to tap a button.
    func testASightingWithoutPairPortCannotPair() {
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver(), posts = Posts()
        let o = outputs(pairs: store(), browser: browser, driver: driver, posts: posts)
        o.touch()
        browser.emit([sighting(other, name: "Kitchen iPad")])
        o.pair(other)
        XCTAssertTrue(driver.begun.isEmpty)
        XCTAssertFalse(o.isPairing)
        XCTAssertEqual(posts.all.count, 0)
        XCTAssertEqual(row(o, other)?.state, .notPaired(pairable: false))
        XCTAssertEqual(row(o, other)?.note, "not paired · open SpanDAC on it to pair")
        o.pair(ipad)   // not seen at all
        XCTAssertTrue(driver.begun.isEmpty)
    }

    private final class Fired {
        private let lock = NSLock()
        private var _all: [(String, String)] = []
        var all: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _all }
        func add(_ id: String, _ name: String) { lock.lock(); _all.append((id, name)); lock.unlock() }
    }

    private func pairToSuccess(_ o: SpanDACOutputs, _ browser: FakeSpanDACBrowser, _ driver: FakePairingDriver,
                               name: String = "Kitchen iPad", key: UInt8 = 3) {
        o.touch()
        browser.emit([sighting(other, name: name, pairPort: 51456)])
        o.pair(other)
        driver.events?(.code("482 913", sourceName: name))
        driver.events?(.confirming)
        XCTAssertNil(driver.save?(pairResult(other, name: name, key: key)))
        driver.events?(.finished(.success(pairResult(other, name: name, key: key))))
    }

    /// A pair that answers ready fires `onPairedAndReady` exactly once, from
    /// the scene's own `tick()`, and later ticks or re-probes do not fire it
    /// again.
    func testPairingSuccessThatIsReadyFiresPairedAndReadyOnce() {
        let clock = TestClock(), fired = Fired()
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver()
        let o = outputs(pairs: store(), browser: browser, driver: driver, clock: { clock.now }, reply: { _ in self.ready })
        o.onPairedAndReady = { fired.add($0, $1) }
        pairToSuccess(o, browser, driver)
        waitUntil { self.row(o, self.other)?.state == .ready }
        _ = o.tick()
        XCTAssertEqual(fired.all.map(\.0), [other])
        XCTAssertEqual(fired.all.map(\.1), ["Kitchen iPad"])
        clock.advance(10); o.touch()
        waitUntil { !o.isProbing(self.other) }
        _ = o.tick(); _ = o.tick()
        XCTAssertEqual(fired.all.count, 1, "exactly once")
    }

    func testPairingSuccessThatIsNotReadyFiresNothing() {
        let clock = TestClock(), fired = Fired()
        var answer = noDAC
        let lock = NSLock()
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver()
        let o = outputs(pairs: store(), browser: browser, driver: driver, clock: { clock.now },
                        reply: { _ in lock.lock(); defer { lock.unlock() }; return answer })
        o.onPairedAndReady = { fired.add($0, $1) }
        pairToSuccess(o, browser, driver)
        waitUntil { self.row(o, self.other)?.state == .notReady("plug in your DAC") }
        _ = o.tick()
        XCTAssertEqual(row(o, other)?.state, .notReady("plug in your DAC"))
        XCTAssertTrue(fired.all.isEmpty)
        // It turning ready later, by a re-probe, is not a pairing: still nothing.
        lock.lock(); answer = ready; lock.unlock()
        clock.advance(10); o.touch()
        waitUntil { self.row(o, self.other)?.state == .ready }
        _ = o.tick()
        XCTAssertTrue(fired.all.isEmpty)
    }

    func testEscWhileWaitingForAllowFiresNothingAndSavesNothing() {
        let fired = Fired()
        let pairs = store()
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver(), posts = Posts()
        let o = outputs(pairs: pairs, browser: browser, driver: driver, posts: posts, reply: { _ in self.ready })
        o.onPairedAndReady = { fired.add($0, $1) }
        o.touch()
        browser.emit([sighting(other, name: "Kitchen iPad", pairPort: 51456)])
        o.pair(other)
        driver.events?(.code("482 913", sourceName: "Kitchen iPad"))
        driver.events?(.confirming)
        XCTAssertTrue(o.cancel())
        XCTAssertTrue(driver.handle.cancelled)
        driver.events?(.finished(.failure(.cancelled)))
        _ = o.tick()
        XCTAssertFalse(o.isPairing)
        XCTAssertEqual(pairs.pairs(), [])
        XCTAssertTrue(fired.all.isEmpty)
        XCTAssertEqual(posts.texts.last, "Pairing cancelled; nothing was paired.")
        XCTAssertEqual(row(o, other)?.state, .notPaired(pairable: true))
    }

    /// Enter on a forgotten row pairs again (the discovery list allows a
    /// `sourceID` that is already in `paired.json`), and the new pair replaces
    /// the old one; the row leaves the forgotten state.
    func testPairingAForgottenSpanDACAgainReplacesThePair() throws {
        let pairs = store()
        try pairs.save(record(other, name: "Kitchen iPad"))
        let lock = NSLock()
        var forgotten = true
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver()
        let o = outputsAnswering(pairs: pairs, browser: browser, driver: driver, answer: { _ in
            lock.lock(); defer { lock.unlock() }
            if forgotten { throw SourceAppError.link(.refused(-9864)) }
            return self.ready
        })
        o.activated()
        waitUntil { self.row(o, self.other)?.state == .forgotten }
        XCTAssertEqual(row(o, other)?.state, .forgotten)

        lock.lock(); forgotten = false; lock.unlock()
        pairToSuccess(o, browser, driver, key: 9)
        XCTAssertEqual(driver.begun.count, 1)
        XCTAssertEqual(pairs.pairs().count, 1)
        XCTAssertEqual(pairs.pairs().first?.pairKey, Data(repeating: 9, count: 32), "the new pair replaced the old")
        waitUntil { self.row(o, self.other)?.state == .ready }
        XCTAssertEqual(row(o, other)?.state, .ready)
    }

    /// C-TXT: `pair=1` is a hint. A device that refuses (busy, too_many,
    /// closed) puts the row in `.notPairableNow` with its words, never back to
    /// pairable, until its TXT record changes or the person presses Enter.
    func testARefusedPairingMapsToNotPairableNowNeverPairable() {
        let cases: [(SpanDACPairFailure, String)] = [
            (.busy, "pairing with another Mac  try again in a moment"),
            (.tooMany, "asked this Mac to wait  try again shortly"),
            (.windowClosed, "not ready to pair  open SpanDAC on it"),
        ]
        for (failure, copy) in cases {
            let browser = FakeSpanDACBrowser(), driver = FakePairingDriver()
            let o = outputs(pairs: store(), browser: browser, driver: driver)
            o.touch()
            let advertised = sighting(other, name: "Kitchen iPad", pairPort: 51456)
            browser.emit([advertised])
            o.pair(other)
            driver.events?(.finished(.failure(failure)))
            XCTAssertEqual(row(o, other)?.state, .notPairableNow(copy), "\(failure)")
            XCTAssertEqual(row(o, other)?.note, copy)
            XCTAssertEqual(row(o, other)?.ready, false)

            browser.emit([advertised])
            XCTAssertEqual(row(o, other)?.state, .notPairableNow(copy), "an unchanged TXT keeps it")

            o.pair(other)
            XCTAssertEqual(driver.begun.count, 2, "Enter tries once more while pair=1 is advertised")
            driver.events?(.finished(.failure(failure)))
            XCTAssertEqual(row(o, other)?.state, .notPairableNow(copy))

            browser.emit([sighting(other, name: "Kitchen iPad")])
            XCTAssertEqual(row(o, other)?.state, .notPaired(pairable: false), "a changed TXT clears it")
        }
    }

    /// The device's person taps Don't allow, or the key confirmation
    /// mismatches: nothing is saved and the failure is said in words.
    func testARejectionOrAMismatchSavesNothingAndSaysSo() {
        let pairs = store()
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
        XCTAssertEqual(row(o, other)?.state, .notPaired(pairable: true))
    }

    func testEscCancelsAPairingInProgress() {
        let pairs = store()
        let browser = FakeSpanDACBrowser(), driver = FakePairingDriver(), posts = Posts()
        let o = outputs(pairs: pairs, browser: browser, driver: driver, posts: posts)
        o.touch()
        browser.emit([sighting(other, name: "Kitchen iPad", pairPort: 51456)])
        o.pair(other)
        XCTAssertTrue(o.cancel())
        XCTAssertTrue(driver.handle.cancelled)
    }

    /// No sentence or note this Mac shows names a Pair button or a window.
    func testNoSentenceMentionsAPairButtonOrAWindow() {
        let failures: [SpanDACPairFailure] = [.windowClosed, .busy, .tooMany, .version, .codesDiffer, .timedOut,
                                              .broken("x"), .disconnected, .notSaved("x"), .cancelled]
        let links: [SpanDACLinkFailure] = [.notPaired, .pairingsUnavailable("x"), .notFound, .asleep,
                                           .refused(-9864), .refused(-9820), .refused(-9846), .refused(-9858),
                                           .refused(-1), .unsafeCipher, .noAnswer, .forgotten]
        var texts = failures.map(\.sentence) + links.map(\.sentence) + links.map(\.note)
        texts.append(SpanDACPairingController.failure(forSourceAbort: "too_many").sentence)
        let states = [SpanDACOutputs.PairingState(sourceID: other, name: "Kitchen iPad", phase: .connecting),
                      SpanDACOutputs.PairingState(sourceID: other, name: "Kitchen iPad", phase: .confirming(deadline: Date()))]
        texts += states.map(\.note)
        for text in texts {
            let lower = text.lowercased()
            XCTAssertFalse(lower.contains("window"), text)
            XCTAssertFalse(lower.contains("pair with musictui"), text)
            XCTAssertFalse(lower.contains("tap pair"), text)
            XCTAssertFalse(lower.contains("pair button"), text)
        }
        XCTAssertEqual(SpanDACPairFailure.windowClosed.sentence, "SpanDAC is not ready to pair; open it on the device.")
        XCTAssertEqual(SpanDACPairFailure.tooMany.sentence, "SpanDAC asked this Mac to wait before pairing again.")
        XCTAssertEqual(SpanDACPairingController.failure(forSourceAbort: "too_many"), .tooMany)
    }

    // MARK: - Forget

    /// `f`, then y: this Mac's copy goes, and any connection this process has
    /// open to it is cancelled. n keeps it.
    func testForgetAsksThenDeletesAndCancelsOpenConnections() {
        let pairs = store()
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
        let o = outputs(pairs: store(), browser: browser)
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
        XCTAssertTrue(text.contains("Select a SpanDAC and press Enter to pair"), text)
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
