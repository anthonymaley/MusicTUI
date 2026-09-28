// tools/music/Tests/MusicTests/OutputTabTests.swift
//
// The Output tab's row model. Source Mode v1 section 4: Speakers becomes Output,
// gains the playback-mode selection and catalogue-access status, and loses EQ
// and Visualizer.
import XCTest
@testable import music

final class OutputTabTests: XCTestCase {

    /// Section 4. Mode first, because it is the only control that changes
    /// routing; catalogue access is status beneath it; AirPlay last.
    func testModeComesFirstAndAirPlayLast() {
        let rows = outputDisplayRows(speakerCount: 2, mode: .musicApp, sourceReady: .ready)
        XCTAssertEqual(rows.first, .modeHeader)
        XCTAssertEqual(rows[1], .mode(.musicApp))
        XCTAssertEqual(rows[2], .mode(.source))
        XCTAssertTrue(rows.contains(.catalogHeader))
        XCTAssertEqual(rows.last, .speaker(1))
    }

    /// EQ and Visualizer leave the TUI with their polling. Anthony judged them
    /// Music.app-specific and not useful for TUI use; the CLI verbs remain.
    func testEQAndVisualizerAreGone() {
        let rows = outputDisplayRows(speakerCount: 1, mode: .musicApp, sourceReady: .ready)
        for row in rows {
            switch row {
            case .modeHeader, .mode, .catalogHeader, .catalogStatus, .airplayHeader, .speaker:
                continue
            }
        }
        XCTAssertFalse(rows.isEmpty)
    }

    /// Binding rule: AirPlay applies in Music.app mode only. The rows are still
    /// LISTED in Source Mode, because hiding the user's speakers would be a
    /// worse answer than showing them inert with a reason.
    func testAirPlayRowsAreListedInBothModesButOnlyActInMusicApp() {
        let inMusicApp = outputDisplayRows(speakerCount: 3, mode: .musicApp, sourceReady: .ready)
        let inSource = outputDisplayRows(speakerCount: 3, mode: .source, sourceReady: .ready)
        XCTAssertEqual(inMusicApp.filter { if case .speaker = $0 { return true }; return false }.count, 3)
        XCTAssertEqual(inSource.filter { if case .speaker = $0 { return true }; return false }.count, 3)
        XCTAssertFalse(airPlayActs(in: .source))
        XCTAssertTrue(airPlayActs(in: .musicApp))
    }

    /// Ruling 12.13 collapsed four states to two. The property that survives is
    /// the one that mattered: only a Bridge that can actually serve is
    /// selectable, and every refusal says WHY.
    func testOnlyAReadyBridgeIsSelectableAndEveryRefusalSaysWhy() {
        XCTAssertTrue(SourceReadiness.ready.canSelect)
        XCTAssertEqual(SourceReadiness.ready.label, "ready")

        let reasons = ["SpanDAC is not running",
                       "SpanDAC was denied Apple Music access",
                       "Apple Music access is restricted on this Mac",
                       "SpanDAC speaks a different version (2); update one of them"]
        for reason in reasons {
            let state = SourceReadiness.unavailable(reason)
            XCTAssertFalse(state.canSelect, "\(reason) must not be selectable")
            XCTAssertEqual(state.label, reason, "the Output tab must show the reason itself")
            XCTAssertFalse(state.label.isEmpty)
        }
    }

    /// Codex I5: require the incoming source to be READY before the switch
    /// begins, so a failed selection cannot interrupt working playback.
    func testANonReadySourceCannotBeSelected() {
        XCTAssertFalse(outputModeSelectable(.source, readiness: .notRunning))
        XCTAssertTrue(outputModeSelectable(.source, readiness: .ready))
        // Music.app is always selectable: it needs nothing to be reachable.
        XCTAssertTrue(outputModeSelectable(.musicApp, readiness: .notRunning))
    }
}

// MARK: - Switching MusicTUI to SpanDAC, and the way back

/// The Output tab's side of the data route: the one-time "Switch MusicTUI to
/// SpanDAC?" screen, the states before SpanDAC on this Mac is set up, "Stop
/// using SpanDAC for music data", and the MusicTUI name. Everything runs over
/// fakes: temp mode.json and data.json, stub transports, a Mac starter that
/// never launches anything, and a data client that is only counted.
final class SpanDACSwitchOutputTabTests: XCTestCase {

    private var dir: String!
    private let phone = "A1B2C3D4-0000-4000-8000-00000000A001"
    private let ipad = "A1B2C3D4-0000-4000-8000-00000000A002"

