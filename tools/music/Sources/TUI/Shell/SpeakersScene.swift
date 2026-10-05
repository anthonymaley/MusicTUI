// tools/music/Sources/TUI/Shell/SpeakersScene.swift
import Foundation
import SystemConfiguration

/// One AirPlay output: its name, whether it's in the active group, and its volume.
struct SpeakerRow {
    let name: String
    var active: Bool
    var volume: Int
    /// Device kind from AppleScript; "computer" is the Mac's own output.
    var kind: String = ""
}

/// Pure mapping from `fetchSpeakerDevices()`'s `[[String:Any]]` to typed rows.
/// Entries missing name/selected/volume are skipped.
func speakerRows(from devices: [[String: Any]]) -> [SpeakerRow] {
    devices.compactMap { d in
        guard let name = d["name"] as? String,
              let active = d["selected"] as? Bool,
              let volume = d["volume"] as? Int else { return nil }
        return SpeakerRow(name: name, active: active, volume: volume,
                          kind: d["kind"] as? String ?? "")
    }
}

// MARK: - The Output tab's rows

/// What the Output tab lists, in order: the SPANDAC section (this Mac first,
/// then SpanDACs on the network), then the MUSICTUI section (speakers, or a
/// stand-in MusicTUI row when there are none), then EQ and Visualizer.
///
/// **Choosing a SpanDAC row IS choosing SpanDAC.** There is no separate
/// "output mode" row any more: the Mac's row is `PlaybackMode.source`, a
/// network row is `.networkSource(sourceID)`, and a speaker (or the stand-in)
/// is the MusicTUI output (`PlaybackMode.musicApp` internally).
///
/// These are the rows the cursor can reach. Before MusicTUI has switched to
/// SpanDAC for music data, the network SpanDACs are drawn but are not rows,
/// and with no SpanDAC on this Mac its row is not either.
enum OutputTabRow: Equatable {
    /// This Mac's own SpanDAC, `PlaybackMode.source`. Always row 1.
    case spandacMac
    /// A SpanDAC on the network, keyed by its `sourceID`, never by its name:
    /// two devices with the same name are two rows.
    case spandac(String)
    /// Stands in for the MusicTUI output when there are no speakers to
    /// list, so it can always be chosen.
    case musicApp
    /// "Stop using SpanDAC for music data": the way back to MusicTUI's own
    /// music data, offered once the person has switched (or while a stored
    /// SpanDAC output waits on the switch).
    case stopUsingSpanDAC
    case speaker(Int)        // index into the SpeakerRow array
    case eqPower
    case eq
    case preset(String)
    case visualizer
}

/// Where "Stop using SpanDAC for music data" sits, if anywhere.
enum StopUsingPlacement: Equatable {
    case none
    /// The last row of the SPANDAC section.
    case endOfSection
    /// The first row of the tab, drawn amber: SpanDAC on this Mac is missing,
    /// not allowed Apple Music, did not start, or a stored SpanDAC output is
    /// waiting on the switch.
    case top
}

func outputTabRows(speakerCount: Int, expanded: Bool, presetNames: [String],
                   spandacIDs: [String] = [], macRow: Bool = true,
                   stopUsing: StopUsingPlacement = .none) -> [OutputTabRow] {
    var rows: [OutputTabRow] = stopUsing == .top ? [.stopUsingSpanDAC] : []
    if macRow { rows.append(.spandacMac) }
    rows += spandacIDs.map { .spandac($0) }
    if stopUsing == .endOfSection { rows.append(.stopUsingSpanDAC) }
    if speakerCount == 0 {
        rows.append(.musicApp)
    } else {
        rows += (0..<speakerCount).map { .speaker($0) }
    }
    rows.append(.eqPower)
    rows.append(.eq)
    if expanded { rows += presetNames.map { .preset($0) } }
    rows.append(.visualizer)
    return rows
}

/// "192 kHz", "44.1 kHz": a sample rate as a person reads it.
func formatSampleRate(_ hz: Int) -> String {
    if hz % 1000 == 0 { return "\(hz / 1000) kHz" }
    var text = String(format: "%.3f", Double(hz) / 1000)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return "\(text) kHz"
}

/// The DAC part of a SpanDAC row and of the top line: `<DAC> · <rate>`, with
/// whatever is unknown left out. Empty unless a DAC is connected.
///
/// The ONE place that decides whether MusicTUI names the DAC: the rows and
/// the top line both come through here.
func spandacOutputDetail(_ output: SourceOutputInfo?) -> String {
    guard let output, output.dac == .connected else { return "" }
    let parts = [output.name, output.maxRateHz.map(formatSampleRate)]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
    return parts.joined(separator: " \u{00B7} ")
}

/// The Mac's own SpanDAC row, from its last status: the network rows get their
/// state from discovery, this one from the scene's own probe.
///
/// An explicit `unknown` DAC is still checking and is never ready, whatever
/// else the status said: unknown must never fall through to playing.
func macSpanDACRowState(readiness: SourceReadiness, output: SourceOutputInfo?) -> SpanDACRowState {
    if readiness == .checking { return .checking }
    switch output?.dac {
    case .unknown?: return .checking
    case .notConnected?: return .notReady("plug in your DAC")
    case .connected?, nil: break
    }
    switch readiness {
    case .ready: return .ready
    case .checking: return .checking
    case .unavailable(let why):
        return readiness == .notRunning ? .unreachable(why) : .notReady(why)
    }
}

/// How a row's words are coloured.
enum OutputRowTone: Equatable {
    case ready, neutral, warning, active
}

/// What a SpanDAC row says beside its name, and the second line it grows while
/// waiting for Allow on the device.
struct SpanDACRowDetail: Equatable {
    let text: String
    let tone: OutputRowTone
    var secondLine: String? = nil
}

/// The words for a device's refusal to pair right now (`busy`, `too_many`,
/// `closed`). Anything else is shown as it came.
func notPairableNowText(_ reason: String) -> String {
    switch reason {
    case "busy": return "pairing with another Mac  try again in a moment"
    case "too_many": return "asked this Mac to wait  try again shortly"
    case "closed": return "not ready to pair  open SpanDAC on it"
    default: return reason
    }
}

