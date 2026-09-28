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

/// Builds the Output tab over fakes. The mode store is a temp file in `dir`;
/// the Mac's SpanDAC and every network SpanDAC answer through stub transports.
func makeOutputTabScene(dir: String, mode: PlaybackMode, spandac: SpanDACOutputsDriving?,
                        speakers: [[String: Any]] = [], status: StatusStore = StatusStore(),
                        macReply: @escaping () throws -> String = { outputTabReadyReply },
                        network: @escaping (String) -> SourceAppClient = { _ in
                            SourceAppClient(path: "/fake", transport: { _, _ in outputTabReadyReply })
                        },
                        macName: String = "Studio Mac",
                        clock: @escaping () -> Date = Date.init) -> SpeakersScene {
    let store = PlaybackModeStore(path: dir + "/mode.json")
    store.set(mode)
    let local = { SourceAppClient(path: "/nonexistent", transport: { _, _ in try macReply() }) }
    let routing = RoutingCoordinator(store: store, surface: .tui, makeSourceFor: { m in
        m.networkSourceID.map(network) ?? local()
    })
    return SpeakersScene(backend: AppleScriptBackend(executable: "/usr/bin/true"),
                         status: status, actions: ActionRunner(status: status), routing: routing,
                         makeSourceClient: local, makeNetworkClient: network, spandac: spandac,
                         macName: macName, clock: clock,
                         fetchSpeakers: { speakers },
                         fetchEQ: { _ in EQSnapshot(enabled: false, current: nil, presets: []) },
                         fetchVisualizer: { _ in false })
}

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

    /// Seven states at 100 and 60 columns, one `.ansi` (raw, `cat` it in a
    /// terminal) and one `.txt` (what the screen shows) each. Skipped unless
    /// OUTPUT_RENDER_DUMP is set to a directory.
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
        ]
        var written: [String] = []
        for c in cases {
            let caseDir = dir + "/" + c.name
            try FileManager.default.createDirectory(atPath: caseDir, withIntermediateDirectories: true)
            let fake = FakeSpanDACOutputs(c.rows)
            fake.isPairing = c.pairing
            let s = makeOutputTabScene(dir: caseDir, mode: c.mode, spandac: fake, speakers: c.speakers,
                                       clock: { now })
            settleOutputTab(s, speakers: c.speakers.count)
            s.deliverMacStatusForTest(readiness: .ready, output: ssl)
            _ = s.tick(snapshot: outputTabSnapshot())
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
        XCTAssertEqual(written.count, 14)
    }
}