    override func setUp() {
        dir = NSTemporaryDirectory() + "output-switch-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    /// What the Mac's SpanDAC answers, changeable mid-test.
    private final class MacAnswer {
        private let lock = NSLock()
        private var answer: () throws -> String
        init(_ answer: @escaping () throws -> String) { self.answer = answer }
        func set(_ answer: @escaping () throws -> String) { lock.lock(); self.answer = answer; lock.unlock() }
        func reply() throws -> String { lock.lock(); let a = answer; lock.unlock(); return try a() }
    }

    /// A clock the test moves, so the Mac row re-probes on demand.
    private final class Clock {
        private let lock = NSLock()
        private var t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    private final class Finished {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func bump() { lock.lock(); _count += 1; lock.unlock() }
    }

    private let ready: () throws -> String = { outputTabReadyReply }
    private let notRunning: () throws -> String = { throw SourceAppError.notRunning }
    private let notAuthorized: () throws -> String = { outputTabNotAuthorizedReply }

    private func scene(mode: PlaybackMode = .musicApp, data: OutputTabData,
                       answer: MacAnswer, starter: FakeMacStarter = FakeMacStarter(),
                       outputs: FakeSpanDACOutputs = FakeSpanDACOutputs(),
                       speakers: [[String: Any]] = [], status: StatusStore = StatusStore(),
                       dataClients: BuildCounter = BuildCounter(), clock: Clock? = nil,
                       macSocketExists: @escaping () -> Bool = { false }) -> SpeakersScene {
        let s = makeOutputTabScene(dir: dir, mode: mode, spandac: outputs, speakers: speakers, status: status,
                                   macReply: { try answer.reply() },
                                   clock: clock.map { c in { c.now() } } ?? Date.init,
                                   data: data, starter: starter, dataClients: dataClients,
                                   macSocketExists: macSocketExists)
        settleOutputTab(s, speakers: speakers.count)
        return s
    }

    private func watchData(_ s: SpeakersScene) -> Finished {
        let f = Finished()
        s.dataActionFinishedForTest = { f.bump() }
        return f
    }

    private func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(10_000) }
        return condition()
    }

