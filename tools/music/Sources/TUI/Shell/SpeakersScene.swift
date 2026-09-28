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

// MARK: - The previous layout (no longer drawn)

/// The Output tab's rows as they were before the SPANDAC section: two output
/// mode rows, then network SpanDACs, then speakers.
///
/// **Not drawn any more.** The scene draws `OutputTabRow` instead. This stays,
/// unchanged, only because a test outside the scene's own tests still pins
/// it; delete it together with that test.
enum SpeakersDisplayRow: Equatable {
    case mode(PlaybackMode)
    case spandac(String)
    case speaker(Int)        // index into the SpeakerRow array
    case eqPower
    case eq
    case preset(String)
    case visualizer
}

/// See `SpeakersDisplayRow`: the previous layout, no longer drawn.
func speakersDisplayRows(speakerCount: Int, expanded: Bool,
                         presetNames: [String],
                         showModes: Bool = true,
                         spandacIDs: [String] = []) -> [SpeakersDisplayRow] {
    var rows: [SpeakersDisplayRow] = showModes ? [.mode(.musicApp), .mode(.source)] : []
    if showModes { rows += spandacIDs.map { .spandac($0) } }
    rows += (0..<speakerCount).map { .speaker($0) }
    rows.append(.eqPower)
    rows.append(.eq)
    if expanded { rows += presetNames.map { .preset($0) } }
    rows.append(.visualizer)
    return rows
}

// MARK: - The Output tab's rows

/// What the Output tab lists, in order: the SPANDAC section (this Mac first,
/// then SpanDACs on the network), then the MUSIC.APP section (speakers, or a
/// stand-in Music.app row when there are none), then EQ and Visualizer.
///
/// **Choosing a SpanDAC row IS choosing SpanDAC.** There is no separate
/// "output mode" row any more: the Mac's row is `PlaybackMode.source`, a
/// network row is `.networkSource(sourceID)`, and a speaker (or the stand-in)
/// is Music.app.
enum OutputTabRow: Equatable {
    /// This Mac's own SpanDAC, `PlaybackMode.source`. Always row 1.
    case spandacMac
    /// A SpanDAC on the network, keyed by its `sourceID`, never by its name:
    /// two devices with the same name are two rows.
    case spandac(String)
    /// Stands in for Music.app when there are no speakers to list, so
    /// Music.app can always be chosen.
    case musicApp
    case speaker(Int)        // index into the SpeakerRow array
    case eqPower
    case eq
    case preset(String)
    case visualizer
}

