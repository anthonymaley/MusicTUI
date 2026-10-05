// tools/music/Tests/MusicTests/SpanDACLicenceReprobeTests.swift
//
// Regaining SpanDAC's licence while the TUI is on another tab (review finding
// 7): while the licence cache says serving is false, the shell loop re-reads
// `slice.status` at a low rate so stored SpanDAC choices resume without the
// Output tab being opened. The cadence is a pure function; the reprobe goes
// through the coordinator's own wrapped client. Fixture transports and temp
// stores only: no socket, no player, no ~/.config/music.
import XCTest
@testable import music

final class SpanDACLicenceReprobeTests: XCTestCase {

    // MARK: cadence (pure)

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let interval: TimeInterval = 30

    private func due(_ serving: Bool?, last: Date?, at offset: TimeInterval,
                     inFlight: Bool = false) -> Bool {
        licenceReprobeDue(serving: serving, lastProbe: last, now: t0.addingTimeInterval(offset),
                          interval: interval, inFlight: inFlight)
    }

    func testTheReprobeIntervalIsThirtySeconds() {
        XCTAssertEqual(licenceReprobeIntervalSeconds, 30)
    }

    func testFiresWhileNotServingWhenNeverProbed() {
        XCTAssertTrue(due(false, last: nil, at: 0))
    }

    func testDoesNotFireWhileServingOrUnknown() {
        XCTAssertFalse(due(true, last: nil, at: 0))
        XCTAssertFalse(due(nil, last: nil, at: 0))
        XCTAssertFalse(due(true, last: t0, at: 1000))
        XCTAssertFalse(due(nil, last: t0, at: 1000))
    }

    func testRespectsTheInterval() {
        XCTAssertFalse(due(false, last: t0, at: 0))
        XCTAssertFalse(due(false, last: t0, at: 29.9))
        XCTAssertTrue(due(false, last: t0, at: 30))
        XCTAssertTrue(due(false, last: t0, at: 300))
    }

    func testDoesNotFireWhileOneIsInFlight() {
        XCTAssertFalse(due(false, last: nil, at: 0, inFlight: true))
        XCTAssertFalse(due(false, last: t0, at: 300, inFlight: true))
    }

    func testAClockStepBackwardsDoesNotFire() {
        XCTAssertFalse(due(false, last: t0, at: -500))
    }

    // MARK: the reprobe, through the coordinator's wrapped client