    /// Ticks until `condition` holds (the Mac's answer must come back through
    /// the inbox), moving the clock past the re-probe interval each round.
    private func tick(_ s: SpeakersScene, clock: Clock? = nil, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            clock?.advance(SpeakersScene.macReprobeInterval)
            _ = s.tick(snapshot: outputTabSnapshot())
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    private func put(_ s: SpeakersScene, on row: OutputTabRow) {
        _ = s.handle(.home)
        guard let i = s.displayRowsForTest.firstIndex(of: row) else { return XCTFail("no \(row) row") }
        for _ in 0..<i { _ = s.handle(.down) }
    }

    private func lines(_ s: SpeakersScene, width: Int = 100) -> [String] {
        screenText(s.render(frame: shellLayout(width: width, height: 30), snapshot: outputTabSnapshot()),
                   width: width, height: 30)
    }

    /// The whole screen as one sentence stream: box sides and wrapping removed.
    private func prose(_ s: SpeakersScene, width: Int) -> String {
        lines(s, width: width)
            .map { $0.replacingOccurrences(of: "[\u{2502}\u{254E}\u{2506}]", with: " ", options: .regularExpression) }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func data() -> (DataProviderSelection, SwitchCeremonyState) {
        let read = DataProviderStore(path: dir + "/data.json").read()
        return (read.data, read.ceremony)
    }
    private func bytes(_ file: String) -> Data? { FileManager.default.contents(atPath: dir + "/" + file) }
    private func modeOnDisk() -> PlaybackMode { PlaybackModeStore(path: dir + "/mode.json").mode() }

    private let agreed = [
        "SPANDAC IS SET UP ON THIS MAC",
        "Switch MusicTUI to SpanDAC?",
        "+ Search, Discover and Radio come straight from Apple Music. No developer key.",
        "+ Lossless to your DAC, on this Mac, your iPhone or iPad, when you pick one in Output.",
        "= Your library and new music still play on MusicTUI and your speakers.",
    ]

    // MARK: No SpanDAC on this Mac

    func testNoMacAppShowsTheDashedBoxAndNeedsMacRows() {
        let starter = FakeMacStarter(installed: false)
        let outputs = FakeSpanDACOutputs([spandacRow(phone, "iPhone", .ready),
                                          spandacRow(ipad, "Studio iPad", .notPaired(pairable: true), paired: false)])
        let s = scene(data: .none, answer: MacAnswer(notRunning), starter: starter, outputs: outputs,
                      speakers: [["name": "Kitchen", "selected": true, "volume": 50]])
        XCTAssertTrue(tick(s) { s.displayRowsForTest.first == .speaker(0) }, "\(s.displayRowsForTest)")

        let wide = lines(s)
        let text = wide.joined(separator: "\n")
        XCTAssertTrue(wide.contains { $0.contains("SPANDAC  not set up on this Mac") }, text)
        XCTAssertTrue(text.contains("Lossless to your DAC, and Apple Music without a developer key."), text)
        XCTAssertTrue(text.contains("Install SpanDAC on this Mac to start. Your iPhone and iPad work with it once it's set up."), text)
        XCTAssertTrue(text.contains("iPhone  seen on your network \u{00B7} needs SpanDAC on this Mac first"), text)
        XCTAssertTrue(text.contains("Studio iPad  seen on your network \u{00B7} needs SpanDAC on this Mac first"), text)
        XCTAssertTrue(text.contains("\u{254C}"), "the box is dashed: \(text)")
        XCTAssertFalse(text.contains("Studio Mac"), "no row for a SpanDAC that is not here")
        XCTAssertFalse(text.contains("Stop using SpanDAC"), "nothing to stop: data is MusicTUI's own")

        let narrow = prose(s, width: 60)
        for sentence in ["SPANDAC not set up on this Mac",
                         "Lossless to your DAC, and Apple Music without a developer key.",
                         "Install SpanDAC on this Mac to start. Your iPhone and iPad work with it once it's set up.",
                         "iPhone seen on your network \u{00B7} needs SpanDAC on this Mac first"] {
            XCTAssertTrue(narrow.contains(sentence), "60 columns: \(sentence)\n\(narrow)")
        }

        // Not selectable: no row to put the cursor on, and Enter anywhere
        // never pairs, never switches, never starts anything.
        XCTAssertFalse(s.displayRowsForTest.contains(.spandacMac))
        XCTAssertFalse(s.displayRowsForTest.contains { if case .spandac = $0 { return true }; return false })
        let before = bytes("mode.json")
        _ = s.handle(.home)
        _ = s.handle(.up)
        XCTAssertEqual(outputs.pairCalls, [])
        usleep(200_000)
        XCTAssertEqual(bytes("mode.json"), before)
        XCTAssertEqual(starter.anyCalls, 0)
    }

    func testNetworkRowsCannotPairOrPlayUntilSwitched() {
        let status = StatusStore()
        let outputs = FakeSpanDACOutputs([spandacRow(phone, "iPhone", .ready),
                                          spandacRow(ipad, "Studio iPad", .notPaired(pairable: true), paired: false),
                                          spandacRow("K", "Kitchen iPad", .forgotten)])
        let s = scene(data: .declined, answer: MacAnswer(ready), outputs: outputs, status: status)
        let text = lines(s).joined(separator: "\n")
        for name in ["iPhone", "Studio iPad", "Kitchen iPad"] {
            XCTAssertTrue(lines(s).contains { $0.contains(name) && $0.contains("needs SpanDAC on this Mac first") },
                          "\(name)\n\(text)")
        }
        XCTAssertFalse(s.displayRowsForTest.contains { if case .spandac = $0 { return true }; return false },
                       "\(s.displayRowsForTest)")
        let before = bytes("mode.json")
        for (i, row) in s.displayRowsForTest.enumerated() where row != .spandacMac {
            _ = s.handle(.home)
            for _ in 0..<i { _ = s.handle(.down) }
            _ = s.handle(.enter)
        }
        // A pair finishing elsewhere does not make one of them the output.
        outputs.onPairedAndReady?(phone, "iPhone")
        usleep(300_000)
        XCTAssertEqual(outputs.pairCalls, [], "Enter never pairs before the switch")
        XCTAssertEqual(bytes("mode.json"), before)
        XCTAssertEqual(modeOnDisk(), .musicApp)
    }

    // MARK: The switch screen

    func testTheSwitchScreenShowsOnceWhenTheMacFirstReadsReady() {
        let answer = MacAnswer(notRunning)
        let clock = Clock()
        let s = scene(data: .none, answer: answer, clock: clock)
        XCTAssertFalse(s.isShowingSwitchScreen, "not before SpanDAC on this Mac reads ready")
        XCTAssertNil(bytes("data.json"))

        answer.set(ready)
        XCTAssertTrue(tick(s, clock: clock) { s.isShowingSwitchScreen })
        XCTAssertNil(bytes("data.json"), "showing it writes nothing")

        let finished = watchData(s)
        XCTAssertEqual(s.handle(.escape), .redraw, "Esc answers the screen; it does not leave the tab")
        XCTAssertFalse(s.isShowingSwitchScreen)
        XCTAssertTrue(wait { finished.count == 1 })
        XCTAssertEqual(data().1, .declined)

        // Never again by itself: not on later probes, not on a new visit.
        for _ in 0..<5 { clock.advance(SpeakersScene.macReprobeInterval); _ = s.tick(snapshot: outputTabSnapshot()); usleep(20_000) }
        XCTAssertFalse(s.isShowingSwitchScreen)
        let later = scene(data: .declined, answer: answer, clock: clock)
        for _ in 0..<5 { clock.advance(SpeakersScene.macReprobeInterval); _ = later.tick(snapshot: outputTabSnapshot()); usleep(20_000) }
        XCTAssertFalse(later.isShowingSwitchScreen)
    }

    func testABlockedExistingInstallSeesTheSwitchScreen() {
        // An install from before the data route: SpanDAC on this Mac is the
        // stored output, and there is no data.json at all. No migration.
        let s = scene(mode: .source, data: .none, answer: MacAnswer(ready))
        XCTAssertEqual(s.routingForTest.selection, .outputBlocked(stored: .source))
        XCTAssertTrue(tick(s) { s.isShowingSwitchScreen })
        let modeBefore = bytes("mode.json")

        let finished = watchData(s)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(wait { finished.count == 1 })
        XCTAssertEqual(s.routingForTest.selection, .consistent(data: .spandacMac, output: .source),
                       "the stored output is live again")
        XCTAssertEqual(data().0, .spandacMac)
        XCTAssertEqual(bytes("mode.json"), modeBefore)
    }

    func testEscDeclinesAndEnterOnTheMacRowAsksAgain() {
        let s = scene(data: .none, answer: MacAnswer(ready))
        XCTAssertTrue(tick(s) { s.isShowingSwitchScreen })
        let finished = watchData(s)
        _ = s.handle(.escape)
        XCTAssertTrue(wait { finished.count == 1 })
        XCTAssertEqual(data().0, .open)
        XCTAssertEqual(data().1, .declined)
        XCTAssertEqual(s.routingForTest.dataEpoch, 0, "Not now switches nothing")

        XCTAssertTrue(lines(s).contains { $0.contains("Studio Mac") && $0.contains("ready  Enter to switch MusicTUI to SpanDAC") },
                      lines(s).joined(separator: "\n"))
        put(s, on: .spandacMac)
        XCTAssertTrue(s.footerHint.contains("Enter Switch to SpanDAC"), s.footerHint)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(s.isShowingSwitchScreen, "Enter on the Mac row asks again")
        _ = s.handle(.escape)
        XCTAssertFalse(s.isShowingSwitchScreen)
        XCTAssertEqual(data().1, .declined)
    }

    func testEnterOnTheSwitchScreenAcceptsDataAndLeavesTheOutput() {
        let status = StatusStore()
        let s = scene(data: .none, answer: MacAnswer(ready),
                      speakers: [["name": "Kitchen", "selected": true, "volume": 50]], status: status)
        XCTAssertTrue(tick(s) { s.isShowingSwitchScreen })
        let modeBefore = bytes("mode.json")
        let finished = watchData(s)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(wait { finished.count == 1 })
        XCTAssertFalse(s.isShowingSwitchScreen)
        XCTAssertEqual(data().0, .spandacMac)
        XCTAssertEqual(data().1, .accepted)
        XCTAssertEqual(bytes("mode.json"), modeBefore, "the output is untouched")
        XCTAssertEqual(s.routingForTest.mode, .musicApp)
        XCTAssertEqual(s.routingForTest.dataEpoch, 1)
        XCTAssertEqual(s.routingForTest.epoch, 0)
        XCTAssertEqual(status.current()?.text, "MusicTUI now gets its music data from SpanDAC.")
        // From here the Mac row is an output again, as before.
        put(s, on: .spandacMac)
        XCTAssertTrue(s.footerHint.contains("Enter Play here"), s.footerHint)

        // Music data does not need a DAC: a Mac with none plugged in still
        // offers the switch, and accepting it works.
        let other = dir + "/nodac"
        try! FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        let nodac = makeOutputTabScene(dir: other, mode: .musicApp, spandac: FakeSpanDACOutputs(),
                                       macReply: { outputTabNoDACReply }, data: .none)
        settleOutputTab(nodac, speakers: 0)
        XCTAssertTrue(tick(nodac) { nodac.isShowingSwitchScreen })
        let f2 = watchData(nodac)
        _ = nodac.handle(.enter)
        XCTAssertTrue(wait { f2.count == 1 })
        XCTAssertEqual(DataProviderStore(path: other + "/data.json").read().data, .spandacMac)
    }

    func testSwitchScreenTextIsTheAgreedText() {
        let s = scene(data: .none, answer: MacAnswer(ready))
        XCTAssertTrue(tick(s) { s.isShowingSwitchScreen })
        let words = lines(s)
            .map { $0.replacingOccurrences(of: "[\u{2502}\u{256D}\u{256E}\u{2570}\u{256F}\u{2500}]", with: "",
                                           options: .regularExpression)
                     .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(words, agreed, lines(s).joined(separator: "\n"))
        XCTAssertEqual(s.footerHint, "Enter Switch to SpanDAC   Esc Not now")
        for width in [60, 40] {
            let text = prose(s, width: width)
            for sentence in agreed { XCTAssertTrue(text.contains(sentence), "\(width): \(sentence)\n\(text)") }
            XCTAssertFalse(text.contains("\u{2026}"), "nothing is cut off at \(width)")
        }
        for width in [100, 60, 40] {
            XCTAssertFalse(lines(s, width: width).joined().contains("Music.app"))
        }
    }

    // MARK: SpanDAC on this Mac, installed and not switched

    func testNotRunningEnterStartsOnceAndShowsStarting() {
        let gate = DispatchSemaphore(value: 0)
        let starter = FakeMacStarter(installed: true, gate: gate)
        let answer = MacAnswer(notRunning)
        let clock = Clock()
        let s = scene(data: .none, answer: answer, starter: starter, clock: clock)
        XCTAssertTrue(lines(s).contains { $0.contains("Studio Mac") && $0.contains("not running  Enter to start it") },
                      lines(s).joined(separator: "\n"))
        XCTAssertEqual(starter.anyCalls, 0)

        put(s, on: .spandacMac)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(wait { starter.ensureCalls == 1 })
        XCTAssertEqual(starter.newAttemptCalls, 1, "a person's Enter is a new attempt")
        _ = s.tick(snapshot: outputTabSnapshot())
        XCTAssertTrue(lines(s).contains { $0.contains("Studio Mac") && $0.contains(startingSpanDAC) },
                      lines(s).joined(separator: "\n"))
        XCTAssertEqual(s.handle(.enter), .none, "one start at a time")
        usleep(100_000)
        XCTAssertEqual(starter.ensureCalls, 1)

        answer.set(ready)
        gate.signal()
        XCTAssertTrue(tick(s, clock: clock) { s.isShowingSwitchScreen }, "the switch screen follows a start that reached ready")
        XCTAssertEqual(starter.ensureCalls, 1)
        XCTAssertEqual(starter.newAttemptCalls, 1)
        XCTAssertEqual(starter.bringForwardCalls, 0)
    }

    func testNeedsAccessEnterBringsSpanDACForward() {
        let starter = FakeMacStarter(installed: true)
        let s = scene(data: .none, answer: MacAnswer(notAuthorized), starter: starter)
        XCTAssertTrue(lines(s).contains { $0.contains("Studio Mac") && $0.contains("needs Apple Music access  Enter to open SpanDAC") },
                      lines(s).joined(separator: "\n"))
        XCTAssertFalse(s.isShowingSwitchScreen)
        put(s, on: .spandacMac)
        XCTAssertEqual(s.handle(.enter), .redraw)
        XCTAssertTrue(wait { starter.bringForwardCalls == 1 })
        usleep(100_000)
        XCTAssertEqual(starter.bringForwardCalls, 1)
        XCTAssertEqual(starter.ensureCalls, 0, "bringing it forward is not a start")
        XCTAssertNil(bytes("data.json"))
    }

    func testOpenDataOutputTabNeverLaunchesSpanDACUnasked() {
        let answers: [(String, () throws -> String)] = [
            ("not running", notRunning), ("not authorized", notAuthorized),
            ("ready", ready), ("no DAC", { outputTabNoDACReply }),
            ("timed out", { throw SourceAppError.timedOut }),
        ]
        for (name, reply) in answers {
            for installed in [true, false] {
                for data in [OutputTabData.none, .declined] {
                    let starter = FakeMacStarter(installed: installed)
                    let dataClients = BuildCounter()
                    let clock = Clock()
                    let s = scene(data: data, answer: MacAnswer(reply), starter: starter,
                                  outputs: FakeSpanDACOutputs([spandacRow(phone, "iPhone", .ready)]),
                                  dataClients: dataClients, clock: clock)
                    for _ in 0..<10 {
                        clock.advance(SpeakersScene.macReprobeInterval)
                        _ = s.tick(snapshot: outputTabSnapshot())
                        _ = s.render(frame: shellLayout(width: 100, height: 30), snapshot: outputTabSnapshot())
                        usleep(10_000)
                    }
                    let label = "\(name), installed \(installed), \(data)"
                    XCTAssertEqual(starter.anyCalls, 0, label)
                    XCTAssertEqual(dataClients.count, 0, "open data never builds a SpanDAC data client: \(label)")
                }
            }
        }
    }

    // MARK: Stop using SpanDAC for music data

    func testStopUsingSpanDACIsOfferedWhenSwitched() {
        let s = scene(data: .accepted, answer: MacAnswer(ready),
                      outputs: FakeSpanDACOutputs([spandacRow(phone, "iPhone", .ready)]),
                      speakers: [["name": "Kitchen", "selected": true, "volume": 50]])
        XCTAssertEqual(Array(s.displayRowsForTest.prefix(4)),
                       [.spandacMac, .spandac(phone), .stopUsingSpanDAC, .speaker(0)])
        let shown = lines(s)
        guard let phoneLine = shown.firstIndex(where: { $0.contains("iPhone") }),
              let stop = shown.firstIndex(where: { $0.contains("Stop using SpanDAC for music data") }),
              let header = shown.firstIndex(where: { $0.contains("MUSICTUI") }) else {
            return XCTFail(shown.joined(separator: "\n"))
        }
        XCTAssertLessThan(phoneLine, stop)
        XCTAssertLessThan(stop, header, "at the end of the SPANDAC section")
        XCTAssertTrue(shown[stop].contains("\u{2502}"), "inside the box")

        for data in [OutputTabData.none, .declined] {
            let sub = dir + "/\(data)"
            try! FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
            let open = makeOutputTabScene(dir: sub, mode: .musicApp, spandac: FakeSpanDACOutputs(), data: data)
            settleOutputTab(open, speakers: 0)
            XCTAssertFalse(open.displayRowsForTest.contains(.stopUsingSpanDAC), "\(data)")
        }
    }

    func testStopUsingSpanDACIsProminentWhenTheMacAppIsMissingOrNotAuthorized() {
        func check(_ s: SpeakersScene, _ label: String) {
            XCTAssertTrue(tick(s) { s.displayRowsForTest.first == .stopUsingSpanDAC }, "\(label): \(s.displayRowsForTest)")
            let raw = s.render(frame: shellLayout(width: 100, height: 30), snapshot: outputTabSnapshot())
            let shown = screenText(raw, width: 100, height: 30)
            guard let stop = shown.firstIndex(where: { $0.contains("Stop using SpanDAC for music data") }),
                  let header = shown.firstIndex(where: { $0.contains("SPANDAC") && !$0.contains("Stop using") }) else {
                return XCTFail("\(label)\n" + shown.joined(separator: "\n"))
            }
            XCTAssertLessThan(stop, header, "\(label): at the top of the tab")
            XCTAssertTrue(raw.contains("\(ANSICode.amber)Stop using SpanDAC for music data"), "\(label): drawn amber")
        }
        var n = 0
        func sub() -> String {
            n += 1
            let d = dir + "/\(n)"
            try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            return d
        }
        check(makeOutputTabScene(dir: sub(), mode: .musicApp, spandac: FakeSpanDACOutputs(),
                                 macReply: { throw SourceAppError.notRunning }, data: .accepted,
                                 starter: FakeMacStarter(installed: false)), "missing")
        check(makeOutputTabScene(dir: sub(), mode: .musicApp, spandac: FakeSpanDACOutputs(),
                                 macReply: { outputTabNotAuthorizedReply }, data: .accepted), "not authorized")
        check(makeOutputTabScene(dir: sub(), mode: .source, spandac: FakeSpanDACOutputs(),
                                 data: .declined), "blocked")

        // Set up and answering: back at the end of the section.
        let fine = makeOutputTabScene(dir: sub(), mode: .musicApp, spandac: FakeSpanDACOutputs(), data: .accepted)
        settleOutputTab(fine, speakers: 0)
        XCTAssertEqual(Array(fine.displayRowsForTest.prefix(2)), [.spandacMac, .stopUsingSpanDAC])
    }

    func testStopUsingSpanDACAsksFirstAndNothingHappensOnNo() {
        let status = StatusStore()
        let s = scene(mode: .source, data: .accepted, answer: MacAnswer(ready), status: status)
        let dataBefore = bytes("data.json"), modeBefore = bytes("mode.json")
        let finished = watchData(s)
        put(s, on: .stopUsingSpanDAC)
        XCTAssertEqual(s.handle(.enter), .redraw)
        let question = "Stop using SpanDAC for music data? MusicTUI goes back to its own library and search.  y Yes  n No"
        XCTAssertTrue(prose(s, width: 100).contains(question.replacingOccurrences(of: "  ", with: " ")),
                      lines(s).joined(separator: "\n"))
        XCTAssertEqual(s.footerHint, "y Yes  n No")

        XCTAssertEqual(s.handle(.char("n")), .redraw)
        XCTAssertFalse(prose(s, width: 100).contains("MusicTUI goes back"))
        _ = s.handle(.enter)
        XCTAssertEqual(s.handle(.escape), .redraw, "Esc answers no; it does not leave the tab")
        usleep(300_000)
        XCTAssertEqual(finished.count, 0)
        XCTAssertEqual(bytes("data.json"), dataBefore)
        XCTAssertEqual(bytes("mode.json"), modeBefore)

        _ = s.handle(.enter)
        XCTAssertEqual(s.handle(.char("y")), .redraw)
        XCTAssertTrue(wait { finished.count == 1 })
        XCTAssertEqual(data().0, .open)
        XCTAssertEqual(data().1, .declined)
        XCTAssertEqual(modeOnDisk(), .musicApp, "the SpanDAC output was left first")
        XCTAssertEqual(s.routingForTest.dataEpoch, 1)
        XCTAssertEqual(s.routingForTest.epoch, 1)
        XCTAssertEqual(status.current()?.text, "MusicTUI is using its own music data again.")
    }

    /// C-REPAIR's pause rule on the way back: SpanDAC on this Mac that is
    /// not running AND has no socket counts as paused; one that may still be
    /// running does not, and the output stays blocked with the reason shown.
    func testStopUsingSpanDACFromABlockedMacOutputUsesTheAbsenceRule() {
        let absent = scene(mode: .source, data: .declined, answer: MacAnswer(notRunning),
                           starter: FakeMacStarter(installed: true))
        let f1 = watchData(absent)
        put(absent, on: .stopUsingSpanDAC)
        _ = absent.handle(.enter); _ = absent.handle(.char("y"))
        XCTAssertTrue(wait { f1.count == 1 })
        XCTAssertEqual(modeOnDisk(), .musicApp)
        XCTAssertEqual(data().0, .open)

        let other = dir + "/running"
        try! FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        let starter = FakeMacStarter(installed: true)
        starter.set(running: true)
        let running = makeOutputTabScene(dir: other, mode: .source, spandac: FakeSpanDACOutputs(),
                                         macReply: { throw SourceAppError.notRunning }, data: .declined,
                                         starter: starter)
        settleOutputTab(running, speakers: 0)
        let f2 = watchData(running)
        put(running, on: .stopUsingSpanDAC)
        _ = running.handle(.enter); _ = running.handle(.char("y"))
        XCTAssertTrue(wait { f2.count == 1 })
        XCTAssertEqual(PlaybackModeStore(path: other + "/mode.json").mode(), .source, "never left unconfirmed")
        XCTAssertEqual(running.routingForTest.selection, .outputBlocked(stored: .source))
        XCTAssertTrue(tick(running) {
            self.lines(running).contains { $0.contains("Couldn't confirm SpanDAC on this Mac paused") }
        }, lines(running).joined(separator: "\n"))
        XCTAssertEqual(running.displayRowsForTest.first, .stopUsingSpanDAC, "still offered, to retry")
    }

    func testNothingSwitchesByItself() {
        let starter = FakeMacStarter(installed: true)
        let answer = MacAnswer(ready)
        let clock = Clock()
        let s = scene(mode: .source, data: .accepted, answer: answer, starter: starter, clock: clock)
        let dataBefore = bytes("data.json"), modeBefore = bytes("mode.json")
        let states: [(Bool, () throws -> String)] = [
            (false, notRunning),                           // missing
            (true, notAuthorized),                         // not authorized
            (true, { throw SourceAppError.timedOut }),     // did not answer in time
            (true, notRunning),
            (true, ready),
        ]
        for (installed, reply) in states {
            starter.set(installed: installed)
            answer.set(reply)
            for _ in 0..<10 {
                clock.advance(SpeakersScene.macReprobeInterval)
                _ = s.tick(snapshot: outputTabSnapshot())
                _ = s.render(frame: shellLayout(width: 100, height: 30), snapshot: outputTabSnapshot())
                usleep(10_000)
            }
        }
        usleep(200_000)
        XCTAssertEqual(bytes("data.json"), dataBefore)
        XCTAssertEqual(bytes("mode.json"), modeBefore)
        XCTAssertEqual(s.routingForTest.stamp.epoch, 0)
        XCTAssertEqual(s.routingForTest.stamp.dataEpoch, 0)
        XCTAssertFalse(s.isShowingSwitchScreen)
        XCTAssertEqual(starter.anyCalls, 0)
    }

    // MARK: The MusicTUI name

    func testTopLineAndHeaderSayMusicTUI() {
        let speakers: [[String: Any]] = [
            ["name": "Kitchen", "selected": true, "volume": 50],
            ["name": "Living Room", "selected": true, "volume": 50],
        ]
        let s = scene(data: .accepted, answer: MacAnswer(ready), speakers: speakers)
        let shown = lines(s)
        XCTAssertEqual(shown.first { !$0.isEmpty }?.trimmingCharacters(in: .whitespaces),
                       "Playing through  MusicTUI \u{2192} Kitchen, Living Room")
        XCTAssertTrue(shown.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("MUSICTUI  this Mac and AirPlay speakers") },
                      shown.joined(separator: "\n"))

        let sub = dir + "/none"
        try! FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let bare = makeOutputTabScene(dir: sub, mode: .source, spandac: FakeSpanDACOutputs())
        settleOutputTab(bare, speakers: 0)
        XCTAssertTrue(lines(bare).contains { $0.contains("MusicTUI") && $0.contains("this Mac") })
        put(bare, on: .musicApp)
        XCTAssertTrue(bare.footerHint.contains("Enter Use MusicTUI"), bare.footerHint)

        let sub2 = dir + "/speaker"
        try! FileManager.default.createDirectory(atPath: sub2, withIntermediateDirectories: true)
        let onSpanDAC = makeOutputTabScene(dir: sub2, mode: .source, spandac: FakeSpanDACOutputs(), speakers: speakers)
        settleOutputTab(onSpanDAC, speakers: 2)
        put(onSpanDAC, on: .speaker(0))
        XCTAssertTrue(onSpanDAC.footerHint.contains("Enter Use MusicTUI"), onSpanDAC.footerHint)

        for scene in [s, bare, onSpanDAC] {
            for width in [100, 60] {
                let text = lines(scene, width: width).joined(separator: "\n") + scene.footerHint
                XCTAssertFalse(text.contains("Music.app"), text)
                XCTAssertFalse(text.contains("MUSIC.APP"), text)
            }
        }
    }

    func testAfterTheSwitchRowsBehaveAsBefore() {
        let starter = FakeMacStarter(installed: true)
        let status = StatusStore()
        let s = scene(mode: .source, data: .accepted, answer: MacAnswer(ready), starter: starter,
                      outputs: FakeSpanDACOutputs([spandacRow(ipad, "Studio iPad", .ready)]), status: status)
        XCTAssertFalse(s.isShowingSwitchScreen)
        XCTAssertTrue(lines(s).contains { $0.contains("1  Studio Mac") && $0.contains("ready") && !$0.contains("switch") })
        XCTAssertTrue(lines(s).contains { $0.contains("2  Studio iPad") && $0.contains("ready") })
        let switched = Finished()
        s.selectModeFinishedForTest = { switched.bump() }
        put(s, on: .spandac(ipad))
        XCTAssertEqual(s.footerHint, "\u{2191}\u{2193} Move   Enter Play here   f Forget   e EQ   v Visualizer")
        _ = s.handle(.enter)
        XCTAssertTrue(wait { switched.count == 1 })
        XCTAssertEqual(modeOnDisk(), .networkSource(ipad))
        put(s, on: .spandacMac)
        _ = s.handle(.enter)
        XCTAssertTrue(wait { switched.count == 2 })
        XCTAssertEqual(modeOnDisk(), .source)
        XCTAssertEqual(starter.anyCalls, 0)
        XCTAssertEqual(data().0, .spandacMac)
    }
}