func outputTabRows(speakerCount: Int, expanded: Bool, presetNames: [String],
                   spandacIDs: [String] = []) -> [OutputTabRow] {
    var rows: [OutputTabRow] = [.spandacMac]
    rows += spandacIDs.map { .spandac($0) }
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
        return (activeSpeakers.isEmpty ? "Music.app" : "Music.app" + arrow + activeSpeakers.joined(separator: ", "), nil)
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
        if spandac?.awaitingAnswer == true { return "y Yes  n No  Esc Cancel" }
        if spandac?.isPairing == true { return "Esc Cancel pairing" }
        let move = "\u{2191}\u{2193} Move"
        let always = "e EQ   v Visualizer"
        let display = displayRows
        let row = display.indices.contains(cursor) ? display[cursor] : nil
        switch row {
        case .spandacMac?:
            return "\(move)   Enter Play here   \(always)"
        case .spandac?:
            let forget = currentSpanDACRow?.paired == true ? "   f Forget" : ""
            return "\(move)   Enter Play here\(forget)   \(always)"
        case .speaker?:
            let enter = routing.mode.usesSource ? "Enter Use Music.app" : "Enter Toggle"
            return "\(move)   \(enter)   \u{2190}\u{2192} Volume   \(always)"
        case .musicApp?:
            return "\(move)   Enter Use Music.app   \(always)"
        case .eq?, .preset?:
            return "\(move)   Enter Select   \u{2190}\u{2192} Preset   \(always)"
        case .eqPower?, .visualizer?, nil:
            return "\(move)   Enter Toggle   \(always)"
        }
    }

    private var spandacIDs: [String] { spandacRows.map(\.sourceID) }

    private var displayRows: [OutputTabRow] {
        outputTabRows(speakerCount: rows.count, expanded: eqExpanded,
                      presetNames: pickerPresetNames, spandacIDs: spandacIDs)
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
    private var inboxReadiness: (readiness: SourceReadiness, output: SourceOutputInfo?)? = nil   // guarded by readinessLock
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
         makeSourceClient: @escaping () -> SourceAppClient = { SourceAppClient() },
         makeNetworkClient: ((String) -> SourceAppClient)? = nil,
         spandac: SpanDACOutputsDriving? = nil,
         macName: String = SpeakersScene.computerName(),
         clock: @escaping () -> Date = Date.init,
         fetchSpeakers: @escaping () throws -> [[String: Any]] = fetchSpeakerDevices,
         fetchEQ: @escaping (AppleScriptBackend) throws -> EQSnapshot = { try fetchEQSnapshot($0, openWindow: false) },
         fetchVisualizer: @escaping (AppleScriptBackend) throws -> Bool = visualizerStatus) {
        self.backend = backend
        self.status = status
        self.actions = actions
        self.routing = routing
        self.makeSourceClient = makeSourceClient
        self.makeNetworkClient = makeNetworkClient
        self.spandac = spandac
        self.macName = macName
        self.clock = clock
        self.fetchSpeakers = fetchSpeakers
        self.fetchEQ = fetchEQ
        self.fetchVisualizer = fetchVisualizer
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
    private func publishReadiness(_ readiness: SourceReadiness, output: SourceOutputInfo?) {
        readinessLock.lock()
        inboxReadiness = (readiness, output)
        readinessLock.unlock()
    }

    /// One status read of the Mac's SpanDAC: its readiness and its DAC. The
    /// readiness is exactly what `SourceAppClient.readiness()` answers; the
    /// status is read once so the DAC comes from the same answer.
    private static func readMacStatus(_ client: SourceAppClient) -> (SourceReadiness, SourceOutputInfo?) {
        do {
            let status = try client.control.status()
            return (status.readiness, status.output)
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
        DispatchQueue.global().async { [weak self] in
            let (readiness, output) = Self.readMacStatus(make())
            self?.publishReadiness(readiness, output: output)
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
                    self.status.post(mode == .source ? "Output: SpanDAC · \(self.macName)" : "Output: Music.app")
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

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let bottom = frame.bodyY + frame.bodyHeight - 1
        let now = clock()
        var y = frame.bodyY
        let spanDACSelected = routing.mode.usesSource

        // Top line: where sound goes now.
        do {
            let label = "Playing through"
            let room = max(0, frame.width - 4 - label.count - 2)
            let selected = selectedSpanDAC
            let (path, problem) = playingThroughText(mode: routing.mode,
                                                     activeSpeakers: rows.filter(\.active).map(\.name),
                                                     spandacDevice: selected.name, state: selected.state,
                                                     output: selected.output, now: now)
            let pathText = truncText(path, to: room)
            var line = "\(ANSICode.dim)\(label)\(ANSICode.reset)  \(ANSICode.bold)\(ANSICode.brightWhite)\(pathText)\(ANSICode.reset)"
            let left = room - pathText.count - 3
            if let problem, left > 1 {
                let color = problem.hasPrefix("not ready") ? ANSICode.amber : ANSICode.dim
                line += "   \(color)\(truncText(problem, to: left))\(ANSICode.reset)"
            }
            out += ANSICode.moveTo(row: y, col: 3) + line
            y += 2
        }

        let display = displayRows
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

        /// A line inside the box (or bare when not boxed), padded to the box.
        func sectionLine(_ content: String) -> String {
            guard boxed else { return ANSICode.moveTo(row: y, col: contentCol) + content }
            let pad = max(0, contentW - visibleColumns(content))
            return ANSICode.moveTo(row: y, col: 3) + "\(ANSICode.cyan)\u{2502}\(ANSICode.reset) "
                + content + String(repeating: " ", count: pad)
                + " \(ANSICode.cyan)\u{2502}\(ANSICode.reset)"
        }

        if boxed, y <= bottom {
            out += ANSICode.moveTo(row: y, col: 3)
                + "\(ANSICode.cyan)\u{256D}\(String(repeating: "\u{2500}", count: max(0, boxWidth - 2)))\u{256E}\(ANSICode.reset)"
            y += 1
        }
        if y <= bottom {
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
                    + "\(ANSICode.cyan)\u{2570}\(String(repeating: "\u{2500}", count: max(0, boxWidth - 2)))\u{256F}\(ANSICode.reset)"
                y += 1
            }
            y += 1   // a blank line before MUSIC.APP
            guard y <= bottom else { return }
            let subtitle = "this Mac and AirPlay speakers"
            let hint = "Enter on a speaker switches back"
            let room = max(0, frame.width - 4 - "MUSIC.APP  ".count)
            var header = "\(ANSICode.bold)\(ANSICode.cyan)MUSIC.APP\(ANSICode.reset)  \(ANSICode.dim)\(truncText(subtitle, to: room))\(ANSICode.reset)"
            // While a SpanDAC plays, say how to come back: beside the heading
            // when it fits, on its own line when it does not.
            let hintInline = spanDACSelected && subtitle.count + 3 + hint.count <= room
            if hintInline { header += "   \(ANSICode.dim)\(hint)\(ANSICode.reset)" }
            out += ANSICode.moveTo(row: y, col: 3) + header
            y += 1
            if spanDACSelected, !hintInline, y <= bottom {
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
                let detail = spandacRowDetail(state: macRowState, output: macOutput, device: macName,
                                              isThisMac: true, now: now)
                spandacLine(isCursor: isCursor, selected: routing.mode == .source, name: macName, detail: detail)

            case .spandac(let id):
                guard let row = spandacRows.first(where: { $0.sourceID == id }) else { break }
                let detail = spandacRowDetail(state: row.state, output: row.output, device: row.name,
                                              isThisMac: false, now: now)
                spandacLine(isCursor: isCursor, selected: routing.mode == .networkSource(id), name: row.name, detail: detail)

            case .musicApp:
                closeSpanDACSection()
                guard y <= bottom else { break }
                let selected = routing.mode == .musicApp
                let title = "Music.app"
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
                } else if row.active && !spanDACSelected {
                    nameStr = "\(ANSICode.brightWhite)\(padName)\(ANSICode.reset)"
                } else {
                    nameStr = "\(ANSICode.dim)\(padName)\(ANSICode.reset)"
                }
                let bar: String
                if spanDACSelected {
                    let filled = Int(Double(max(0, min(100, row.volume))) / 100.0 * Double(barW))
                    bar = "\(ANSICode.dim)\(String(repeating: "\u{2588}", count: filled))\(String(repeating: "\u{2591}", count: barW - filled))\(ANSICode.reset)"
                } else {
                    bar = meterBar(value: row.volume, width: barW)
                }
                let vol = String(format: "%3d", row.volume)
                let volStr = spanDACSelected ? "\(ANSICode.dim)\(vol)\(ANSICode.reset)" : vol
                out += "\(marker) \(dot(row.active, dimmed: spanDACSelected)) \(nameStr) \(bar) \(volStr)"
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
                // Only a ready Mac row plays; any other state says why on the
                // row itself, so Enter does nothing (no switch, no toast).
                guard macRowState == .ready else { return .none }
                selectMode(.source, name: macName)
                return .redraw
            case .spandac(let id):
                guard let spandac, let row = spandacRows.first(where: { $0.sourceID == id }) else { return .none }
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
                // to Music.app: one keypress, one change (composer default).
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
