// tools/music/Tests/MusicTests/OutputTabRenderTests.swift
//
// The Output tab as a person sees it: the SPANDAC section, the MUSIC.APP
// section, the top line and the footer, drawn from injected fakes. No Bonjour,
// no real SpanDAC, no Music.app, no ~/.config/music: every store is a temp
// path, speakers come from a closure, and the backend runs /usr/bin/true.
//
// `testRenderDump` writes the screens to files for a person to read; it is
// skipped unless OUTPUT_RENDER_DUMP names a directory.
import XCTest
@testable import music

// MARK: - Fakes shared by the Output tab scene tests

/// Stands in for the network SpanDACs so a test sets each row's state
/// directly, the way discovery and pairing will fill it.
final class FakeSpanDACOutputs: SpanDACOutputsDriving {
    private let lock = NSLock()
    private var _rows: [SpanDACOutputRow] = []
    private var changed = true
    private(set) var pairCalls: [String] = []
    private(set) var probeCalls: [String] = []
    var onPairedAndReady: ((_ sourceID: String, _ name: String) -> Void)?
    var awaitingAnswer = false
    var isPairing = false

    init(_ rows: [SpanDACOutputRow] = []) { _rows = rows }

    func set(_ rows: [SpanDACOutputRow]) {
        lock.lock(); _rows = rows; changed = true; lock.unlock()
    }

    func rows(selected selectedSourceID: String?) -> [SpanDACOutputRow] {
        lock.lock(); defer { lock.unlock() }
        return _rows
    }

    func tick() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = changed
        changed = false
        return was
    }

    func touch() {}
    func activated() {}
    func probe(_ sourceID: String) { lock.lock(); probeCalls.append(sourceID); lock.unlock() }
    func pair(_ sourceID: String) { lock.lock(); pairCalls.append(sourceID); lock.unlock() }
    @discardableResult func cancel() -> Bool { false }
    func answer(_ yes: Bool) {}
    func askToForget(_ sourceID: String) {}
}

/// A network SpanDAC row in a given state. `ready` follows the state, as the
/// row contract requires.
func spandacRow(_ id: String, _ name: String, _ state: SpanDACRowState, paired: Bool = true,
                output: SourceOutputInfo? = nil) -> SpanDACOutputRow {
    var row = SpanDACOutputRow(sourceID: id, name: name, paired: paired, note: "", ready: state == .ready)
    row.state = state
    row.output = output
    return row
}

/// Stands in for SpanDAC on this Mac's starter. It never launches anything:
/// the test sets what it answers, and every call is counted. `gate`, when
/// set, holds `ensureStarted()` until the test signals it.
final class FakeMacStarter: MacSpanDACStarting {
    private let lock = NSLock()
    private var _installed: Bool
    private var _running = false
    private var _outcome: MacSpanDACStartOutcome = .ready
    private var _starting = 0
    private var _ensureCalls = 0
    private var _bringForwardCalls = 0
    private var _newAttemptCalls = 0
    private let gate: DispatchSemaphore?
    /// Fires after every `ensureStarted()` and `bringForward()`.
    var onCall: (() -> Void)?

    init(installed: Bool = true, gate: DispatchSemaphore? = nil) {
        _installed = installed
        self.gate = gate
    }

    func set(installed: Bool? = nil, running: Bool? = nil, outcome: MacSpanDACStartOutcome? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let installed { _installed = installed }
        if let running { _running = running }
        if let outcome { _outcome = outcome }
    }

    var ensureCalls: Int { lock.lock(); defer { lock.unlock() }; return _ensureCalls }
    var bringForwardCalls: Int { lock.lock(); defer { lock.unlock() }; return _bringForwardCalls }
    var newAttemptCalls: Int { lock.lock(); defer { lock.unlock() }; return _newAttemptCalls }
    var anyCalls: Int { ensureCalls + bringForwardCalls + newAttemptCalls }

    var isInstalled: Bool { lock.lock(); defer { lock.unlock() }; return _installed }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    var isStarting: Bool { lock.lock(); defer { lock.unlock() }; return _starting > 0 }

    func ensureStarted() -> MacSpanDACStartOutcome {
        lock.lock(); _ensureCalls += 1; _starting += 1; lock.unlock()
        gate?.wait()
        lock.lock(); _starting -= 1; let outcome = _outcome; lock.unlock()
        onCall?()
        return outcome
    }