/// `m:ss` until `deadline`, never negative.
func minutesSecondsLeft(until deadline: Date, now: Date) -> String {
    let seconds = max(0, Int((deadline.timeIntervalSince(now)).rounded(.up)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Every word a SpanDAC row shows, by state. `device` is the row's name;
/// `isThisMac` is row 1.
func spandacRowDetail(state: SpanDACRowState, output: SourceOutputInfo?, device: String,
                      isThisMac: Bool, now: Date) -> SpanDACRowDetail {
    switch state {
    case .checking:
        return SpanDACRowDetail(text: output?.dac == .unknown ? "checking the DAC" : "checking\u{2026}",
                                tone: .neutral)
    case .ready:
        let dac = spandacOutputDetail(output)
        return SpanDACRowDetail(text: dac.isEmpty ? "ready" : "ready  \(dac)", tone: .ready)
    case .notPaired(let pairable):
        return SpanDACRowDetail(text: pairable ? "not paired  Enter to pair"
                                               : "not paired  open SpanDAC on it to pair",
                                tone: .neutral)
    case .notPairableNow(let reason):
        return SpanDACRowDetail(text: notPairableNowText(reason), tone: .warning)
    case .connecting:
        return SpanDACRowDetail(text: "pairing\u{2026}", tone: .active)
    case .waitingForAllow(let deadline):
        return SpanDACRowDetail(text: "Tap Allow on \(device).  \(minutesSecondsLeft(until: deadline, now: now)) left",
                                tone: .active,
                                secondLine: "It plays there as soon as you allow it. Nothing else to pick.")
    case .forgotten:
        return SpanDACRowDetail(text: "forgot this Mac  Enter to pair again", tone: .warning)
    case .needsRepair:
        return SpanDACRowDetail(text: "pairing broken  Enter to pair again", tone: .warning)
    case .notReady(let why):
        if output?.dac == .notConnected || why == "plug in your DAC" {
            return SpanDACRowDetail(text: isThisMac ? "plug in your DAC  no DAC on this Mac"
                                                    : "plug in your DAC  no DAC on \(device)'s cable",
                                    tone: .warning)
        }
        return SpanDACRowDetail(text: why, tone: .warning)
    case .unreachable(let why):
        return SpanDACRowDetail(text: isThisMac ? "\(why)  open it on this Mac" : "not seen  open SpanDAC on it",
                                tone: .warning)
    case .forgetPrompt:
        return SpanDACRowDetail(text: "forget? y / n", tone: .warning)
    case .needsMacSpanDAC:
        // Compile-only arm (C-SEED-ROW): a later step owns this row's real
        // wording and behaviour.
        return SpanDACRowDetail(text: "needs SpanDAC on this Mac first", tone: .warning)
    }
}

/// The Output tab's top line, after "Playing through": where sound goes now.
/// `problem` is set when the selected SpanDAC cannot play, with its reason;
/// the output does not change because of it (no fallback).
func playingThroughText(mode: PlaybackMode, activeSpeakers: [String], spandacDevice: String,
                        state: SpanDACRowState, output: SourceOutputInfo?, now: Date = Date())
    -> (path: String, problem: String?) {
    let arrow = " \u{2192} "
    guard mode.usesSource else {
        let name = musicTUIOutputName
        return (activeSpeakers.isEmpty ? name : name + arrow + activeSpeakers.joined(separator: ", "), nil)
    }
    var path = "SpanDAC" + arrow + spandacDevice
    if state == .ready {
        let dac = spandacOutputDetail(output)
        if !dac.isEmpty { path += arrow + dac }
        return (path, nil)
    }
    let detail = spandacRowDetail(state: state, output: output, device: spandacDevice,
                                  isThisMac: mode == .source, now: now)
    return (path, detail.tone == .warning ? "not ready  \(detail.text)" : detail.text)
}

/// Visible columns in `text`, with SGR escapes left out.
private func visibleColumns(_ text: String) -> Int {
    var count = 0
    var inEscape = false
    for ch in text {
        if inEscape {
            if ch.isLetter { inEscape = false }
        } else if ch == "\u{1B}" {
            inEscape = true
        } else {
            count += 1
        }
    }
    return count
}

/// What the Output tab needs from the SpanDACs on the network. `SpanDACOutputs`
/// is the production one; a test stands in its own to drive row states.
protocol SpanDACOutputsDriving: AnyObject {
    var onPairedAndReady: ((_ sourceID: String, _ name: String) -> Void)? { get set }
    var awaitingAnswer: Bool { get }
    var isPairing: Bool { get }
    func rows(selected selectedSourceID: String?) -> [SpanDACOutputRow]
    func tick() -> Bool
    func touch()
    func activated()
    func probe(_ sourceID: String)
    func pair(_ sourceID: String)
    @discardableResult func cancel() -> Bool
    func answer(_ yes: Bool)
    func askToForget(_ sourceID: String)
}

extension SpanDACOutputs: SpanDACOutputsDriving {}

final class SpeakersScene: Scene {
    let id: SceneID = .speakers
    let tabTitle = "Output"

    /// Keys for the row under the cursor. The shell adds the tab keys, the
    /// playback globals and `q Quit` around this.
    var footerHint: String {
        if showingSwitchScreen { return SpanDACSwitchCopy.keys }
        if askingStopUsing { return stopUsingSpanDACKeys }
        if spandac?.awaitingAnswer == true { return "y Yes  n No  Esc Cancel" }
        if spandac?.isPairing == true { return "Esc Cancel pairing" }
        let move = "\u{2191}\u{2193} Move"
        let always = "e EQ   v Visualizer"
        let display = displayRows
        let row = display.indices.contains(cursor) ? display[cursor] : nil
        switch row {
        case .spandacMac?:
            guard dataSwitched else {
                // Before the switch, Enter on this Mac's row is about music
                // data: switch, start SpanDAC, or open it for access.
                switch macDataState {
                case .ready: return "\(move)   Enter Switch to SpanDAC   \(always)"
                case .notRunning, .startFailed: return "\(move)   Enter Start SpanDAC   \(always)"
                case .needsAccess: return "\(move)   Enter Open SpanDAC   \(always)"
                default: return "\(move)   \(always)"
                }
            }
            return "\(move)   Enter Play here   \(always)"
        case .stopUsingSpanDAC?:
            return "\(move)   Enter Stop using SpanDAC   \(always)"
        case .spandac?:
            let forget = currentSpanDACRow?.paired == true ? "   f Forget" : ""
            return "\(move)   Enter Play here\(forget)   \(always)"
        case .speaker?:
            let enter = routing.mode.usesSource ? "Enter Use \(musicTUIOutputName)" : "Enter Toggle"
            return "\(move)   \(enter)   \u{2190}\u{2192} Volume   \(always)"
        case .musicApp?:
            return "\(move)   Enter Use \(musicTUIOutputName)   \(always)"
        case .eq?, .preset?:
            return "\(move)   Enter Select   \u{2190}\u{2192} Preset   \(always)"
        case .eqPower?, .visualizer?, nil:
            return "\(move)   Enter Toggle   \(always)"
        }
    }

    private var spandacIDs: [String] { spandacRows.map(\.sourceID) }

    /// The rows the cursor can reach. Before the switch to SpanDAC data the
    /// network SpanDACs are drawn but are not rows, and with no SpanDAC on
    /// this Mac its row is not one either.
    private var displayRows: [OutputTabRow] {
        let switched = dataSwitched
        return outputTabRows(speakerCount: rows.count, expanded: eqExpanded,
                             presetNames: pickerPresetNames, spandacIDs: switched ? spandacIDs : [],
                             macRow: switched || macDataState != .notInstalled,
                             stopUsing: stopUsingPlacement)
    }

    /// Test-only: the rows the cursor can reach, in order.
    var displayRowsForTest: [OutputTabRow] { displayRows }

    /// Test-only: the coordinator this tab switches through.
    var routingForTest: RoutingCoordinator { routing }

    // MARK: Music data: the switch, and the way back

    /// MusicTUI gets its music data from SpanDAC on this Mac: the person
    /// switched. Until then the Mac row is about switching, and SpanDACs on
    /// the network cannot be chosen (the Mac app is a prerequisite).
    private var dataSwitched: Bool { routing.data == .spandacMac }

    /// A stored SpanDAC output waiting on the switch (C-REPAIR): nothing plays
    /// until the person switches or stops using SpanDAC here.
    private var outputBlocked: Bool {
        if case .outputBlocked = routing.selection { return true }
        return false
    }

    /// This Mac's row before the switch.
    private var macDataState: MacDataRowState {
        macDataRowState(readiness: bridgeReadiness, installed: macInstalled,
                        starting: startInFlight, startOutcome: startOutcome)
    }

    /// "Stop using SpanDAC for music data": offered once switched, or while
    /// blocked; at the top, amber, when it is the way out of trouble.
    private var stopUsingPlacement: StopUsingPlacement {
        guard dataSwitched || outputBlocked else { return .none }
        let trouble = outputBlocked
            || macInstalled == false
            || macSpanDACNeedsAccess(bridgeReadiness)
            || startOutcome == .notAuthorized
            || startOutcome == .timedOut
        return trouble ? .top : .endOfSection
    }

    /// The network SpanDAC under the cursor, if the cursor is on one.
    private var currentSpanDACRow: SpanDACOutputRow? {
        let display = displayRows
        guard display.indices.contains(cursor), case .spandac(let id) = display[cursor] else { return nil }
        return spandacRows.first { $0.sourceID == id }
    }

    private let backend: AppleScriptBackend
    private let status: StatusStore
    private let actions: ActionRunner
    private let routing: RoutingCoordinator
    /// How the client is built. Injectable so a test can drive readiness without
    /// a socket; production uses the real one.
    private let makeSourceClient: () -> SourceAppClient
    /// How a SpanDAC on the network is reached, by `spandac_id`. Nil when the
    /// scene was composed without the network (every existing test): a network
    /// target then refuses as not paired rather than reaching for the network.
    private let makeNetworkClient: ((String) -> SourceAppClient)?
    /// SpanDACs on the network: discovery, readiness, pairing, forgetting.
    /// Nil when composed without the network, and then the tab lists none.
    private let spandac: SpanDACOutputsDriving?
    /// The network rows as last drawn; the cursor and keys index into them.
    private var spandacRows: [SpanDACOutputRow] = []
    /// This Mac's name for row 1.
    private let macName: String
    /// Times the Mac row's re-probe and the pairing countdown. Injectable so a
    /// test can step time instead of sleeping; production uses the wall clock.
    private let clock: () -> Date
    /// The three external refreshes `tick()` fires on entry and every 5s.
    /// Injectable so a test can prove it never reaches AppleScript or the real
    /// speaker cache; production uses the real global functions, unchanged.
    private let fetchSpeakers: () throws -> [[String: Any]]
    private let fetchEQ: (AppleScriptBackend) throws -> EQSnapshot
    private let fetchVisualizer: (AppleScriptBackend) throws -> Bool

    /// How often the Mac's row asks again while the tab is shown. CHOSEN
    /// (composer default, not a measurement): 5 s, the same as the network
    /// SpanDACs' re-probe.
    static let macReprobeInterval: TimeInterval = 5

    /// Bridge's own last-reported state. Owned by the main loop and written ONLY
    /// in `tick()`; background work posts to `inboxReadiness` instead.
    private var bridgeReadiness: SourceReadiness = .checking
    /// What the Mac's SpanDAC last said about its DAC; written with
    /// `bridgeReadiness`, by `tick()` only.
    private var macOutput: SourceOutputInfo? = nil
    private let readinessLock = NSLock()
    private var inboxReadiness: (readiness: SourceReadiness, output: SourceOutputInfo?, installed: Bool?)? = nil   // guarded by readinessLock
    private var readinessInFlight = false
    private var lastReadinessKick = Date.distantPast   // clock(), tick()-thread only
    private var lastCountdownSecond = 0                // tick()-thread only
    /// Counts actual probes, so a test can prove how often the tab asks.
    private(set) var readinessProbeCount = 0

    /// Read-only view for tests. `bridgeReadiness` stays private so nothing but
    /// `tick()` can write it.
    var bridgeReadinessForTest: SourceReadiness { bridgeReadiness }

    /// Whether a result has landed in the inbox but not yet been applied. Lets a
    /// test prove the value changes on the DRAIN rather than on arrival.
    var hasPendingReadinessForTest: Bool {
        readinessLock.lock(); defer { readinessLock.unlock() }
        return inboxReadiness != nil
    }

    /// Test-only: fires after selectMode's action body finishes (either branch).
    /// Never read or set by production code.
    var selectModeFinishedForTest: (() -> Void)?

    /// Test-only: fires after a switch-screen answer or a stop-using answer has
    /// run (either outcome). Never read or set by production code.
    var dataActionFinishedForTest: (() -> Void)?

    /// Whether SpanDAC on this Mac is installed (LaunchServices or its socket,
    /// or it answered). Nil until first asked. Written in `tick()` only.
    private var macInstalled: Bool? = nil
    /// The switch screen is up. Main loop only.
    private var showingSwitchScreen = false
    /// The switch screen has shown itself once in this process; after that
    /// only Enter on this Mac's row shows it.
    private var switchScreenAutoShown = false
    /// Enter on "Stop using SpanDAC for music data" asked; y or n answers.
    private var askingStopUsing = false
    /// Why the last "Stop using" could not leave the SpanDAC output.
    private var stopUsingProblem: String? = nil
    /// A start this tab asked for is running, and how the last one ended.
    /// Main loop only; the outcome arrives through `inboxStart`.
    private var startInFlight = false
    private var startOutcome: MacSpanDACStartOutcome? = nil
    private var inboxStart: MacSpanDACStartOutcome? = nil        // guarded by readinessLock
    private var inboxStopProblem: String?? = nil                 // guarded by readinessLock
    /// Whether SpanDAC on this Mac's control socket exists. Injectable so a
    /// test never looks at the real one; with "not running", its absence is
    /// what lets "Stop using" leave a SpanDAC on this Mac that is not there.
    private let macSocketExists: () -> Bool

    /// Test-only: the switch screen is up.
    var isShowingSwitchScreen: Bool { showingSwitchScreen }

    /// Test-only: the speakers as last loaded or toggled.
    var speakerRowsForTest: [SpeakerRow] { rows }

    /// Test-only: lands a Mac status in the inbox exactly as a probe would,
    /// so a test can set the DAC the Mac reports without a socket.
    func deliverMacStatusForTest(readiness: SourceReadiness, output: SourceOutputInfo?) {
        publishReadiness(readiness, output: output)
    }

    /// The pairing Enter started, and the output epoch at that moment: a pair
    /// that comes back ready switches only if nothing switched meanwhile.
    private let pairLock = NSLock()
    private var pendingPair: (sourceID: String, epoch: Int)? = nil   // guarded by pairLock

    private let speakerTargets = TargetAccumulator()
    private let eqTargetLock = NSLock()
    private var eqTarget: String? = nil
    private var rows: [SpeakerRow] = []
    private var cursor = 0
    private var eqState: EQSnapshot? = nil
    private var eqExpanded = false
    private var visualizerOn: Bool? = nil

    // Background refresh, inbox pattern: tick() kicks fetches and drains results.
    // The scene used to load once and never again — devices appearing/vanishing
    // never showed, and a failed optimistic toggle stayed wrong forever.
    private let inboxLock = NSLock()
    private var inbox: [SpeakerRow]? = nil
    private var inboxEQ: EQSnapshot? = nil   // guarded by inboxLock
    private var inboxVis: Bool? = nil        // guarded by inboxLock
    private var fetchInFlight = false                 // tick()-thread only
    private var fetchStartedAt = Date.distantPast     // tick()-thread only
    private var lastFetchKickoff = Date.distantPast   // tick()-thread only
    private var lastTickAt = Date.distantPast         // tick()-thread only
    private var lastMutation = Date.distantPast       // handle()/tick() thread only
    private var everLoaded = false

    init(backend: AppleScriptBackend, status: StatusStore, actions: ActionRunner,
         routing: RoutingCoordinator,
         makeSourceClient: (() -> SourceAppClient)? = nil,
         makeNetworkClient: ((String) -> SourceAppClient)? = nil,
         spandac: SpanDACOutputsDriving? = nil,
         macName: String = SpeakersScene.computerName(),
         clock: @escaping () -> Date = Date.init,
         fetchSpeakers: @escaping () throws -> [[String: Any]] = fetchSpeakerDevices,
         fetchEQ: @escaping (AppleScriptBackend) throws -> EQSnapshot = { try fetchEQSnapshot($0, openWindow: false) },
         fetchVisualizer: @escaping (AppleScriptBackend) throws -> Bool = visualizerStatus,
         macSocketExists: @escaping () -> Bool = {
             FileManager.default.fileExists(atPath: SourceAppStationSearch.socketPath)
         }) {
        self.backend = backend
        self.status = status
        self.actions = actions
        self.routing = routing
        // Nil means the coordinator's Mac client, whose licence cache hears
        // every status this tab reads; a bare `SourceAppClient()` would not.
        self.makeSourceClient = makeSourceClient ?? { routing.client(for: .source) }
        self.makeNetworkClient = makeNetworkClient
        self.spandac = spandac
        self.macName = macName
        self.clock = clock
        self.fetchSpeakers = fetchSpeakers
        self.fetchEQ = fetchEQ
        self.fetchVisualizer = fetchVisualizer
        self.macSocketExists = macSocketExists
        spandac?.onPairedAndReady = { [weak self] id, name in self?.pairedAndReady(id, name: name) }
    }

    /// The Mac's computer name, as row 1 shows it.
    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "This Mac"
    }

    /// Row 1's state, from the Mac's last status.
    private var macRowState: SpanDACRowState {
        macSpanDACRowState(readiness: bridgeReadiness, output: macOutput)
    }

    /// The one way a background result reaches `bridgeReadiness`.
    ///
    /// **The result comes back through the inbox**, not by assignment. The first
    /// version wrote `bridgeReadiness` directly from `ActionRunner`'s background
    /// queue while `render` read it on the main loop — a data race that happened
    /// to be invisible because the write never ran at all.
    private func publishReadiness(_ readiness: SourceReadiness, output: SourceOutputInfo?,
                                  installed: Bool? = nil) {
        readinessLock.lock()
        inboxReadiness = (readiness, output, installed)
        readinessLock.unlock()
    }

    /// One status read of the Mac's SpanDAC: its readiness and its DAC. The
    /// readiness is exactly what `SourceAppClient.readiness()` answers; the
    /// status is read once so the DAC comes from the same answer.
    private static func readMacStatus(_ client: SourceAppClient) -> (SourceReadiness, SourceOutputInfo?) {
        do {
            let status = try client.control.status()
            // Not serving: the licence line is the whole story. Its DAC says
            // nothing a person can use while SpanDAC will not play.
            return (status.readiness, status.licence?.serving == false ? nil : status.output)
        } catch {
            return (SourceReadiness.from(error), nil)
        }
    }

    /// Ask the Mac's SpanDAC how it is, off the input thread, one at a time.
    ///
    /// **Asked on entry and then every `macReprobeInterval` while the tab is
    /// shown**, so a row that could not play turns ready by itself when the
    /// DAC is plugged in or the app opened (the agreed design; this reverses
    /// the earlier "asked on entry only, never a heartbeat" rule). Never while
    /// the tab is hidden: only `tick()` asks, and `tick()` runs only for the
    /// tab on screen.
    private func kickReadinessProbe() {
        guard !readinessInFlight else { return }
        readinessInFlight = true
        readinessProbeCount += 1
        lastReadinessKick = clock()
        let make = makeSourceClient
        let starter = routing.macStarter
        DispatchQueue.global().async { [weak self] in
            let (readiness, output) = Self.readMacStatus(make())
            // Installed: LaunchServices or its socket knows it, or it just
            // answered. Asking never starts it.
            let answered = readiness != .checking && readiness != .notRunning
            self?.publishReadiness(readiness, output: output, installed: answered || starter.isInstalled)
        }
    }

    /// A pairing this tab started came back paired and ready. It plays there
    /// only if the output did not change since Enter was pressed; otherwise
    /// the person is told, and nothing moves.
    private func pairedAndReady(_ sourceID: String, name: String) {
        pairLock.lock()
        let pending = pendingPair
        if pending?.sourceID == sourceID { pendingPair = nil }
        pairLock.unlock()
        guard let pending, pending.sourceID == sourceID else {
            status.post("Paired with \(name). Press Enter to play there.")
            return
        }
        selectMode(.networkSource(sourceID), name: name, onlyIfEpoch: pending.epoch)
    }

    /// Starts SpanDAC on this Mac for a person's Enter: a new attempt, off the
    /// main loop, one at a time. The outcome comes back through the inbox;
    /// on ready the switch screen follows.
    private func startMacSpanDAC() {
        guard !startInFlight else { return }
        startInFlight = true
        startOutcome = nil
        let starter = routing.macStarter
        DispatchQueue.global().async { [weak self] in
            starter.newAttempt()
            let outcome = starter.ensureStarted()
            guard let self else { return }
            self.readinessLock.lock()
            self.inboxStart = outcome
            self.readinessLock.unlock()
        }
    }

    /// Applies a finished start and a stop-using reason. Main loop only.
    private func drainDataInbox() -> Bool {
        readinessLock.lock()
        let start = inboxStart; inboxStart = nil
        let problem = inboxStopProblem; inboxStopProblem = nil
        readinessLock.unlock()
        var changed = false
        if let start {
            startInFlight = false
            changed = true
            if start == .ready {
                startOutcome = nil
                // Ask again now rather than at the next re-probe.
                lastReadinessKick = .distantPast
                if !dataSwitched { showingSwitchScreen = true }
            } else {
                startOutcome = start
            }
        }
        if let problem {
            stopUsingProblem = problem
            changed = true
        }
        return changed
    }

    /// The switch screen's Enter: SpanDAC on this Mac becomes MusicTUI's
    /// music data source. The coordinator re-reads readiness inside its
    /// boundary; music data needs SpanDAC answering and allowed Apple Music,
    /// not a DAC. The output does not change (a stored SpanDAC output that
    /// was waiting becomes live).
    private func acceptSpanDACData() {
        let make = makeSourceClient
        actions.run("SpanDAC") { [weak self] in
            guard let self else { return }
            defer { self.dataActionFinishedForTest?() }
            let result = try self.routing.acceptSpanDACData(readiness: {
                macDataReadiness(Self.readMacStatus(make()).0)
            })
            if case .switched = result { self.status.post(switchedToSpanDACData) }
        }
    }

    /// The switch screen's Esc: "Not now", remembered, so the screen never
    /// shows itself again. Nothing switches.
    private func declineSpanDACData() {
        guard routing.ceremony == .neverShown else { return }
        actions.run("SpanDAC") { [weak self] in
            guard let self else { return }
            defer { self.dataActionFinishedForTest?() }
            try self.routing.declineSpanDACData()
        }
    }

    /// "Stop using SpanDAC for music data", after the person's y. When the
    /// output is a SpanDAC it is left first, through the normal switch: its
    /// pause must be confirmed, except that SpanDAC on this Mac that is not
    /// running (LaunchServices) AND has no socket counts as paused (C-REPAIR).
    /// Then data returns to MusicTUI's own. If the output could not be left,
    /// data still returns and the row says why; the person can try again.
    private func stopUsingSpanDAC() {
        let starter = routing.macStarter
        let socketExists = macSocketExists
        actions.run("SpanDAC") { [weak self] in
            guard let self else { return }
            defer { self.dataActionFinishedForTest?() }
            let client = self.makeSourceClient()
            let clientFor: (PlaybackMode) -> SourceAppClient = { mode in
                guard let id = mode.networkSourceID else { return client }
                return self.makeNetworkClient?(id) ?? .failing(.notPaired)
            }
            let macAbsent = { !starter.isRunning && !socketExists() }
            let result: StopUsingSpanDACResult
            do {
                result = try self.routing.stopUsingSpanDACData(
                    pauseOutgoing: { outgoing in
                        switch outgoing {
                        case .musicApp:
                            return try confirmMusicAppNotPlaying(session: liveMusicAppPauseSession,
                                                                 isRunning: liveMusicAppMayBeRunning)
                        case .source:
                            if (try? confirmBridgeNotPlaying(client.control)) == true { return true }
                            return macAbsent()
                        case .networkSource:
                            return try confirmBridgeNotPlaying(clientFor(outgoing).control)
                        }
                    },
                    dropQueue: { outgoing in
                        switch outgoing {
                        case .musicApp: break
                        case .source:
                            // Nothing to drop in a SpanDAC that is not there.
                            do { try client.control.stop() } catch { if !macAbsent() { throw error } }
                        case .networkSource:
                            try clientFor(outgoing).control.stop()
                        }
                    })
            } catch let error as ActionError {
                self.publishStopProblem(error.message)
                throw error
            }
            switch result {
            case .alreadyOpen:
                self.publishStopProblem(nil)
            case .stopped:
                self.publishStopProblem(nil)
                self.status.post(backToMusicTUIData)
            case .outputStillBlocked(let why):
                self.publishStopProblem(why)
                // The output did not switch: it stays.
                self.status.post(why, error: true, untilStateChange: true)
            }
        }
    }

    private func publishStopProblem(_ problem: String?) {
        readinessLock.lock()
        inboxStopProblem = .some(problem)
        readinessLock.unlock()
    }

    /// Choosing a row. Ruling 12.3's transaction lives in the coordinator:
    /// pause the outgoing player, drop its queue, save, commit — and refuse the
    /// whole switch if any step cannot be confirmed.
    ///
    /// `onlyIfEpoch`: switch only if no other switch committed since that
    /// epoch. Checked on the action queue, where every switch this tab makes
    /// is ordered, so a switch queued before this one is seen.
    private func selectMode(_ target: PlaybackMode, name targetName: String? = nil, onlyIfEpoch: Int? = nil) {
        actions.run("Output") { [weak self] in
            guard let self else { return }
            // Fires on every exit from this closure — including a thrown
            // error from switchMode — so a test waiting on it can never be
            // stranded by the exceptional path.
            defer { self.selectModeFinishedForTest?() }
            if let expected = onlyIfEpoch, self.routing.epoch != expected {
                self.status.post("Paired with \(targetName ?? "SpanDAC"). Press Enter to play there.")
                return
            }
            // Through the injected factory, like the probe. Building a real
            // client here made this path unmockable AND meant a test drove the
            // live app's socket instead of a stub.
            // One client per side of the switch: the incoming output answers
            // readiness, the OUTGOING one is paused and cleared. They differ
            // when the switch is between the Mac's SpanDAC and one on the
            // network, or between two on the network.
            let client = self.makeSourceClient()
            let clientFor: (PlaybackMode) -> SourceAppClient = { mode in
                guard let id = mode.networkSourceID else { return client }
                return self.makeNetworkClient?(id) ?? .failing(.notPaired)
            }
            let incoming = clientFor(target)
            let result = try self.routing.switchMode(
                to: target,
                readiness: { incoming.readiness() },
                pauseOutgoing: { outgoing in
                    switch outgoing {
                    case .musicApp:
                        return try confirmMusicAppNotPlaying(session: liveMusicAppPauseSession,
                                                             isRunning: liveMusicAppMayBeRunning)
                    case .source:
                        return try confirmBridgeNotPlaying(clientFor(outgoing).control)
                    case .networkSource:
                        return try confirmBridgeNotPlaying(clientFor(outgoing).control)
                    }
                },
                dropQueue: { outgoing in
                    switch outgoing {
                    case .musicApp: break   // MusicTUI's own queue, cleared below
                    case .source, .networkSource: try clientFor(outgoing).control.stop()
                    }
                })
            switch result {
            case .alreadyInMode:
                break
            case .switched(let mode):
                // Through the inbox, like every other background result. Writing
                // `bridgeReadiness` here would reinstate the main-loop/background
                // race the inbox exists to remove — and this is the path a
                // successful Enter on Bridge actually takes.
                switch mode {
                case .networkSource(let id):
                    self.spandac?.probe(id)
                    self.status.post("Output: SpanDAC · \(targetName ?? "on the network")")
                case .source, .musicApp:
                    let (readiness, output) = Self.readMacStatus(client)
                    self.publishReadiness(readiness, output: output)
                    self.status.post(mode == .source ? "Output: SpanDAC · \(self.macName)" : "Output: \(musicTUIOutputName)")
                }
            }
        }
    }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false
        // SpanDACs on the network: keep discovery alive while the tab is
        // shown, and redraw the rows when anything behind them moved.
        if let spandac {
            spandac.touch()
            if spandac.tick() || spandacRows.isEmpty {
                let fresh = spandac.rows(selected: routing.mode.networkSourceID)
                if fresh != spandacRows {
                    let cursorID = currentSpanDACRow?.sourceID
                    spandacRows = fresh
                    changed = true
                    // Keep the cursor on the same SpanDAC, by sourceID, when rows move.
                    let display = displayRows
                    if let cursorID, let i = display.firstIndex(of: .spandac(cursorID)) { cursor = i }
                    if cursor >= display.count { cursor = max(0, display.count - 1) }
                }
            }
        }
        // The Mac's status: drained here so the only writer is the main loop.
        readinessLock.lock()
        let freshReadiness = inboxReadiness; inboxReadiness = nil
        readinessLock.unlock()
        if let freshReadiness {
            readinessInFlight = false
            if freshReadiness.readiness != bridgeReadiness || freshReadiness.output != macOutput {
                bridgeReadiness = freshReadiness.readiness
                macOutput = freshReadiness.output
                changed = true
            }
            if let installed = freshReadiness.installed, installed != macInstalled {
                macInstalled = installed
                changed = true
            }
            // A status that reads ready for music data ends a failed start.
            if startOutcome != nil, macDataReadiness(bridgeReadiness) == .ready {
                startOutcome = nil
                changed = true
            }
        }
        if drainDataInbox() { changed = true }
        // The switch screen shows itself ONCE, the first time SpanDAC on this
        // Mac reads ready for music data while the person has never been
        // asked (every install from before the data route included: no
        // migration). After Esc, only Enter on this Mac's row shows it.
        if !switchScreenAutoShown, !dataSwitched, routing.ceremony == .neverShown,
           macDataReadiness(bridgeReadiness) == .ready {
            switchScreenAutoShown = true
            showingSwitchScreen = true
            changed = true
        }
        // Switched meanwhile (another answer landed): nothing left to ask.
        if showingSwitchScreen, dataSwitched {
            showingSwitchScreen = false
            changed = true
        }

        // Apply a landed fetch — unless the user mutated state after it started,
        // in which case it's stale and would briefly revert the optimistic UI.
        inboxLock.lock()
        let fresh = inbox; inbox = nil
        let freshEQ = inboxEQ; inboxEQ = nil
        let freshVis = inboxVis; inboxVis = nil
        inboxLock.unlock()
        if let fresh {
            fetchInFlight = false
            if fetchStartedAt > lastMutation {
                // Keep the cursor on the same speaker, by name, if it was on one.
                let before = displayRows
                var cursorName: String? = nil
                if before.indices.contains(cursor), case .speaker(let i) = before[cursor], rows.indices.contains(i) {
                    cursorName = rows[i].name
                }
                rows = fresh
                everLoaded = true
                let after = displayRows
                if let cursorName, let i = rows.firstIndex(where: { $0.name == cursorName }),
                   let at = after.firstIndex(of: .speaker(i)) {
                    cursor = at
                }
                if cursor >= after.count { cursor = max(0, after.count - 1) }
                changed = true
            }
        }
        if let freshEQ, fetchStartedAt > lastMutation {
            eqState = freshEQ
            changed = true
        }
        if let freshVis, fetchStartedAt > lastMutation {
            visualizerOn = freshVis
            changed = true
        }
        // Refresh on (re)entry — tick only runs while this scene is active, so a
        // gap since the last tick means the user just switched back — and every
        // few seconds while shown. AirPlay enumeration runs off-thread.
        let now = Date()
        let reentered = now.timeIntervalSince(lastTickAt) > 0.5
        lastTickAt = now
        // The Mac's row: on entry, until it has an answer, and then every
        // `macReprobeInterval` while the tab is shown, one probe in flight.
        if reentered || bridgeReadiness == .checking
            || clock().timeIntervalSince(lastReadinessKick) >= Self.macReprobeInterval {
            kickReadinessProbe()
        }
        if reentered { spandac?.activated() }
        // A pairing countdown redraws once a second on its own.
        if spandacRows.contains(where: { if case .waitingForAllow = $0.state { return true }; return false }) {
            let second = Int(clock().timeIntervalSinceReferenceDate)
            if second != lastCountdownSecond { lastCountdownSecond = second; changed = true }
        }
        // A wedged enumeration (osascript hung on a dying device) used to set
        // fetchInFlight forever and kill refreshes for the session; treat a
        // long-overdue fetch as dead and allow a new kickoff. (The backend
        // watchdog also terminates the hung osascript itself.)
        if fetchInFlight, now.timeIntervalSince(fetchStartedAt) > 30 {
            fetchInFlight = false
        }
        if !fetchInFlight, reentered || now.timeIntervalSince(lastFetchKickoff) > 5 {
            fetchInFlight = true
            fetchStartedAt = now
            lastFetchKickoff = now
            let fetchSpeakers = self.fetchSpeakers
            let fetchEQ = self.fetchEQ
            let fetchVisualizer = self.fetchVisualizer
            DispatchQueue.global().async { [weak self] in
                let result = speakerRows(from: (try? fetchSpeakers()) ?? [])
                let backend = self?.backend ?? AppleScriptBackend()
                // openWindow: false — the poll must never pop the Equalizer
                // window (it steals focus, e.g. from the visualizer).
                let eq = try? fetchEQ(backend)
                let vis = try? fetchVisualizer(backend)
                guard let self else { return }
                self.inboxLock.lock()
                self.inbox = result
                self.inboxEQ = eq
                self.inboxVis = vis
                self.inboxLock.unlock()
            }
        }
        return changed
    }

    private var pickerPresetNames: [String] {
        let installed = eqState?.presets ?? []
        return VenuePack.names + installed.filter { VenuePack.preset(named: $0) == nil }
    }

    /// The selected SpanDAC's name, state and DAC, for the top line.
    private var selectedSpanDAC: (name: String, state: SpanDACRowState, output: SourceOutputInfo?) {
        switch routing.mode {
        case .networkSource(let id):
            if let row = spandacRows.first(where: { $0.sourceID == id }) { return (row.name, row.state, row.output) }
            return ("SpanDAC", .checking, nil)
        case .source, .musicApp:
            return (macName, macRowState, macOutput)
        }
    }

    // MARK: Render

    private func dot(_ on: Bool, dimmed: Bool = false) -> String {
        if on && !dimmed { return "\(ANSICode.lime)\u{25CF}\(ANSICode.reset)" }
        return "\(ANSICode.dim)\(on ? "\u{25CF}" : "\u{25CB}")\(ANSICode.reset)"
    }

    private func toneColor(_ tone: OutputRowTone) -> String {
        switch tone {
        case .ready: return ANSICode.lime
        case .neutral: return ANSICode.dim
        case .warning: return ANSICode.amber
        case .active: return ANSICode.brightWhite
        }
    }

    /// "Stop using SpanDAC for music data", the question it asks, and why
    /// the last answer could not leave a SpanDAC output, in lines of at most
    /// `width` columns.
    private func stopUsingLines(isCursor: Bool, prominent: Bool, width: Int) -> [String] {
        var lines: [String] = []
        if askingStopUsing {
            var ask = wrapForOutputTab(stopUsingSpanDACAsk, width: width)
            let keys = stopUsingSpanDACKeys
            if let last = ask.last, last.count + 2 + keys.count <= width {
                ask[ask.count - 1] = last + "  " + keys
            } else {
                ask.append(keys)
            }
            lines += ask.map { "\(ANSICode.bold)\(ANSICode.brightWhite)\($0)\(ANSICode.reset)" }
        } else {
            let text = truncText(stopUsingSpanDACText, to: width)
            // Amber when prominent, under the cursor too (inverse amber).
            let tone = prominent ? ANSICode.amber : ""
            lines.append("\(isCursor ? ANSICode.inverse : "")\(tone)\(text)\(ANSICode.reset)")
        }
        if let problem = stopUsingProblem {
            lines += wrapForOutputTab(problem, width: width).map { "\(ANSICode.amber)\($0)\(ANSICode.reset)" }
        }
        return lines
    }

    /// The one-time "Switch MusicTUI to SpanDAC?" screen: the whole tab, in a
    /// box from 60 columns, every sentence whole (wrapped, never cut). The
    /// keys are the footer's.
    private func renderSwitchScreen(frame: ShellFrame) -> String {
        var out = ""
        let bottom = frame.bodyY + frame.bodyHeight - 1
        var y = frame.bodyY
        let boxed = frame.width >= 60
        let boxWidth = max(0, frame.width - 4)
        let textW = boxed ? max(0, boxWidth - 6) : max(0, frame.width - 4)

        func line(_ content: String) {
            guard y <= bottom else { return }
            if boxed {
                let pad = max(0, textW - visibleColumns(content))
                out += ANSICode.moveTo(row: y, col: 3) + "\(ANSICode.cyan)\u{2502}\(ANSICode.reset)  "
                    + content + String(repeating: " ", count: pad)
                    + "  \(ANSICode.cyan)\u{2502}\(ANSICode.reset)"
            } else {
                out += ANSICode.moveTo(row: y, col: 3) + content
            }
            y += 1
        }
        func rule(_ left: String, _ right: String) {
            guard boxed, y <= bottom else { return }
            out += ANSICode.moveTo(row: y, col: 3)
                + "\(ANSICode.cyan)\(left)\(String(repeating: "\u{2500}", count: max(0, boxWidth - 2)))\(right)\(ANSICode.reset)"
            y += 1
        }

        rule("\u{256D}", "\u{256E}")
        if boxed { line("") }
        for piece in wrapForOutputTab(SpanDACSwitchCopy.eyebrow, width: textW) {
            line("\(ANSICode.bold)\(ANSICode.cyan)\(piece)\(ANSICode.reset)")
        }
        line("")
        for piece in wrapForOutputTab(SpanDACSwitchCopy.question, width: textW) {
            line("\(ANSICode.bold)\(ANSICode.brightWhite)\(piece)\(ANSICode.reset)")
        }
        line("")
        for point in SpanDACSwitchCopy.points {
            for (i, piece) in wrapForOutputTab(point, width: textW).enumerated() {
                guard i == 0, let sign = piece.first else { line(piece); continue }
                let color = sign == "+" ? ANSICode.lime : ANSICode.cyan
                line("\(color)\(sign)\(ANSICode.reset)\(piece.dropFirst())")
            }
        }
        // The keys sit in the box, under the promise, as on the agreed canvas:
        // in the footer alone they were fifteen lines away and read as absent
        // (Anthony, 2026-09-28 22:05).
        line("")
        let enter = "\(ANSICode.inverse) \(SpanDACSwitchCopy.enterKey) \(ANSICode.reset)"
        let esc = "\(ANSICode.dim)\(SpanDACSwitchCopy.escKey)\(ANSICode.reset)"
        // One line when it fits (26 + 6 + 12 visible columns), else two.
        if textW >= SpanDACSwitchCopy.enterKey.count + 2 + 6 + SpanDACSwitchCopy.escKey.count {
            line(enter + "      " + esc)
        } else {
            line(enter)
            line(esc)
        }
        if boxed { line("") }
        rule("\u{2570}", "\u{256F}")
        return out
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let bottom = frame.bodyY + frame.bodyHeight - 1
        if showingSwitchScreen { return out + renderSwitchScreen(frame: frame) }
        let now = clock()
        var y = frame.bodyY
        // Codex review 102: a SpanDAC is PLAYING only when the effective
        // output is one. The section's "switches back" hint and its dimming
        // follow that; row selection marks and Enter still follow the stored
        // choice (`routing.mode`).
        let spanDACPlaying = routing.effectiveOutput.usesSource
        let switched = dataSwitched
        let blocked = outputBlocked
        let noMacBox = !switched && macDataState == .notInstalled

        // Top line: where sound goes now.
        do {
            let label = "Playing through"
            let room = max(0, frame.width - 4 - label.count - 2)
            let selected = selectedSpanDAC
            // Where the sound IS (Codex review 101, blocking 1): after a
            // replacement that is MusicTUI, though the device row stays the
            // stored, selected one.
            let (path, problem) = playingThroughText(mode: routing.effectiveOutput,
                                                     activeSpeakers: rows.filter(\.active).map(\.name),
                                                     spandacDevice: selected.name, state: selected.state,
                                                     output: selected.output, now: now)
            // A stored SpanDAC output waiting on the switch plays nothing
            // (C-REPAIR); the line says so rather than the row's state.
            let problemNow = blocked ? waitingOnTheSwitchToSpanDAC : problem
            let pathText = truncText(path, to: room)
            var line = "\(ANSICode.dim)\(label)\(ANSICode.reset)  \(ANSICode.bold)\(ANSICode.brightWhite)\(pathText)\(ANSICode.reset)"
            let left = room - pathText.count - 3
            if let problem = problemNow, left > 1 {
                let color = problem.hasPrefix("not ready") ? ANSICode.amber : ANSICode.dim
                line += "   \(color)\(truncText(problem, to: left))\(ANSICode.reset)"
            }
            out += ANSICode.moveTo(row: y, col: 3) + line
            y += 2
        }

        let display = displayRows
        let placement = stopUsingPlacement

        // "Stop using SpanDAC for music data" leads the tab, amber, when it
        // is the way out of trouble.
        if placement == .top, y <= bottom {
            let isCursor = display.first == .stopUsingSpanDAC && cursor == 0
            for line in stopUsingLines(isCursor: isCursor, prominent: true, width: max(0, frame.width - 4)) {
                guard y <= bottom else { break }
                out += ANSICode.moveTo(row: y, col: 3) + line
                y += 1
            }
            y += 1
        }

        let nameW = 18
        let barW = 16

        // The SPANDAC section: boxed from 60 columns, a plain heading below.
        let boxed = frame.width >= 60
        let boxWidth = max(0, frame.width - 4)
        let contentCol = boxed ? 5 : 3
        let contentW = boxed ? max(0, boxWidth - 4) : max(0, frame.width - 4)
        let spandacCount = 1 + spandacRows.count
        let numberW = String(spandacCount).count
        // Names as wide as the longest one (at most `nameW`), so a narrow
        // terminal keeps room for what the row says.
        let spandacNameW = min(nameW, max(4, ([macName] + spandacRows.map(\.name)).map(\.count).max() ?? 0))

        // No SpanDAC on this Mac: the section is a dashed box that says so.
        let side = noMacBox ? "\u{254E}" : "\u{2502}"
        let (topLeft, topRight, bottomLeft, bottomRight, rule) = noMacBox
            ? ("\u{250C}", "\u{2510}", "\u{2514}", "\u{2518}", "\u{254C}")
            : ("\u{256D}", "\u{256E}", "\u{2570}", "\u{256F}", "\u{2500}")

        /// A line inside the box (or bare when not boxed), padded to the box.
        func sectionLine(_ content: String) -> String {
            guard boxed else { return ANSICode.moveTo(row: y, col: contentCol) + content }
            let pad = max(0, contentW - visibleColumns(content))
            return ANSICode.moveTo(row: y, col: 3) + "\(ANSICode.cyan)\(side)\(ANSICode.reset) "
                + content + String(repeating: " ", count: pad)
                + " \(ANSICode.cyan)\(side)\(ANSICode.reset)"
        }

        if boxed, y <= bottom {
            out += ANSICode.moveTo(row: y, col: 3)
                + "\(ANSICode.cyan)\(topLeft)\(String(repeating: rule, count: max(0, boxWidth - 2)))\(topRight)\(ANSICode.reset)"
            y += 1
        }
        if noMacBox {
            if y <= bottom {
                let note = truncText(NoMacSpanDACCopy.note, to: max(0, contentW - 9))
                out += sectionLine("\(ANSICode.bold)\(ANSICode.cyan)\(NoMacSpanDACCopy.title)\(ANSICode.reset)  \(ANSICode.amber)\(note)\(ANSICode.reset)")
                y += 1
            }
            for sentence in [NoMacSpanDACCopy.pitch, NoMacSpanDACCopy.install] {
                for line in wrapForOutputTab(sentence, width: contentW) {
                    guard y <= bottom else { break }
                    out += sectionLine(sentence == NoMacSpanDACCopy.pitch ? line : "\(ANSICode.dim)\(line)\(ANSICode.reset)")
                    y += 1
                }
            }
            // SpanDACs seen on the network: drawn, never chosen.
            if !spandacRows.isEmpty, y <= bottom {
                out += sectionLine("")
                y += 1
            }
            for row in spandacRows {
                let detail = needsMacSpanDACDetail(macMissing: true)
                for (i, line) in wrapForOutputTab("\(row.name)  \(detail.text)", width: max(0, contentW - 2)).enumerated() {
                    guard y <= bottom else { break }
                    let lead = i == 0 ? "\(dot(false)) " : "  "
                    out += sectionLine(lead + "\(ANSICode.dim)\(line)\(ANSICode.reset)")
                    y += 1
                }
            }
        } else if y <= bottom {
            let subtitle = "lossless to your DAC \u{00B7} pick one and it plays there"
            let header = "\(ANSICode.bold)\(ANSICode.cyan)SPANDAC\(ANSICode.reset)  \(ANSICode.dim)\(truncText(subtitle, to: max(0, contentW - 9)))\(ANSICode.reset)"
            out += sectionLine(header)
            y += 1
        }

        var number = 0
        var spandacSectionOpen = true
        func closeSpanDACSection() {
            guard spandacSectionOpen else { return }
            spandacSectionOpen = false
            if boxed, y <= bottom {
                out += ANSICode.moveTo(row: y, col: 3)
                    + "\(ANSICode.cyan)\(bottomLeft)\(String(repeating: rule, count: max(0, boxWidth - 2)))\(bottomRight)\(ANSICode.reset)"
                y += 1
            }
            y += 1   // a blank line before MUSICTUI
            guard y <= bottom else { return }
            let title = musicTUIOutputName.uppercased()
            let subtitle = "this Mac and AirPlay speakers"
            let hint = "Enter on a speaker switches back"
            let room = max(0, frame.width - 4 - (title.count + 2))
            var header = "\(ANSICode.bold)\(ANSICode.cyan)\(title)\(ANSICode.reset)  \(ANSICode.dim)\(truncText(subtitle, to: room))\(ANSICode.reset)"
            // While a SpanDAC plays, say how to come back: beside the heading
            // when it fits, on its own line when it does not.
            let hintInline = spanDACPlaying && subtitle.count + 3 + hint.count <= room
            if hintInline { header += "   \(ANSICode.dim)\(hint)\(ANSICode.reset)" }
            out += ANSICode.moveTo(row: y, col: 3) + header
            y += 1
            if spanDACPlaying, !hintInline, y <= bottom {
                out += ANSICode.moveTo(row: y, col: 3)
                    + "\(ANSICode.dim)\(truncText(hint, to: max(0, frame.width - 4)))\(ANSICode.reset)"
                y += 1
            }
        }

        /// One SpanDAC row: a drawn number (a label, not a key), the name,
        /// and every word from `spandacRowDetail`.
        func spandacLine(isCursor: Bool, selected: Bool, name: String, detail: SpanDACRowDetail) {
            guard y <= bottom else { return }
            number += 1
            let label = String(repeating: " ", count: max(0, numberW - String(number).count)) + String(number)
            let title = truncText(name, to: spandacNameW)
            let padTitle = title + String(repeating: " ", count: max(0, spandacNameW - title.count))
            let titleStr = isCursor ? "\(ANSICode.inverse)\(padTitle)\(ANSICode.reset)"
                                    : (selected ? "\(ANSICode.brightWhite)\(padTitle)\(ANSICode.reset)" : padTitle)
            let lead = 1 + 1 + numberW + 2 + spandacNameW + 2
            let room = max(0, contentW - lead)
            let text = truncText(detail.text, to: room)
            out += sectionLine("\(dot(selected)) \(ANSICode.dim)\(label)\(ANSICode.reset)  \(titleStr)  \(toneColor(detail.tone))\(text)\(ANSICode.reset)")
            y += 1
            if let second = detail.secondLine, y <= bottom {
                out += sectionLine(String(repeating: " ", count: lead)
                                   + "\(ANSICode.dim)\(truncText(second, to: room))\(ANSICode.reset)")
                y += 1
            }
        }

        for (dispIdx, dispRow) in display.enumerated() {
            guard y <= bottom else { break }
            let isCursor = dispIdx == cursor
            switch dispRow {
            case .spandacMac:
                let detail: SpanDACRowDetail
                if !switched {
                    detail = macDataRowDetail(macDataState)
                } else if macInstalled == false {
                    detail = macDataRowDetail(.notInstalled)
                } else {
                    detail = spandacRowDetail(state: macRowState, output: macOutput, device: macName,
                                              isThisMac: true, now: now)
                }
                spandacLine(isCursor: isCursor, selected: routing.mode == .source && !blocked, name: macName, detail: detail)
                // Before the switch, SpanDACs on the network are drawn under
                // this Mac but cannot be chosen (C-SEED-ROW).
                if !switched {
                    for row in spandacRows {
                        spandacLine(isCursor: false, selected: false, name: row.name,
                                    detail: needsMacSpanDACDetail(macMissing: false))
                    }
                }

            case .stopUsingSpanDAC:
                guard placement == .endOfSection else { break }
                for line in stopUsingLines(isCursor: isCursor, prominent: false, width: max(0, contentW - 2)) {
                    guard y <= bottom else { break }
                    out += sectionLine("  " + line)
                    y += 1
                }

            case .spandac(let id):
                guard let row = spandacRows.first(where: { $0.sourceID == id }) else { break }
                let detail = spandacRowDetail(state: row.state, output: row.output, device: row.name,
                                              isThisMac: false, now: now)
                spandacLine(isCursor: isCursor, selected: routing.mode == .networkSource(id), name: row.name, detail: detail)

            case .musicApp:
                closeSpanDACSection()
                guard y <= bottom else { break }
                let selected = routing.mode == .musicApp
                let title = musicTUIOutputName
                let padTitle = title + String(repeating: " ", count: max(0, nameW - title.count))
                let titleStr = isCursor ? "\(ANSICode.inverse)\(padTitle)\(ANSICode.reset)"
                                        : (selected ? "\(ANSICode.brightWhite)\(padTitle)\(ANSICode.reset)"
                                                    : "\(ANSICode.dim)\(padTitle)\(ANSICode.reset)")
                let note = "this Mac  \u{00B7}  " + (everLoaded ? "no AirPlay speakers found" : "loading speakers\u{2026}")
                out += ANSICode.moveTo(row: y, col: 3)
                out += "  \(dot(selected)) \(titleStr) \(ANSICode.dim)\(truncText(note, to: max(0, frame.width - 4 - 4 - nameW - 1)))\(ANSICode.reset)"
                y += 1

            case .speaker(let i):
                closeSpanDACSection()
                guard y <= bottom else { break }
                let row = rows[i]
                out += ANSICode.moveTo(row: y, col: 3)
                let marker = " "
                let name = truncText(row.name, to: nameW)
                let padName = name + String(repeating: " ", count: max(0, nameW - name.count))
                // Same selection language as the other tabs: inverse-video cursor.
                // While a SpanDAC plays, the whole section is dimmed.
                let nameStr: String
                if isCursor {
                    nameStr = "\(ANSICode.inverse)\(padName)\(ANSICode.reset)"
                } else if row.active && !spanDACPlaying {
                    nameStr = "\(ANSICode.brightWhite)\(padName)\(ANSICode.reset)"
                } else {
                    nameStr = "\(ANSICode.dim)\(padName)\(ANSICode.reset)"
                }
                let bar: String
                if spanDACPlaying {
                    let filled = Int(Double(max(0, min(100, row.volume))) / 100.0 * Double(barW))
                    bar = "\(ANSICode.dim)\(String(repeating: "\u{2588}", count: filled))\(String(repeating: "\u{2591}", count: barW - filled))\(ANSICode.reset)"
                } else {
                    bar = meterBar(value: row.volume, width: barW)
                }
                let vol = String(format: "%3d", row.volume)
                let volStr = spanDACPlaying ? "\(ANSICode.dim)\(vol)\(ANSICode.reset)" : vol
                out += "\(marker) \(dot(row.active, dimmed: spanDACPlaying)) \(nameStr) \(bar) \(volStr)"
                y += 1

            case .eqPower:
                closeSpanDACSection()
                // Blank line before the EQ block when space allows.
                if y + 1 <= bottom {
                    y += 1
                }
                guard y <= bottom else { break }
                out += ANSICode.moveTo(row: y, col: 3)
                let on = eqState?.enabled == true
                let label = "EQ  \(on ? "on" : "off")"
                let padLabel = label + String(repeating: " ", count: max(0, nameW - label.count))
                let labelStr: String
                if isCursor {
                    labelStr = "\(ANSICode.inverse)\(padLabel)\(ANSICode.reset)"
                } else if on {
                    labelStr = "\(ANSICode.brightWhite)\(padLabel)\(ANSICode.reset)"
                } else {
                    labelStr = padLabel
                }
                out += "  \(dot(on)) \(labelStr)"
                y += 1

            case .eq:
                guard y <= bottom else { break }
                out += ANSICode.moveTo(row: y, col: 3)
                let presetName = truncText(eqState?.current ?? "none", to: nameW - 4)
                let label = "Preset  \(presetName)"
                let padLabel = label + String(repeating: " ", count: max(0, nameW + 4 - label.count))
                let labelStr: String
                if isCursor {
                    labelStr = "\(ANSICode.inverse)\(padLabel)\(ANSICode.reset)"
                } else {
                    labelStr = padLabel
                }
                out += "    \(labelStr)"
                y += 1

            case .preset(let name):
                guard y <= bottom else { break }
                out += ANSICode.moveTo(row: y, col: 5)
                let isCurrent = eqState?.current == name
                let bullet = isCurrent ? "\u{25CF}" : " "
                let truncName = truncText(name, to: nameW)
                let padName = truncName + String(repeating: " ", count: max(0, nameW - truncName.count))
                let nameStr: String
                if isCursor {
                    nameStr = "\(ANSICode.inverse)\(padName)\(ANSICode.reset)"
                } else if isCurrent {
                    nameStr = "\(ANSICode.brightWhite)\(padName)\(ANSICode.reset)"
                } else {
                    nameStr = "\(ANSICode.dim)\(padName)\(ANSICode.reset)"
                }
                out += "\(bullet) \(nameStr)"
                y += 1

            case .visualizer:
                // Blank line before the visualizer row when space allows.
                if y + 1 <= bottom {
                    y += 1
                }
                guard y <= bottom else { break }
                out += ANSICode.moveTo(row: y, col: 3)
                let on = visualizerOn == true
                let label = "Visualizer  \(on ? "on" : "off")"
                let padLabel = label + String(repeating: " ", count: max(0, nameW + 4 - label.count))
                let labelStr: String
                if isCursor {
                    labelStr = "\(ANSICode.inverse)\(padLabel)\(ANSICode.reset)"
                } else if on {
                    labelStr = "\(ANSICode.brightWhite)\(padLabel)\(ANSICode.reset)"
                } else {
                    labelStr = padLabel
                }
                out += "  \(dot(on)) \(labelStr)"
                y += 1
            }
        }

        // No in-body key hints — the scene-aware footer already shows them.
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // The switch screen and the stop-using question come before
        // everything, before the vim aliases: they answer only their keys.
        if showingSwitchScreen {
            switch key {
            case .enter:
                showingSwitchScreen = false
                acceptSpanDACData()
                return .redraw
            case .escape:
                showingSwitchScreen = false
                declineSpanDACData()
                return .redraw
            default:
                return .none
            }
        }
        if askingStopUsing {
            switch key {
            case .char("y"), .char("Y"):
                askingStopUsing = false
                stopUsingSpanDAC()
                return .redraw
            case .char("n"), .char("N"), .escape:
                askingStopUsing = false
                return .redraw
            default:
                return .none
            }
        }
        // Rows can come and go with the data axis; keep the cursor on one.
        if cursor >= displayRows.count { cursor = max(0, displayRows.count - 1) }

        // Vim aliases: j/k/h/l/g/G/ctrl-d/ctrl-u — this scene has no raw-text
        // capture mode, so the full list-scene set is safe everywhere.
        let key = vimAlias(key, listScene: true)
        let displayRows = self.displayRows
        let rowCount = displayRows.count   // always ≥ 1 (the Mac's row is always present)

        // A y/n question from forgetting, and Esc on a pairing, come first.
        if let spandac {
            if case .escape = key, spandac.cancel() {
                pairLock.lock(); pendingPair = nil; pairLock.unlock()
                return .redraw
            }
            if spandac.awaitingAnswer {
                switch key {
                case .char("y"), .char("Y"): spandac.answer(true); return .redraw
                case .char("n"), .char("N"): spandac.answer(false); return .redraw
                default: break
                }
            }
            if case .char("f") = key, let row = currentSpanDACRow, row.paired {
                spandac.askToForget(row.sourceID)
                return .redraw
            }
        }

        // Collapse the picker when Escape is pressed; otherwise pop.
        if case .escape = key {
            if eqExpanded {
                eqExpanded = false
                // Clamp cursor: it may have been on a preset row that no longer exists.
                let collapsed = self.displayRows
                if cursor >= collapsed.count { cursor = max(0, collapsed.count - 1) }
                return .redraw
            }
            return .pop
        }

        switch key {
        case .char("e"), .char("E"):
            toggleEQ()
            return .redraw
        case .char("v"), .char("V"):
            toggleVisualizer()
            return .redraw
        case .up:
            cursor = max(0, cursor - 1); return .redraw
        case .down:
            cursor = min(rowCount - 1, cursor + 1); return .redraw
        case .pageUp:
            cursor = max(0, cursor - 5); return .redraw
        case .pageDown:
            cursor = min(rowCount - 1, cursor + 5); return .redraw
        case .home:
            cursor = 0; return .redraw
        case .end:
            cursor = rowCount - 1; return .redraw
        case .enter:
            let currentRow = displayRows.indices.contains(cursor) ? displayRows[cursor] : nil
            switch currentRow {
            case .spandacMac:
                // Before the switch, this row is about music data (C-CEREMONY):
                // Enter asks to switch, starts SpanDAC, or opens it for
                // access. Only ever on this keypress, never by itself.
                if !dataSwitched {
                    switch macDataState {
                    case .ready:
                        showingSwitchScreen = true
                        return .redraw
                    case .notRunning, .startFailed:
                        startMacSpanDAC()
                        return .redraw
                    case .needsAccess:
                        let starter = routing.macStarter
                        DispatchQueue.global().async { starter.bringForward() }
                        return .redraw
                    default:
                        return .none
                    }
                }
                // Only a ready Mac row plays; any other state says why on the
                // row itself, so Enter does nothing (no switch, no toast).
                guard macRowState == .ready else { return .none }
                selectMode(.source, name: macName)
                return .redraw
            case .stopUsingSpanDAC:
                // Asks first; nothing happens until y.
                askingStopUsing = true
                return .redraw
            case .spandac(let id):
                // Never before the switch: SpanDAC on this Mac comes first.
                guard dataSwitched,
                      let spandac, let row = spandacRows.first(where: { $0.sourceID == id }) else { return .none }
                switch row.state {
                case .ready:
                    selectMode(.networkSource(id), name: row.name)
                    return .redraw
                case .notPaired(pairable: true), .forgotten, .needsRepair, .notPairableNow:
                    // Pair first; it plays there once paired AND ready, and
                    // only if the output did not change meanwhile. A device
                    // that just refused gets one more try per Enter; pairing
                    // itself does nothing unless the device still invites it.
                    guard !spandac.isPairing else { return .none }
                    pairLock.lock(); pendingPair = (id, routing.epoch); pairLock.unlock()
                    spandac.pair(id)
                    return .redraw
                default:
                    return .none
                }
            case .musicApp:
                guard routing.mode != .musicApp else { return .none }
                selectMode(.musicApp)
                return .redraw
            case .speaker(let i):
                // While a SpanDAC plays, Enter on a speaker only switches back
                // to the MusicTUI output: one keypress, one change (composer
                // default).
                if routing.mode.usesSource {
                    selectMode(.musicApp)
                    return .redraw
                }
                rows[i].active.toggle()
                lastMutation = Date()
                setSelected(rows[i])
                return .redraw
            case .eqPower:
                toggleEQ()
                return .redraw
            case .eq:
                eqExpanded.toggle()
                // Clamp after collapse.
                if !eqExpanded {
                    let collapsed = self.displayRows
                    if cursor >= collapsed.count { cursor = max(0, collapsed.count - 1) }
                }
                return .redraw
            case .preset(let name):
                selectEQPreset(name)
                return .redraw
            case .visualizer:
                toggleVisualizer()
                return .redraw
            case nil:
                return .none
            }
        case .left:
            let currentRow = displayRows.indices.contains(cursor) ? displayRows[cursor] : nil
            switch currentRow {
            case .speaker(let i):
                rows[i].volume = max(0, rows[i].volume - 5)
                lastMutation = Date()
                setVolume(rows[i])
                return .redraw
            case .eq:
                let names = pickerPresetNames
                guard !names.isEmpty else { return .none }
                let idx = eqState?.current.flatMap { n in names.firstIndex(of: n) } ?? -1
                let newIdx = idx == -1 ? names.count - 1 : (idx - 1 + names.count) % names.count
                selectEQPreset(names[newIdx])
                return .redraw
            default:
                return .none
            }
        case .right:
            let currentRow = displayRows.indices.contains(cursor) ? displayRows[cursor] : nil
            switch currentRow {
            case .speaker(let i):
                rows[i].volume = min(100, rows[i].volume + 5)
                lastMutation = Date()
                setVolume(rows[i])
                return .redraw
            case .eq:
                let names = pickerPresetNames
                guard !names.isEmpty else { return .none }
                let idx = eqState?.current.flatMap { n in names.firstIndex(of: n) } ?? -1
                let newIdx = (idx + 1) % names.count
                selectEQPreset(names[newIdx])
                return .redraw
            default:
                return .none
            }
        default:
            return .none
        }
    }

    // MARK: AppleScript (each its own call — never batched, per the -50 rule).
    // On the action queue: the optimistic UI updates instantly; a failure posts
    // a toast and the next background refresh reconciles the real state.

    private func setSelected(_ row: SpeakerRow) {
        let esc = escapeAppleScriptString(row.name)
        let name = row.name
        let active = row.active
        actions.run("Speaker") {
            // Verify additions only while playing — and pay the Bonjour
            // resolver cost only then (paused toggles defer to the play
            // path, same ordering as the speaker commands). Baseline BEFORE
            // the write so establishment shows as churn. The computer row is
            // local output — no AirPlay session exists to verify.
            let playing = active && row.kind != "computer" && playerIsPlaying(backend: self.backend)
            let verifier = RouteVerifier()
            let ip = playing ? verifier.resolver.resolveIP(forSpeaker: name) : nil
            let baseline = ip.flatMap { try? verifier.snapshot(ip: $0) }
            try require((try? syncRun { try await self.backend.runMusic("set selected of AirPlay device \"\(esc)\" to \(active)") }) != nil,
                        "Couldn't \(active ? "add" : "remove") '\(name)'.")
            // Short timeout — this runs on the serial action queue and must
            // not stall the shell. No heal here: the toast points at the
            // existing recovery paths instead (a 2×1.5s heal dance would
            // freeze the action queue).
            if playing, let ip = ip, let baseline = baseline {
                // A netstat read error is NOT evidence the route is fine — the
                // old `?? true` silently passed on it, while the CLI path treats
                // the same error as not-verified. Post an honest "couldn't check"
                // instead of a false all-clear.
                let verdict: RouteVerdict
                do {
                    verdict = try verifier.verifyEstablishment(ip: ip, baseline: baseline, timeout: 3.0)
                } catch {
                    throw ActionError(message: "Couldn't verify '\(name)' route (network read failed).")
                }
                try require(verdict.verified,
                            "'\(name)' selected but route NOT verified — try: music speaker wake")
            }
        }
    }
    private func setVolume(_ row: SpeakerRow) {
        // Coalesced per speaker: holding an arrow applies only the final target.
        let esc = escapeAppleScriptString(row.name)
        let name = row.name
        speakerTargets.set(name, row.volume)
        actions.run("Volume") {
            guard let v = self.speakerTargets.take(name) else { return }
            try require((try? syncRun { try await self.backend.runMusic("set sound volume of AirPlay device \"\(esc)\" to \(v)") }) != nil,
                        "Couldn't set '\(name)' volume.")
        }
    }
    /// EQ on/off — shared by the power row (Enter) and the 'e' shortcut.
    /// eqSetEnabled is a check-then-click, so rapid toggles stay idempotent.
    private func toggleEQ() {
        let on = !(eqState?.enabled ?? false)
        if eqState == nil { eqState = EQSnapshot(enabled: on, current: nil, presets: []) }
        else { eqState?.enabled = on }
        lastMutation = Date()
        actions.run("EQ") {
            try require((try? eqSetEnabled(self.backend, on)) != nil,
                        "Couldn't turn EQ \(on ? "on" : "off").")
        }
    }

    /// Music's on-screen visualizer on/off. visualizerSetEnabled reads then
    /// clicks only if needed, so repeated toggles stay idempotent. Turning it
    /// on brings Music to the front (the visuals render in Music's window).
    private func toggleVisualizer() {
        let on = !(visualizerOn ?? false)
        visualizerOn = on
        lastMutation = Date()
        actions.run("Visualizer") {
            try require((try? visualizerSetEnabled(self.backend, on)) != nil,
                        "Couldn't turn visualizer \(on ? "on" : "off").")
        }
    }

    private func selectEQPreset(_ name: String) {
        if eqState == nil { eqState = EQSnapshot(enabled: true, current: name, presets: []) }
        eqState?.current = name
        eqState?.enabled = true
        lastMutation = Date()
        eqTargetLock.lock(); eqTarget = name; eqTargetLock.unlock()
        actions.run("EQ") {
            self.eqTargetLock.lock()
            let target = self.eqTarget; self.eqTarget = nil
            self.eqTargetLock.unlock()
            guard let target else { return }
            if let venue = VenuePack.preset(named: target) {
                try require((try? eqEnsurePreset(self.backend, preset: venue)) != nil,
                            "Couldn't create preset '\(target)'.")
            }
            try require((try? eqSetCurrent(self.backend, name: target)) != nil,
                        "Couldn't select preset '\(target)'.")
            try require((try? eqSetEnabled(self.backend, true)) != nil,
                        "Couldn't enable EQ.")
        }
    }
}

/// Pause Bridge and confirm, from its own status, that it is not playing.
///
/// **Only positive evidence counts:** a reported paused, stopped or idle
/// status. `notRunning` is NOT that — it also covers a failed write to a live
/// app that may still be playing, and trusting it could leave both players
/// going (rule 4, DoD 8).
///
/// **A refused pause is not itself a verdict.** An idle Bridge answers
/// `slice.pause` with "did not reach paused within 3s", because there is
/// nothing to pause (found 2026-09-22: the Output tab could not get back to
/// Music.app after any stop or a fresh launch). So the status is read whatever
/// the pause said, and that reading decides. A status read that fails still
/// throws, and the switch still refuses.
func confirmBridgeNotPlaying(_ control: SourceControlling) throws -> Bool {
    try? control.pause()
    let playback = try control.status().playback
    return playback == "paused" || playback == "stopped" || playback == "idle"
}