    private let notServing = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[],"licence":{"serving":false,"state":"none","text":"No licence."}}}"#
    private let serving = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[],"licence":{"serving":true,"state":"licensed","text":"ok"}}}"#

    private final class Fixture {
        let dir = NSTemporaryDirectory() + "music-licence-reprobe-\(UUID().uuidString)"
        let cache = SpanDACServingCache()
        let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        var answer: String
        let coordinator: RoutingCoordinator

        init(answer: String, output: PlaybackMode = .source) {
            self.answer = answer
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let modes = PlaybackModeStore(path: (dir as NSString).appendingPathComponent("mode.json"))
            XCTAssertTrue(modes.set(output))
            let data = DataProviderStore(path: (dir as NSString).appendingPathComponent("data.json"))
            XCTAssertTrue(data.accept())
            let cache = self.cache
            var make: ((PlaybackMode) -> SourceAppClient)!
            let holder = Holder()
            make = { _ in
                SourceAppClient(path: "/nonexistent", transport: observingLicence({ _, line in
                    holder.fixture?.record(line)
                    return holder.fixture?.answer ?? ""
                }, cache: cache))
            }
            coordinator = RoutingCoordinator(store: modes, surface: .tui, dataStore: data,
                                             makeSourceFor: make,
                                             makeDataClient: { make(.source) },
                                             starter: NeverStartsMacSpanDAC(), licence: cache)
            holder.fixture = self
        }
        final class Holder { weak var fixture: Fixture? }
        func record(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
        deinit { try? FileManager.default.removeItem(atPath: dir) }
    }

    /// Runs the queued work inline so a test needs no waiting; the real
    /// executor is a global queue.
    private func makeReprobe(_ f: Fixture, socket: @escaping () -> Bool = { true },
                             clock: @escaping () -> Date) -> LicenceReprobe {
        LicenceReprobe(routing: f.coordinator, interval: interval, now: clock, socketExists: socket,
                       async: { work in work() })
    }

    func testAReprobeReadsStatusThroughTheWrappedClientAndFlipsTheCache() {
        let f = Fixture(answer: serving)
        f.cache.observe(replyLine: notServing)
        XCTAssertEqual(f.cache.snapshot().serving, false)
        let flipsBefore = f.cache.snapshot().changes
        let fellBack = f.coordinator.selection
        let reprobe = makeReprobe(f, clock: { self.t0 })

        reprobe.tick()

        XCTAssertEqual(f.lines, [#"{"op":"slice.status"}"#])
        XCTAssertEqual(f.cache.snapshot().serving, true, "the wrapped client fed the cache")
        XCTAssertEqual(f.cache.snapshot().changes, flipsBefore + 1)
        XCTAssertNotEqual(f.coordinator.selection, fellBack, "the stored SpanDAC choice resumes")
    }

    func testNothingIsSentWhileServingOrUnknown() {
        for known in [true, nil] as [Bool?] {
            let f = Fixture(answer: serving)
            if known == true { f.cache.observe(replyLine: serving) }
            makeReprobe(f, clock: { self.t0 }).tick()
            XCTAssertEqual(f.lines, [], "serving=\(String(describing: known))")
        }
    }

    func testNothingIsSentWithoutTheSocketFile() {
        let f = Fixture(answer: serving)
        f.cache.observe(replyLine: notServing)
        makeReprobe(f, socket: { false }, clock: { self.t0 }).tick()
        XCTAssertEqual(f.lines, [])
        XCTAssertEqual(f.cache.snapshot().serving, false)
    }

    func testStillNotServingStaysNotServingAndWaitsOutTheInterval() {
        let f = Fixture(answer: notServing)
        f.cache.observe(replyLine: notServing)
        var now = t0
        let reprobe = makeReprobe(f, clock: { now })

        reprobe.tick()
        XCTAssertEqual(f.lines.count, 1)
        now = t0.addingTimeInterval(10)
        reprobe.tick()
        XCTAssertEqual(f.lines.count, 1, "inside the interval")
        now = t0.addingTimeInterval(30)
        reprobe.tick()
        XCTAssertEqual(f.lines.count, 2)
        XCTAssertEqual(f.cache.snapshot().serving, false)
    }

    func testAFailedReadChangesNothingAndIsNotRetriedAtOnce() {
        let f = Fixture(answer: "not json")
        f.cache.observe(replyLine: notServing)
        var now = t0
        let reprobe = makeReprobe(f, clock: { now })
        reprobe.tick()
        now = t0.addingTimeInterval(1)
        reprobe.tick()
        XCTAssertEqual(f.lines.count, 1)
        XCTAssertEqual(f.cache.snapshot().serving, false)
    }

    func testOneReprobeInFlightBlocksAnother() {
        let f = Fixture(answer: serving)
        f.cache.observe(replyLine: notServing)
        var pending: [() -> Void] = []
        var now = t0
        let reprobe = LicenceReprobe(routing: f.coordinator, interval: interval, now: { now },
                                     socketExists: { true }, async: { pending.append($0) })
        reprobe.tick()
        now = t0.addingTimeInterval(100)
        reprobe.tick()
        XCTAssertEqual(pending.count, 1, "the second tick finds one in flight")
        pending.removeFirst()()
        XCTAssertEqual(f.lines.count, 1)
        XCTAssertEqual(f.cache.snapshot().serving, true)
    }
}