    func bringForward() {
        lock.lock(); _bringForwardCalls += 1; lock.unlock()
        onCall?()
    }

    func newAttempt() { lock.lock(); _newAttemptCalls += 1; lock.unlock() }
}

/// Counts how many times something was built.
final class BuildCounter {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func bump() { lock.lock(); _count += 1; lock.unlock() }
}

/// The DATA axis a test starts from, as `data.json` beside the temp mode.json.
enum OutputTabData {
    /// The person switched MusicTUI to SpanDAC: every test from before the
    /// data axis starts here, so its rows behave as they did.
    case accepted
    /// No data.json at all: open data, switch screen never shown.
    case none
    /// The person said "Not now": open data, declined.
    case declined
}

/// Builds the Output tab over fakes. The mode store and data.json are temp
/// files in `dir`; the Mac's SpanDAC and every network SpanDAC answer through
/// stub transports; the Mac starter is a fake that never launches anything;
/// the data client is counted and can only fail.
func makeOutputTabScene(dir: String, mode: PlaybackMode, spandac: SpanDACOutputsDriving?,
                        speakers: [[String: Any]] = [], status: StatusStore = StatusStore(),
                        macReply: @escaping () throws -> String = { outputTabReadyReply },
                        network: @escaping (String) -> SourceAppClient = { _ in
                            SourceAppClient(path: "/fake", transport: { _, _ in outputTabReadyReply })
                        },
                        macName: String = "Studio Mac",
                        clock: @escaping () -> Date = Date.init,
                        data: OutputTabData = .accepted,
                        starter: FakeMacStarter = FakeMacStarter(),
                        dataClients: BuildCounter = BuildCounter(),
                        macSocketExists: @escaping () -> Bool = { false }) -> SpeakersScene {
    let store = PlaybackModeStore(path: dir + "/mode.json")
    store.set(mode)
    let dataStore = DataProviderStore(path: dir + "/data.json")
    switch data {
    case .accepted: dataStore.accept()
    case .declined: dataStore.decline()
    case .none: try? FileManager.default.removeItem(atPath: dir + "/data.json")
    }
    let local = { SourceAppClient(path: "/nonexistent", transport: { _, _ in try macReply() }) }
    let routing = RoutingCoordinator(store: store, surface: .tui, dataStore: dataStore,
                                     makeSourceFor: { m in m.networkSourceID.map(network) ?? local() },
                                     makeDataClient: {
                                         dataClients.bump()
                                         return SourceAppClient(path: "/nonexistent", transport: { _, _ in throw SourceAppError.notRunning })
                                     },
                                     starter: starter)
    return SpeakersScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                         status: status, actions: ActionRunner(status: status), routing: routing,
                         makeSourceClient: local, makeNetworkClient: network, spandac: spandac,
                         macName: macName, clock: clock,
                         fetchSpeakers: { speakers },
                         fetchEQ: { _ in EQSnapshot(enabled: false, current: nil, presets: []) },
                         fetchVisualizer: { _ in false },
                         macSocketExists: macSocketExists)
}

/// A Mac SpanDAC that answers, is authorized, and has no DAC plugged in:
/// ready to serve music data, not ready to play.
let outputTabNoDACReply = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[],"output":{"dac":"not_connected"}}}"#
/// A Mac SpanDAC that answers but has not been allowed Apple Music access.
let outputTabNotAuthorizedReply = #"{"ok":true,"status":{"playback":"idle","authorization":"not_determined","contract":3,"capabilities":[]}}"#

let outputTabReadyReply = #"{"ok":true,"status":{"playback":"idle","authorization":"authorized","contract":3,"capabilities":[]}}"#

func outputTabSnapshot() -> NowPlayingSnapshot { NowPlayingSnapshot(outcome: .stopped, history: [], surrounding: []) }

/// Ticks until the Mac's first answer has landed and the speakers are loaded.
func settleOutputTab(_ s: SpeakersScene, speakers: Int, timeout: TimeInterval = 3) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        _ = s.tick(snapshot: outputTabSnapshot())
        if s.bridgeReadinessForTest != .checking, !s.hasPendingReadinessForTest,
           s.speakerRowsForTest.count == speakers { return }
        usleep(10_000)
    }
}

/// Plays the scene's escapes onto a character grid: cursor moves, line
/// clears and colour codes. What a terminal of that size would show.
func screenText(_ ansi: String, width: Int, height: Int) -> [String] {
    var grid = Array(repeating: Array(repeating: Character(" "), count: width), count: height)
    var row = 0, col = 0
    let chars = Array(ansi)
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if ch == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
            var j = i + 2
            var params = ""
            while j < chars.count, !chars[j].isLetter { params.append(chars[j]); j += 1 }
            guard j < chars.count else { break }
            switch chars[j] {
            case "H":
                let parts = params.split(separator: ";").compactMap { Int($0) }
                row = (parts.first ?? 1) - 1
                col = (parts.count > 1 ? parts[1] : 1) - 1
            case "K":
                if row >= 0, row < height { grid[row] = Array(repeating: " ", count: width) }
            default:
                break
            }
            i = j + 1
            continue
        }
        if row >= 0, row < height, col >= 0, col < width { grid[row][col] = ch }
        col += 1
        i += 1
    }
    return grid.map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
}

final class OutputTabRenderTests: XCTestCase {

    private var dir: String!
    private let phone = "A1B2C3D4-0000-4000-8000-00000000A001"
    private let ipad = "A1B2C3D4-0000-4000-8000-00000000A002"
    private let ssl = SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: 192_000)
    private let phoneDAC = SourceOutputInfo(dac: .connected, name: "SSL 2+", maxRateHz: nil)

    override func setUp() {
        dir = NSTemporaryDirectory() + "output-render-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func screen(_ s: SpeakersScene, width: Int = 100, height: Int = 30) -> String {
        let frame = shellLayout(width: width, height: height)
        return screenText(s.render(frame: frame, snapshot: outputTabSnapshot()), width: width, height: height)
            .joined(separator: "\n")
    }

    // MARK: - Pure pieces

    func testTheDACDetailLeavesOutWhatIsUnknown() {
        XCTAssertEqual(spandacOutputDetail(ssl), "SSL 2+ \u{00B7} 192 kHz")
        XCTAssertEqual(spandacOutputDetail(phoneDAC), "SSL 2+")
        XCTAssertEqual(spandacOutputDetail(SourceOutputInfo(dac: .connected, name: nil, maxRateHz: 44_100)), "44.1 kHz")
        XCTAssertEqual(spandacOutputDetail(SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil)), "")
        XCTAssertEqual(spandacOutputDetail(SourceOutputInfo(dac: .unknown, name: nil, maxRateHz: nil)), "")
        XCTAssertEqual(spandacOutputDetail(nil), "")
    }

    func testEveryRowStateHasItsWords() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        func text(_ state: SpanDACRowState, _ output: SourceOutputInfo? = nil, mac: Bool = false) -> String {
            spandacRowDetail(state: state, output: output, device: "iPhone", isThisMac: mac, now: now).text
        }
        XCTAssertEqual(text(.ready, ssl), "ready  SSL 2+ \u{00B7} 192 kHz")
        XCTAssertEqual(text(.notPaired(pairable: true)), "not paired  Enter to pair")
        XCTAssertEqual(text(.notPaired(pairable: false)), "not paired  open SpanDAC on it to pair")
        XCTAssertEqual(text(.notPairableNow("busy")), "pairing with another Mac  try again in a moment")
        XCTAssertEqual(text(.notPairableNow("too_many")), "asked this Mac to wait  try again shortly")
        XCTAssertEqual(text(.notPairableNow("closed")), "not ready to pair  open SpanDAC on it")
        XCTAssertEqual(text(.waitingForAllow(deadline: now.addingTimeInterval(112))), "Tap Allow on iPhone.  1:52 left")
        XCTAssertEqual(spandacRowDetail(state: .waitingForAllow(deadline: now), output: nil, device: "iPhone",
                                        isThisMac: false, now: now).secondLine,
                       "It plays there as soon as you allow it. Nothing else to pick.")
        XCTAssertEqual(text(.forgotten), "forgot this Mac  Enter to pair again")
        XCTAssertEqual(text(.needsRepair("x")), "pairing broken  Enter to pair again")
        XCTAssertEqual(text(.notReady("plug in your DAC"), SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil)),
                       "plug in your DAC  no DAC on iPhone's cable")
        XCTAssertEqual(text(.notReady("plug in your DAC"), mac: true), "plug in your DAC  no DAC on this Mac")
        XCTAssertEqual(text(.unreachable("asleep")), "not seen  open SpanDAC on it")
        XCTAssertEqual(text(.checking, SourceOutputInfo(dac: .unknown, name: nil, maxRateHz: nil)), "checking the DAC")
        XCTAssertEqual(text(.forgetPrompt), "forget? y / n")
    }

    func testTheMacRowIsNeverReadyWithAnUnknownOrMissingDAC() {
        let unknown = SourceOutputInfo(dac: .unknown, name: nil, maxRateHz: nil)
        let none = SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil)
        XCTAssertEqual(macSpanDACRowState(readiness: .ready, output: unknown), .checking)
        XCTAssertEqual(macSpanDACRowState(readiness: .unavailable("SpanDAC is still checking for a DAC"), output: unknown),
                       .checking)
        XCTAssertEqual(macSpanDACRowState(readiness: .ready, output: none), .notReady("plug in your DAC"))
        XCTAssertEqual(macSpanDACRowState(readiness: .ready, output: ssl), .ready)
        XCTAssertEqual(macSpanDACRowState(readiness: .ready, output: nil), .ready, "an older SpanDAC reads as before")
        XCTAssertEqual(macSpanDACRowState(readiness: .checking, output: nil), .checking)
        XCTAssertEqual(macSpanDACRowState(readiness: .notRunning, output: nil), .unreachable("SpanDAC is not running"))
    }

    func testBelowSixtyColumnsTheSectionIsNotBoxed() {
        let fake = FakeSpanDACOutputs([spandacRow(phone, "iPhone", .ready, output: phoneDAC)])
        let s = makeOutputTabScene(dir: dir, mode: .source, spandac: fake)
        settleOutputTab(s, speakers: 0)
        let narrow = screen(s, width: 50)
        XCTAssertFalse(narrow.contains("\u{256D}"), narrow)
        XCTAssertTrue(narrow.contains("SPANDAC"), narrow)
        XCTAssertTrue(narrow.contains("2  iPhone"), narrow)
        XCTAssertTrue(screen(s, width: 60).contains("\u{256D}"))
    }

    // MARK: - The dump for a person to read

    /// Seventeen states at 100 and 60 columns, one `.ansi` (raw, `cat` it in
    /// a terminal) and one `.txt` (what the screen shows) each. Skipped unless
    /// OUTPUT_RENDER_DUMP is set to a directory. Cases 1-7 are after the
    /// switch to SpanDAC data; 8-17 are the switch, the states before SpanDAC
    /// on this Mac is set up, and the way back.
    func testRenderDump() throws {
        guard let out = ProcessInfo.processInfo.environment["OUTPUT_RENDER_DUMP"], !out.isEmpty else {
            throw XCTSkip("set OUTPUT_RENDER_DUMP=<dir> to write the Output tab's screens")
        }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let twoSpeakers: [[String: Any]] = [
            ["name": "Kitchen", "selected": true, "volume": 58, "kind": "AirPlay"],
            ["name": "Living Room", "selected": true, "volume": 40, "kind": "AirPlay"],
            ["name": "Office", "selected": false, "volume": 30, "kind": "AirPlay"],
        ]
        let noDAC = SourceOutputInfo(dac: .notConnected, name: nil, maxRateHz: nil)

        struct Case {
            let name: String
            let mode: PlaybackMode
            let rows: [SpanDACOutputRow]
            let speakers: [[String: Any]]
            var pairing = false
            var data: OutputTabData = .accepted
            var macReply: () throws -> String = { outputTabReadyReply }
            var installed = true
            /// Delivered after the tab settles, as a probe would.
            var macStatus: (SourceReadiness, SourceOutputInfo?)? = (.ready, nil)
            /// Holds a start open, for the "Starting SpanDAC…" screen.
            var holdStart = false
            /// Keys pressed before the screen is drawn: the cursor goes to
            /// `enterOn` and Enter is pressed there.
            var enterOn: OutputTabRow? = nil
        }
        let cases: [Case] = [
            Case(name: "1-musicapp-two-speakers", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers),
            Case(name: "2-mac-selected-ready", mode: .source,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers),
            Case(name: "3-iphone-waiting-for-allow", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .waitingForAllow(deadline: now.addingTimeInterval(112)), paired: false)],
                 speakers: twoSpeakers, pairing: true),
            Case(name: "4-iphone-forgotten", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .forgotten)], speakers: twoSpeakers),
            Case(name: "5-iphone-selected-no-dac", mode: .networkSource(phone),
                 rows: [spandacRow(phone, "iPhone", .notReady("plug in your DAC"), output: noDAC)], speakers: twoSpeakers),
            Case(name: "6-unpaired-not-pairable", mode: .musicApp,
                 rows: [spandacRow(ipad, "Studio iPad", .notPaired(pairable: false), paired: false)], speakers: twoSpeakers),
            Case(name: "7-no-speakers", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: []),
            Case(name: "8-switch-screen", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 data: .none),
            Case(name: "9-no-mac-app-iphone-seen", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 data: .none, macReply: { throw SourceAppError.notRunning }, installed: false, macStatus: nil),
            Case(name: "10-installed-not-switched", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 data: .declined),
            Case(name: "11-starting", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 data: .declined, macReply: { throw SourceAppError.notRunning }, macStatus: nil,
                 holdStart: true, enterOn: .spandacMac),
            Case(name: "12-needs-apple-music-access", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 data: .declined, macReply: { outputTabNotAuthorizedReply }, macStatus: nil),
            Case(name: "13-blocked-existing-install", mode: .source,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 data: .none),
            Case(name: "14-blocked-after-not-now", mode: .source,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 data: .declined),
            Case(name: "15-switched-mac-app-missing", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 macReply: { throw SourceAppError.notRunning }, installed: false, macStatus: nil),
            Case(name: "16-spandac-data-musictui-output", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers),
            Case(name: "17-stop-using-asks", mode: .musicApp,
                 rows: [spandacRow(phone, "iPhone", .ready, output: phoneDAC)], speakers: twoSpeakers,
                 enterOn: .stopUsingSpanDAC),
        ]
        var gates: [DispatchSemaphore] = []
        defer { gates.forEach { $0.signal() } }
        var written: [String] = []
        for c in cases {
            let caseDir = dir + "/" + c.name
            try FileManager.default.createDirectory(atPath: caseDir, withIntermediateDirectories: true)
            let fake = FakeSpanDACOutputs(c.rows)
            fake.isPairing = c.pairing
            let gate = DispatchSemaphore(value: 0)
            if c.holdStart { gates.append(gate) }
            let starter = FakeMacStarter(installed: c.installed, gate: c.holdStart ? gate : nil)
            let s = makeOutputTabScene(dir: caseDir, mode: c.mode, spandac: fake, speakers: c.speakers,
                                       macReply: c.macReply, clock: { now }, data: c.data, starter: starter)
            settleOutputTab(s, speakers: c.speakers.count)
            if let status = c.macStatus {
                s.deliverMacStatusForTest(readiness: status.0, output: status.1 ?? ssl)
            }
            _ = s.tick(snapshot: outputTabSnapshot())
            if let row = c.enterOn {
                _ = s.handle(.home)
                if let i = s.displayRowsForTest.firstIndex(of: row) { for _ in 0..<i { _ = s.handle(.down) } }
                _ = s.handle(.enter)
                let deadline = Date().addingTimeInterval(3)
                while c.holdStart && starter.ensureCalls == 0 && Date() < deadline { usleep(10_000) }
                _ = s.tick(snapshot: outputTabSnapshot())
            }
            for width in [100, 60] {
                let height = 30
                let frame = shellLayout(width: width, height: height)
                let ansi = s.render(frame: frame, snapshot: outputTabSnapshot())
                let footer = ANSICode.moveTo(row: frame.footerY, col: 3) + ANSICode.clearLine
                    + "\(ANSICode.dim)\(s.footerHint)\(ANSICode.reset)"
                let raw = ANSICode.clearScreen + ansi + footer + ANSICode.moveTo(row: height + 1, col: 1) + "\n"
                let text = screenText(ansi + footer, width: width, height: height).joined(separator: "\n") + "\n"
                let base = "\(out)/\(c.name)-\(width)"
                try raw.write(toFile: base + ".ansi", atomically: true, encoding: .utf8)
                try text.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                written.append(base)
                XCTAssertTrue(text.contains("SPANDAC"), "\(c.name) at \(width)")
            }
        }
        XCTAssertEqual(written.count, 34)
    }
}
