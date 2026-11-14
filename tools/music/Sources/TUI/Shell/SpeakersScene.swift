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
    /// Set only on the Mac's own row when its macOS volume is not known: the
    /// row then shows no level (never Music's unrelated number) and its arrows
    /// write nothing. Nil means `volume` is the macOS output volume.
    var macVolumeUnavailable: MacVolumeUnavailable? = nil

    /// The Mac's own output: its volume is the macOS output volume, which is
    /// what you hear (Music's `sound volume` for it was inaudible on the
    /// laptop, 2026-11-01).
    var isMacOutput: Bool { kind == "computer" }
}

/// Why the Mac's own row has no volume to show or set.
enum MacVolumeUnavailable: Equatable {
    /// `output volume` is missing value: an output with no software volume
    /// (some DACs, HDMI).
    case noControl
    /// The read failed, answered something outside 0...100, or never ran.
    case unreadable

    /// Drawn where the bar and number would be.
    var note: String {
        switch self {
        case .noControl: return "no volume control"
        case .unreadable: return "volume unknown"
        }
    }

    /// Posted when an arrow is pressed on the row.
    var notice: String {
        switch self {
        case .noControl: return "This Mac's output has no volume control; use the device's own."
        case .unreadable: return "Couldn't read this Mac's volume; try again in a moment."
        }
    }
}

/// Pure mapping from the speaker list read's `[[String:Any]]` to typed rows.
/// Entries missing name/selected/volume are skipped. The Mac's own row takes
/// the macOS output volume (`outputVolume`); without a known one it is marked
/// unavailable, never left showing Music's number for the device.
func speakerRows(from devices: [[String: Any]]) -> [SpeakerRow] {
    devices.compactMap { d in
        guard let name = d["name"] as? String,
              let active = d["selected"] as? Bool,
              let volume = d["volume"] as? Int else { return nil }
        var row = SpeakerRow(name: name, active: active, volume: volume,
                             kind: d["kind"] as? String ?? "")
        if row.isMacOutput {
            if let system = d["outputVolume"] as? Int, (0...100).contains(system) {
                row.volume = system
            } else if d["outputVolume"] as? String == "missing" {
                row.macVolumeUnavailable = .noControl
            } else {
                row.macVolumeUnavailable = .unreadable
            }
        }
        return row
    }
}

/// Clip the Output tab's positioned lines to a viewport and translate their
/// terminal coordinates. Output's selectable rows can each occupy several
/// lines, so scrolling by a count of model rows would lose the cursor.
func outputViewport(_ drawing: String, bodyY: Int, height: Int, focusY: Int, inset: Int = 0) -> String {
    // `inset` lines at the top are pinned (drawn by the caller); the logical
    // drawing scrolls in the lines below them.
    guard height - inset > 0 else { return "" }
    let shift = max(0, focusY + inset - (bodyY + height - 1))
    let regex = try! NSRegularExpression(pattern: "\u{1B}\\[([0-9]+);([0-9]+)H")
    let ns = drawing as NSString
    let matches = regex.matches(in: drawing, range: NSRange(location: 0, length: ns.length))
    var result = ""
    for (index, match) in matches.enumerated() {
        guard let row = Int(ns.substring(with: match.range(at: 1))),
              let col = Int(ns.substring(with: match.range(at: 2))) else { continue }
        let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
        let from = match.range.location + match.range.length
        let translated = row - shift + inset
        guard translated >= bodyY + inset, translated < bodyY + height else { continue }
        result += ANSICode.moveTo(row: translated, col: col)
        result += ns.substring(with: NSRange(location: from, length: end - from))
    }
    return result
}

// MARK: - The Output tab's rows

/// What the Output tab lists, in order: the SPANDAC section (this Mac first,
/// then SpanDACs on the network), then the MUSICTUI section (speakers, or a
/// stand-in MusicTUI row when there are none), then EQ. (The Visualizer row
/// was removed 2026-11-01: Music draws it only in its own window.)
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
    /// The row the highlight was on when a list update took it away: a
    /// speaker that left the AirPlay list, or the stand-in the first list
    /// replaced. It carries the name it had, never an index into the speaker
    /// array, acts on no key, and goes the moment the person moves (Codex
    /// round 3, 5c2219a8: a kept row number landed on a row they never picked,
    /// and every row acts on Enter).
    case held(String)
    case eqPower
    case eq
    case preset(String)
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

extension OutputTabRow {
    /// Speaker rows are keyed by position, so the same case can name a
    /// different speaker after the list changes; callers match those by name.
    var isSpeaker: Bool { if case .speaker = self { return true }; return false }
    var isHeld: Bool { if case .held = self { return true }; return false }
}

func outputTabRows(speakerCount: Int, expanded: Bool, presetNames: [String],
                   spandacIDs: [String] = [], macRow: Bool = true,
                   stopUsing: StopUsingPlacement = .none,
                   held: (name: String, slot: Int)? = nil) -> [OutputTabRow] {
    var rows: [OutputTabRow] = stopUsing == .top ? [.stopUsingSpanDAC] : []
    if macRow { rows.append(.spandacMac) }
    rows += spandacIDs.map { .spandac($0) }
    if stopUsing == .endOfSection { rows.append(.stopUsingSpanDAC) }
    let speakersStart = rows.count
    if speakerCount == 0 {
        rows.append(.musicApp)
    } else {
        rows += (0..<speakerCount).map { .speaker($0) }
    }
    // In the speaker section, where the row it stands for was, as far as the
    // shorter list allows.
    if let held {
        rows.insert(.held(held.name), at: speakersStart + min(max(0, held.slot), speakerCount))
    }
    rows.append(.eqPower)
    rows.append(.eq)
    if expanded { rows += presetNames.map { .preset($0) } }
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
    case .notConnected? where output?.switchable != true: return .notReady("plug in your DAC")
    // A DAC that is plugged in but not the sound output (`switchable`) is
    // selectable: choosing it makes it the Mac's output. It is as ready as
    // `readiness` says, no more.
    case .notConnected?, .connected?, nil: break
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
        if isThisMac, let output, output.dac == .notConnected, output.switchable {
            let rate = output.maxRateHz.map(formatSampleRate)
            let name = [output.name, rate].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            return SpanDACRowDetail(text: "\(name.isEmpty ? "your DAC" : name)  select to make it the Mac's output",
                                    tone: .neutral)
        }
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
        if askingStopUsing || askingLeave != nil { return stopUsingSpanDACKeys }
        if spandac?.awaitingAnswer == true { return "y Yes  n No  Esc Cancel" }
        if spandac?.isPairing == true { return "Esc Cancel pairing" }
        let move = "\u{2191}\u{2193} Move"
        let always = "e EQ"
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
        case .speaker(let i)?:
            let enter = routing.mode.usesSource ? "Enter Use \(musicTUIOutputName)" : "Enter Toggle"
            // The arrows are offered only where the coordinator would run them,
            // and only on a speaker that is on: Music has no volume of its own
            // for one that is off (`speakerIsOn`), nor on the Mac's row while
            // its macOS volume is not known (`speakerVolumeSettable`).
            let on = rows.indices.contains(i) && rows[i].active && rows[i].macVolumeUnavailable == nil
            let volume = routing.refusal(for: .volume) == nil && on ? "   \u{2190}\u{2192} Volume" : ""
            return "\(move)   \(enter)\(volume)   \(always)"
        case .musicApp?:
            return "\(move)   Enter Use \(musicTUIOutputName)   \(always)"
        case .held?:
            return "\(move)   \(always)"
        case .eq?, .preset?:
            return "\(move)   Enter Select   \u{2190}\u{2192} Preset   \(always)"
        case .eqPower?, nil:
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
                             stopUsing: stopUsingPlacement,
                             held: held.map { ($0.name, $0.slot) })
    }

    /// The held row owns the highlight: rows coming or going above it (a
    /// SpanDAC appearing, the Mac row, a data switch) must not move the
    /// highlight off it onto a row the person never picked.
    private func anchorHeld() {
        guard held != nil else { return }
        if let i = displayRows.firstIndex(where: \.isHeld) { cursor = i } else { held = nil }
    }

    /// Test-only: the rows the cursor can reach, in order.
    var displayRowsForTest: [OutputTabRow] { displayRows }
    /// Test-only: the row the cursor is on.
    var cursorRowForTest: OutputTabRow? {
        let d = displayRows
        return d.indices.contains(cursor) ? d[cursor] : nil
    }

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
        macDataRowState(readiness: bridgeDataReadiness, installed: macInstalled,
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
    private let fetchNow: () -> Date
    private let fetchSpeakers: () throws -> [[String: Any]]
    private let fetchEQ: (AppleScriptBackend) throws -> EQSnapshot
    private let routePlaying: (AppleScriptBackend) -> Bool
    private let makeRouteVerifier: () -> RouteVerifier

    /// How often the Mac's row asks again while the tab is shown. CHOSEN
    /// (composer default, not a measurement): 5 s, the same as the network
    /// SpanDACs' re-probe.
    static let macReprobeInterval: TimeInterval = 5

    /// Bridge's own last-reported state. Owned by the main loop and written ONLY
    /// in `tick()`; background work posts to `inboxReadiness` instead.
    private var bridgeReadiness: SourceReadiness = .checking
    /// The same status read for music DATA (`SourceStatus.dataReadiness`): the
    /// DAC and the player are the output's concern, never the data's. Written
    /// with `bridgeReadiness`, by `tick()` only.
    private var bridgeDataReadiness: SourceReadiness = .checking
    /// What the Mac's SpanDAC last said about its DAC; written with
    /// `bridgeReadiness`, by `tick()` only.
    private var macOutput: SourceOutputInfo? = nil
    private let readinessLock = NSLock()
    private var inboxReadiness: (readiness: SourceReadiness, data: SourceReadiness,
                                 output: SourceOutputInfo?, installed: Bool?)? = nil   // guarded by readinessLock
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
    /// Why SpanDAC could not make its DAC the Mac's sound output on the last
    /// Enter (`slice.useDAC` refused), shown on the Mac row while that DAC is
    /// still switchable. Main loop only; arrives through `inboxOutputProblem`
    /// (`.some(nil)` clears it).
    private var macOutputProblem: String? = nil
    private var inboxOutputProblem: String?? = nil               // guarded by readinessLock
    /// Whether SpanDAC on this Mac's control socket exists. Injectable so a
    /// test never looks at the real one; with "not running", its absence is
    /// what lets "Stop using" leave a SpanDAC on this Mac that is not there.
    private let macSocketExists: () -> Bool
    /// Where a switch away from MusicTUI's own player confirms it is not
    /// playing. Required at construction; production passes
    /// `liveMusicAppPauseConfirmation`.
    private let confirmMusicAppPaused: () throws -> Bool

    /// Test-only: the switch screen is up.
    var isShowingSwitchScreen: Bool { showingSwitchScreen }

    /// Test-only: the speakers as last loaded or toggled.
    var speakerRowsForTest: [SpeakerRow] { rows }
    var eqStateForTest: EQSnapshot? { eqState }

    /// Test-only: lands a Mac status in the inbox exactly as a probe would,
    /// so a test can set the DAC the Mac reports without a socket.
    func deliverMacStatusForTest(readiness: SourceReadiness, output: SourceOutputInfo?) {
        publishReadiness(readiness, data: macDataReadiness(readiness), output: output)
    }

    /// The pairing Enter started, and the output epoch at that moment: a pair
    /// that comes back ready switches only if nothing switched meanwhile.
    private let pairLock = NSLock()
    private var pendingPair: (sourceID: String, epoch: Int)? = nil   // guarded by pairLock

    private let speakerTargets = TargetAccumulator()
    private let routeCheckLock = NSLock()
    private var routeCheckSerial = 0
    // A slow Music.app or Bonjour read must neither hold the action queue nor
    // spawn an unbounded number of abandoned background reads.
    private let routePreparationSlot = DispatchSemaphore(value: 1)
    var routeCheckFinishedForTest: (() -> Void)?
    private let eqTargetLock = NSLock()
    private var eqTarget: String? = nil
    private var rows: [SpeakerRow] = []
    private var cursor = 0
    /// The held row, while the highlight is on it (see `OutputTabRow.held`).
    /// `slot` is where its row was in the speaker section. Only an accepted
    /// speaker list creates or clears it; a failed or fenced read does neither.
    private struct HeldRow {
        let name: String
        let standIn: Bool
        let slot: Int
        /// Its name was shared, so no later list can say which speaker it was:
        /// it never turns live by name, only by the person moving.
        var ambiguous = false
    }
    private var held: HeldRow? = nil
    private var eqState: EQSnapshot? = nil
    private var eqExpanded = false

    // Background refresh, inbox pattern: tick() kicks fetches and drains results.
    // The scene used to load once and never again — devices appearing/vanishing
    // never showed, and a failed optimistic toggle stayed wrong forever.
    private let inboxLock = NSLock()
    // One job per kickoff, still one in flight at a time, but it posts in two
    // parts: the speaker list the moment its own read lands, then the EQ
    // state. Measured 2026-10-31: the list alone ~0.9 s, the whole
    // job ~2.5 s, and first open said "loading speakers..." for all of it.
    // Each part has its own applied serial, so an older job's part never
    // replaces a newer one's, and each keeps the job's start time for the
    // mutation fence.
    private struct SpeakerPart {
        let serial: Int
        let startedAt: Date
        let speakers: [SpeakerRow]?
    }
    private struct ExtrasPart {
        let serial: Int
        let startedAt: Date
        let eq: EQSnapshot?
    }
    private var speakerInbox: SpeakerPart? = nil       // guarded by inboxLock
    private var extrasInbox: ExtrasPart? = nil         // guarded by inboxLock
    var fetchFinishedForTest: ((Int) -> Void)?
    private var fetchSerial = 0                       // tick()-thread only
    private var appliedSpeakerSerial = 0              // tick()-thread only
    private var appliedExtrasSerial = 0               // tick()-thread only
    private var speakerFetchFailed = false
    private var fetchInFlight = false                 // tick()-thread only
    private var fetchStartedAt = Date.distantPast     // tick()-thread only
    private var lastFetchKickoff = Date.distantPast   // tick()-thread only
    private var lastTickAt = Date.distantPast         // tick()-thread only
    private var lastMutation = Date.distantPast       // handle()/tick() thread only
    private var everLoaded = false

    init(backend: AppleScriptBackend, status: StatusStore, actions: ActionRunner,
         routing: RoutingCoordinator,
         confirmMusicAppPaused: @escaping () throws -> Bool,
         makeSourceClient: (() -> SourceAppClient)? = nil,
         makeNetworkClient: ((String) -> SourceAppClient)? = nil,
         spandac: SpanDACOutputsDriving? = nil,
         macName: String = SpeakersScene.computerName(),
         clock: @escaping () -> Date = Date.init,
         fetchSpeakers: @escaping () throws -> [[String: Any]] = { try fetchOutputTabSpeakerDevices() },
         fetchNow: @escaping () -> Date = Date.init,
         fetchEQ: @escaping (AppleScriptBackend) throws -> EQSnapshot = { try fetchEQSnapshot($0, openWindow: false) },
         routePlaying: @escaping (AppleScriptBackend) -> Bool = playerIsPlaying,
         makeRouteVerifier: @escaping () -> RouteVerifier = { RouteVerifier() },
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
        self.confirmMusicAppPaused = confirmMusicAppPaused
        self.makeNetworkClient = makeNetworkClient
        self.spandac = spandac
        self.macName = macName
        self.clock = clock
        self.fetchSpeakers = fetchSpeakers
        self.fetchNow = fetchNow
        self.fetchEQ = fetchEQ
        self.routePlaying = routePlaying
        self.makeRouteVerifier = makeRouteVerifier
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
    private func publishReadiness(_ readiness: SourceReadiness, data: SourceReadiness,
                                  output: SourceOutputInfo?, installed: Bool? = nil) {
        readinessLock.lock()
        inboxReadiness = (readiness, data, output, installed)
        readinessLock.unlock()
    }

    /// One status read of the Mac's SpanDAC: its readiness and its DAC. The
    /// readiness is exactly what `SourceAppClient.readiness()` answers; the
    /// status is read once so the DAC comes from the same answer.
    private static func readMacStatus(_ client: SourceAppClient)
        -> (readiness: SourceReadiness, data: SourceReadiness, output: SourceOutputInfo?) {
        let read = readMacStatusWithMacOutput(client)
        return (read.readiness, read.data, read.output)
    }

    /// `readMacStatus` plus `macOutput`: the Mac's sound output as the reply
    /// states it, whatever the licence. A not-serving SpanDAC still reports
    /// where the Mac's sound goes, and that fact is what the MusicTUI line
    /// after a switch needs (Codex 2cb5eca0).
    private static func readMacStatusWithMacOutput(_ client: SourceAppClient)
        -> (readiness: SourceReadiness, data: SourceReadiness, output: SourceOutputInfo?, macOutput: SourceOutputInfo?) {
        do {
            let status = try client.control.status()
            // Not serving: the licence line is the whole story. Its DAC says
            // nothing a person can use while SpanDAC will not play.
            return (status.readiness, status.dataReadiness,
                    status.licence?.serving == false ? nil : status.output, status.output)
        } catch {
            let readiness = SourceReadiness.from(error)
            return (readiness, readiness, nil, nil)
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
            let (readiness, data, output) = Self.readMacStatus(make())
            // Installed: LaunchServices or its socket knows it, or it just
            // answered. Asking never starts it.
            let answered = readiness != .checking && readiness != .notRunning
            self?.publishReadiness(readiness, data: data, output: output,
                                   installed: answered || starter.isInstalled)
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
        let outputProblem = inboxOutputProblem; inboxOutputProblem = nil
        readinessLock.unlock()
        var changed = false
        if let outputProblem, outputProblem != macOutputProblem {
            macOutputProblem = outputProblem
            changed = true
        }
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
                macDataReadiness(Self.readMacStatus(make()).data)
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
                            return try self.confirmMusicAppPaused()
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
                let output = self.routing.mode == .musicApp ? Self.readMacStatusWithMacOutput(client).macOutput : nil
                if let notice = macSoundStillOnTheDAC(output) {
                    self.status.post(notice, ttl: macSoundNoticeSeconds)
                } else {
                    self.status.post(backToMusicTUIData)
                }
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

    /// The question "can't reach <device>; leave it?", and what it was asked
    /// about. It is shown only while all of this is still true (see
    /// `drainLeaveQuestion`).
    struct LeaveQuestion: Equatable {
        let outgoing: PlaybackMode
        let target: PlaybackMode
        let targetName: String?
        let device: String
        let epoch: Int
        /// `keyCount` when the Enter that started the switch was handled.
        let keyCount: Int
        /// `activationGeneration` at that Enter: leaving and re-entering the tab
        /// in between makes the question stale.
        let activation: Int
    }
    /// The open question. Main loop only; modal like `askingStopUsing`.
    private var askingLeave: LeaveQuestion? = nil
    private var inboxLeaveQuestion: LeaveQuestion? = nil          // guarded by readinessLock
    /// Keys this scene has handled. A question is dropped when any key was
    /// handled after the Enter it answers. Guarded by `readinessLock`.
    private var handledKeys = 0
    /// Moves every time the tab is left or entered. Guarded by `readinessLock`.
    private var activationGeneration = 0
    /// Whether this tab is the one showing. The shell tells us
    /// (`becameActive`/`resignedActive`); a scene never told is active.
    private var isActive = true

    var askingLeaveForTest: Bool { askingLeave != nil }

    func becameActive() {
        isActive = true
        readinessLock.lock(); activationGeneration += 1; readinessLock.unlock()
    }
    func resignedActive() {
        isActive = false
        askingLeave = nil
        // A question already delivered but not yet drained goes too.
        readinessLock.lock(); activationGeneration += 1; inboxLeaveQuestion = nil; readinessLock.unlock()
    }

    static func leaveQuestionText(_ q: LeaveQuestion) -> String {
        "Can't reach \(q.device). It may still be playing. Leave it and use \(q.targetName ?? "SpanDAC")?"
    }

    private func currentKeyAndActivation() -> (keys: Int, activation: Int) {
        readinessLock.lock(); defer { readinessLock.unlock() }
        return (handledKeys, activationGeneration)
    }

    /// Main loop only: opens a delivered question if it is still current, and
    /// closes an open one that no longer is. A question that went stale is
    /// dropped silently; the person can press Enter again.
    private func drainLeaveQuestion() -> Bool {
        readinessLock.lock()
        let delivered = inboxLeaveQuestion; inboxLeaveQuestion = nil
        let keys = handledKeys, activation = activationGeneration
        readinessLock.unlock()
        var changed = false
        if let open = askingLeave, open.epoch != routing.epoch || open.outgoing != routing.mode {
            askingLeave = nil
            changed = true
        }
        if let q = delivered, isActive, q.epoch == routing.epoch, q.outgoing == routing.mode,
           q.keyCount == keys, q.activation == activation {
            askingLeave = q
            changed = true
        }
        return changed
    }

    /// Whether a failed request to a SpanDAC on the network means NOTHING CAME
    /// BACK. The network client (`SpanDACTLSTransport`, SpanDACLink.swift) throws
    /// only `SourceAppError.link(...)`: `.notFound` (Bonjour did not resolve,
    /// :347), `.asleep` (connect failed or the handshake timed out, :400/:453/
    /// :463) and `.noAnswer` (connected, no reply, :402/:441/:491) are silence.
    /// `.notRunning` and `.timedOut` are the Mac's Unix-socket errors and never
    /// come from it. Everything else is a device or this Mac saying something
    /// (`.notPaired`, `.refused`, `.unsafeCipher`, `.forgotten`, `.unreadable`,
    /// `.notAuthorized`) and keeps the strict rule.
    static func isNoAnswer(_ error: Error) -> Bool {
        guard case SourceAppError.link(let failure) = error else { return false }
        switch failure {
        case .notFound, .asleep, .noAnswer: return true
        default: return false
        }
    }

    /// Choosing a row. Ruling 12.3's transaction lives in the coordinator:
    /// pause the outgoing player, drop its queue, save, commit — and refuse the
    /// whole switch if any step cannot be confirmed.
    ///
    /// `onlyIfEpoch`: switch only if no other switch committed since that
    /// epoch. Checked on the action queue, where every switch this tab makes
    /// is ordered, so a switch queued before this one is seen.
    ///
    /// **One person-chosen exception to "only positive evidence":** when the
    /// outgoing output is a SpanDAC on an iPhone or iPad and it gives NO ANSWER
    /// (`isNoAnswer`), the switch is refused and the tab ASKS, in its body, "Can't
    /// reach <device>. It may still be playing. Leave it and use <target>?"
    /// (`askingLeave`, delivered through the inbox and shown only while it is
    /// still current). The person's y comes back here as `leaveUnreached`: if
    /// that output and epoch are still current and it is still silent, its pause counts
    /// as confirmed and the status line says it may still be playing. A device
    /// that answers, and every other output, keeps the strict rule.
    private func selectMode(_ target: PlaybackMode, name targetName: String? = nil, onlyIfEpoch: Int? = nil,
                            leaveUnreached: (outgoing: PlaybackMode, epoch: Int)? = nil) {
        // Device names by id, read here on the caller's thread (the rows belong
        // to it, not to the action queue); the refusal looks up the id of the
        // output actually being left.
        let deviceNames = Dictionary(spandacRows.map { ($0.sourceID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let (keysAtEnter, activationAtEnter) = currentKeyAndActivation()
        let targetLabel = targetName ?? (target == .musicApp ? musicTUIOutputName : "SpanDAC")
        actions.run("Output") { [weak self] in
            guard let self else { return }
            // Fires on every exit from this closure — including a thrown
            // error from switchMode — so a test waiting on it can never be
            // stranded by the exceptional path.
            defer { self.selectModeFinishedForTest?() }
            let outgoingNow = self.routing.mode, epochNow = self.routing.epoch
            // The person's y holds only for the output and epoch they were ASKED about
            // (recorded with the question, not re-read at the y).
            let leaving = leaveUnreached.map { $0.outgoing == outgoingNow && $0.epoch == epochNow } ?? false
            let outgoingDevice = outgoingNow.networkSourceID.flatMap { deviceNames[$0] } ?? "that device"
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
            var noAnswerRefused = false    // the outgoing network SpanDAC did not answer, and the person has not said to leave it
            var leftUnanswered = false     // it did not answer, and the person said to leave it
            let result: RoutingCoordinator.SwitchResult
            do {
                result = try self.routing.switchMode(
                    to: target,
                    readiness: { incoming.readiness() },
                    pauseOutgoing: { outgoing in
                        switch outgoing {
                        case .musicApp:
                            return try self.confirmMusicAppPaused()
                        case .source:
                            return try confirmBridgeNotPlaying(clientFor(outgoing).control)
                        case .networkSource:
                            do {
                                return try confirmBridgeNotPlaying(clientFor(outgoing).control)
                            } catch where Self.isNoAnswer(error) {
                                if leaving { leftUnanswered = true; return true }
                                noAnswerRefused = true
                                return false
                            }
                        }
                    },
                    dropQueue: { outgoing in
                        switch outgoing {
                        case .musicApp: break   // MusicTUI's own queue, cleared below
                        case .source: try clientFor(outgoing).control.stop()
                        case .networkSource:
                            do { try clientFor(outgoing).control.stop() }
                            catch where leftUnanswered && Self.isNoAnswer(error) { break }
                        }
                    })
            } catch {
                if noAnswerRefused {
                    // No toast: a question, through the inbox, to the main loop.
                    self.readinessLock.lock()
                    self.inboxLeaveQuestion = LeaveQuestion(outgoing: outgoingNow, target: target, targetName: targetLabel,
                                                            device: outgoingDevice, epoch: epochNow, keyCount: keysAtEnter,
                                                            activation: activationAtEnter)
                    self.readinessLock.unlock()
                    return
                }
                // The coordinator's save-failure sentence says the queue was
                // cleared; after an unconfirmed leave it was not.
                if leftUnanswered, let refusal = error as? ActionError,
                   refusal.message.hasPrefix("Couldn't save the playback mode") {
                    throw ActionError(message: "Couldn't save the playback mode; still using SpanDAC on \(outgoingDevice), which could not be reached.")
                }
                throw error
            }
            // After an unconfirmed leave the success line carries the reminder.
            let reminder: (String) -> Bool = { newOutput in
                guard leftUnanswered else { return false }
                self.status.post("Now using \(newOutput). SpanDAC on \(outgoingDevice) may still be playing.",
                                 ttl: macSoundNoticeSeconds)
                return true
            }
            switch result {
            case .alreadyInMode:
                // Enter on the SpanDAC row that is already the output: when its
                // DAC is still not the Mac's output, ask again.
                if target == .source { self.makeMacOutputTheDAC(client) }
            case .switched(let mode):
                // Through the inbox, like every other background result. Writing
                // `bridgeReadiness` here would reinstate the main-loop/background
                // race the inbox exists to remove — and this is the path a
                // successful Enter on Bridge actually takes.
                switch mode {
                case .networkSource(let id):
                    self.spandac?.probe(id)
                    if !reminder("SpanDAC on \(targetName ?? "the network")") {
                        self.status.post("Output: SpanDAC · \(targetName ?? "on the network")")
                    }
                case .source:
                    // The selection is committed and the outgoing player is
                    // paused and cleared (inside `switchMode`): only now may
                    // SpanDAC move the Mac's sound output to its DAC.
                    self.makeMacOutputTheDAC(client)
                    if !reminder("SpanDAC on \(self.macName)") {
                        self.status.post("Output: SpanDAC · \(self.macName)")
                    }
                case .musicApp:
                    let read = Self.readMacStatusWithMacOutput(client)
                    self.publishReadiness(read.readiness, data: read.data, output: read.output)
                    let notice = macSoundStillOnTheDAC(read.macOutput)
                    if leftUnanswered {
                        // Both facts, the reminder first.
                        let head = "Now using \(musicTUIOutputName). SpanDAC on \(outgoingDevice) may still be playing."
                        self.status.post(notice.map { head + " " + $0 } ?? head, ttl: macSoundNoticeSeconds)
                    } else {
                        self.status.post(musicTUIOutputLine(read.macOutput), ttl: notice == nil ? 3 : macSoundNoticeSeconds)
                    }
                }
            }
        }
    }

    /// Reads the Mac's status and, when its DAC is plugged in but not the sound
    /// output (`switchable`) and this SpanDAC lists `output.use_dac`, sends
    /// `slice.useDAC`. Always publishes the freshest status; a refusal is kept
    /// for the row (SpanDAC's own detail, else a fallback). An older SpanDAC
    /// without the capability is left alone: its switch is at the first play.
    /// Runs on the action queue, after the selection is committed.
    private func makeMacOutputTheDAC(_ client: SourceAppClient) {
        var fresh: SourceStatus
        do {
            fresh = try client.control.status()
        } catch {
            let readiness = SourceReadiness.from(error)
            publishReadiness(readiness, data: readiness, output: nil)
            return
        }
        var problem: String? = nil
        if fresh.output?.switchable == true, fresh.offersUseDAC {
            do {
                fresh = try client.control.useDAC() ?? client.control.status()
            } catch let refusal as SourceUseDACRefusal {
                // The refusal carries the status it left behind: publish that,
                // not the one read before the operation.
                if let after = refusal.status { fresh = after }
                problem = (refusal.detail?.isEmpty ?? true) ? Self.notTheMacsSoundOutput : refusal.detail
            } catch SourceAppError.refused(let detail) {
                problem = (detail.isEmpty || detail == "no detail") ? Self.notTheMacsSoundOutput : detail
            } catch {
                problem = Self.notTheMacsSoundOutput
            }
        }
        readinessLock.lock()
        inboxOutputProblem = .some(problem)
        readinessLock.unlock()
        publishReadiness(fresh.readiness, data: fresh.dataReadiness, output: fresh.output)
        if let problem { status.post("SpanDAC is selected, but \(problem)") }
    }

    /// Shown on the Mac row when `slice.useDAC` is refused without a reason.
    static let notTheMacsSoundOutput = "not the Mac's sound output"

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
                    anchorHeld()
                }
            }
        }
        // The Mac's status: drained here so the only writer is the main loop.
        readinessLock.lock()
        let freshReadiness = inboxReadiness; inboxReadiness = nil
        readinessLock.unlock()
        if let freshReadiness {
            readinessInFlight = false
            if freshReadiness.readiness != bridgeReadiness || freshReadiness.data != bridgeDataReadiness
                || freshReadiness.output != macOutput {
                bridgeReadiness = freshReadiness.readiness
                bridgeDataReadiness = freshReadiness.data
                macOutput = freshReadiness.output
                changed = true
            }
            // A refusal belongs to a DAC that is still not the output; once it
            // is, or is gone, the old reason is stale.
            if macOutput?.switchable != true, macOutputProblem != nil {
                macOutputProblem = nil
                changed = true
            }
            if let installed = freshReadiness.installed, installed != macInstalled {
                macInstalled = installed
                changed = true
            }
            // A status that reads ready for music data ends a failed start.
            if startOutcome != nil, macDataReadiness(bridgeDataReadiness) == .ready {
                startOutcome = nil
                changed = true
            }
        }
        if drainDataInbox() { changed = true }
        if drainLeaveQuestion() { changed = true }
        // The switch screen shows itself ONCE, the first time SpanDAC on this
        // Mac reads ready for music data while the person has never been
        // asked (every install from before the data route included: no
        // migration). After Esc, only Enter on this Mac's row shows it.
        if !switchScreenAutoShown, !dataSwitched, routing.ceremony == .neverShown,
           macDataReadiness(bridgeDataReadiness) == .ready {
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
        let freshSpeakers = speakerInbox; speakerInbox = nil
        let freshExtras = extrasInbox; extrasInbox = nil
        inboxLock.unlock()
        // Any part newer than the last one shown lands, even if its kickoff
        // was declared dead and a successor started: requiring the CURRENT
        // serial let a consistently slow EQ read starve the list
        // forever (Codex turn 33). An older part than the one shown never lands.
        if let fresh = freshSpeakers, fresh.serial > appliedSpeakerSerial {
            appliedSpeakerSerial = fresh.serial
            if fresh.startedAt > lastMutation {
                speakerFetchFailed = fresh.speakers == nil
                if let fetchedRows = fresh.speakers {
                    // Keep the cursor on the same speaker, by name, if it was
                    // on one, and on the same row otherwise: a list that grows
                    // or shrinks shifts every row below it. When the row under
                    // it is gone (the speaker left the list, or the first list
                    // replaced the stand-in) it stays on a held row until the
                    // person moves: a kept row number would land on a row they
                    // never picked, and every row acts on Enter.
                    let before = displayRows
                    let beforeRow = before.indices.contains(cursor) ? before[cursor] : nil
                    var target: OutputTabRow? = nil
                    switch beforeRow {
                    case .speaker(let i)? where rows.indices.contains(i):
                        // By name only while the name says which speaker it is:
                        // unique in both lists. A shared name cannot (Codex round
                        // 2, 503eddd2), except across an unchanged list, or
                        // speakers sharing a name would be held every refresh.
                        let name = rows[i].name
                        let oldNames = rows.map(\.name)
                        let newMatches = fetchedRows.indices.filter { fetchedRows[$0].name == name }
                        let sharedBefore = oldNames.filter { $0 == name }.count > 1
                        if oldNames == fetchedRows.map(\.name) {
                            target = .speaker(i)
                        } else if newMatches.count == 1, !sharedBefore {
                            target = .speaker(newMatches[0])
                        } else {
                            held = HeldRow(name: name, standIn: false, slot: i,
                                           ambiguous: sharedBefore || newMatches.count > 1)
                        }
                    case .held?:
                        if let h = held {
                            if h.standIn {
                                if fetchedRows.isEmpty { held = nil; target = .musicApp }
                            } else {
                                // Back under its name: live again. Two by that
                                // name cannot say which one it was (the Music
                                // write is by name too), so it stays held.
                                // Once a list has shown two by that name, no later
                                // list can say which one it was (Codex round 3).
                                let same = fetchedRows.indices.filter { fetchedRows[$0].name == h.name }
                                if same.count > 1 {
                                    held?.ambiguous = true
                                } else if same.count == 1, !h.ambiguous {
                                    held = nil; target = .speaker(same[0])
                                }
                            }
                        }
                    case .musicApp?:
                        // Also where the tab starts with no SpanDAC on this Mac:
                        // still a visible highlight (Codex round 2, 503eddd2).
                        if fetchedRows.isEmpty {
                            target = .musicApp
                        } else {
                            held = HeldRow(name: musicTUIOutputName, standIn: true, slot: 0)
                        }
                    case let row?:
                        target = row
                    case nil:
                        break
                    }
                    rows = fetchedRows
                    everLoaded = true
                    let after = displayRows
                    if held != nil {
                        anchorHeld()
                    } else if let target, let at = after.firstIndex(of: target) {
                        cursor = at
                    }
                    if cursor >= after.count { cursor = max(0, after.count - 1) }
                }
                changed = true
            }
        }
        // The extras part ends the job: only then may the next kickoff start,
        // so one job still owns the reads at a time.
        if let fresh = freshExtras, fresh.serial > appliedExtrasSerial {
            appliedExtrasSerial = fresh.serial
            if fresh.serial == fetchSerial { fetchInFlight = false }
            if fresh.startedAt > lastMutation {
                // Installed presets arriving or leaving change the picker's
                // rows; keep the cursor on the row it was on (Codex round 2:
                // a preset inserted above the cursor's row left Enter on the preset).
                let before = displayRows
                let beforeRow = before.indices.contains(cursor) ? before[cursor] : nil
                if let eq = fresh.eq { eqState = eq }
                let after = displayRows
                if let beforeRow, let at = after.firstIndex(of: beforeRow) {
                    cursor = at
                } else if case .preset? = beforeRow, let at = after.firstIndex(of: .eq) {
                    cursor = at                 // its preset went away: back to the picker
                }
                if cursor >= after.count { cursor = max(0, after.count - 1) }
                changed = true
            }
        }
        // Refresh on (re)entry — tick only runs while this scene is active, so a
        // gap since the last tick means the user just switched back — and every
        // few seconds while shown. AirPlay enumeration runs off-thread.
        let now = fetchNow()
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
            fetchSerial += 1
            let serial = fetchSerial
            lastFetchKickoff = now
            let fetchSpeakers = self.fetchSpeakers
            let fetchEQ = self.fetchEQ
            DispatchQueue.global().async { [weak self] in
                let result = (try? fetchSpeakers()).map(speakerRows(from:))
                // Post the list before the EQ read, which can
                // take longer than the list itself.
                if let self {
                    self.inboxLock.lock()
                    if self.speakerInbox == nil || self.speakerInbox!.serial < serial {
                        self.speakerInbox = SpeakerPart(serial: serial, startedAt: now, speakers: result)
                    }
                    self.inboxLock.unlock()
                }
                let backend = self?.backend ?? AppleScriptBackend()
                // openWindow: false — the poll must never open the Equalizer
                // window, not even off-screen (Anthony's ruling, 2026-11-01).
                let eq = try? fetchEQ(backend)
                guard let self else { return }
                self.inboxLock.lock()
                if self.extrasInbox == nil || self.extrasInbox!.serial < serial {
                    self.extrasInbox = ExtrasPart(serial: serial, startedAt: now, eq: eq)
                }
                self.inboxLock.unlock()
                self.fetchFinishedForTest?(serial)
            }
        }
        anchorHeld()
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
        var clear = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            clear += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        if showingSwitchScreen { return clear + renderSwitchScreen(frame: frame) }
        var out = ""
        // Render a logical full-height list, then show the slice containing the
        // selected row. The terminal itself is only written within bodyHeight.
        let bottom = frame.bodyY + max(1000, displayRows.count * 8 + spandacRows.count * 4)
        var focusY = frame.bodyY
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
            // Where the sound IS (Codex review 101, blocking 1): MusicTUI for
            // SpanDAC on this Mac stored but not serving, though its row stays
            // the stored, selected one.
            let (path, problem) = playingThroughText(mode: routing.effectiveOutput,
                                                     activeSpeakers: rows.filter(\.active).map(\.name),
                                                     spandacDevice: selected.name, state: selected.state,
                                                     output: selected.output, now: now)
            // A stored SpanDAC output waiting on the switch plays nothing
            // (C-REPAIR); the line says so rather than the row's state.
            // The output's own problem keeps this line; a stale speaker list
            // is said on the pinned line instead (Codex turn 35).
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
            if cursor == 0 { focusY = y }
            let isCursor = display.first == .stopUsingSpanDAC && cursor == 0
            for line in stopUsingLines(isCursor: isCursor, prominent: true, width: max(0, frame.width - 4)) {
                guard y <= bottom else { break }
                out += ANSICode.moveTo(row: y, col: 3) + line
                y += 1
            }
            y += 1
        }

        let nameW = 18
        let speakerRoom = max(0, frame.width - 11)
        let barW = min(16, max(0, speakerRoom - 8))
        let speakerNameW = min(nameW, max(0, speakerRoom - barW))

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
            if isCursor, !(placement == .top && dispRow == .stopUsingSpanDAC) { focusY = y }
            switch dispRow {
            case .spandacMac:
                var detail: SpanDACRowDetail
                if !switched {
                    detail = macDataRowDetail(macDataState)
                } else if macInstalled == false {
                    detail = macDataRowDetail(.notInstalled)
                } else {
                    detail = spandacRowDetail(state: macRowState, output: macOutput, device: macName,
                                              isThisMac: true, now: now)
                    if let problem = macOutputProblem, macRowState == .ready, macOutput?.switchable == true {
                        // The switch was asked for and refused: SpanDAC stays the
                        // output, and the row says why. Enter asks again.
                        detail = SpanDACRowDetail(text: problem, tone: .warning)
                    }
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
                if isCursor { focusY = y }
                guard y <= bottom else { break }
                let selected = routing.mode == .musicApp
                let title = musicTUIOutputName
                let padTitle = title + String(repeating: " ", count: max(0, nameW - title.count))
                let titleStr = isCursor ? "\(ANSICode.inverse)\(padTitle)\(ANSICode.reset)"
                                        : (selected ? "\(ANSICode.brightWhite)\(padTitle)\(ANSICode.reset)"
                                                    : "\(ANSICode.dim)\(padTitle)\(ANSICode.reset)")
                let note = "this Mac  \u{00B7}  " + (speakerFetchFailed ? "speaker list unavailable; retrying" : (everLoaded ? "no AirPlay speakers found" : "loading speakers\u{2026}"))
                out += ANSICode.moveTo(row: y, col: 3)
                out += "  \(dot(selected)) \(titleStr) \(ANSICode.dim)\(truncText(note, to: max(0, frame.width - 4 - 4 - nameW - 1)))\(ANSICode.reset)"
                y += 1

            case .speaker(let i):
                closeSpanDACSection()
                if isCursor { focusY = y }
                guard y <= bottom else { break }
                let row = rows[i]
                out += ANSICode.moveTo(row: y, col: 3)
                let marker = " "
                let name = speakerNameW <= 1 ? String(row.name.prefix(speakerNameW)) : truncText(row.name, to: speakerNameW)
                let padName = name + String(repeating: " ", count: max(0, speakerNameW - name.count))
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
                // A speaker that is off has no volume of its own: Music reports
                // the Mac's volume for every unselected device and ignores a
                // write to one (measured 2026-11-01), so no bar and no number.
                // The off dot already says why; nothing follows the name.
                guard row.active else {
                    out += "\(marker) \(dot(false, dimmed: spanDACPlaying)) \(nameStr)"
                    y += 1
                    break
                }
                // The Mac's own row with no known macOS volume: no bar and no
                // number (Music's would be a different, inaudible level), a
                // plain note in their place.
                if let why = row.macVolumeUnavailable {
                    let note = truncText(why.note, to: max(0, frame.width - 10 - speakerNameW))
                    out += "\(marker) \(dot(true, dimmed: spanDACPlaying)) \(nameStr) \(ANSICode.dim)\(note)\(ANSICode.reset)"
                    y += 1
                    break
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

            case .held(let name):
                closeSpanDACSection()
                if isCursor { focusY = y }
                guard y <= bottom else { break }
                let shown = speakerNameW <= 1 ? String(name.prefix(speakerNameW)) : truncText(name, to: speakerNameW)
                let padName = shown + String(repeating: " ", count: max(0, speakerNameW - shown.count))
                let nameStr = isCursor ? "\(ANSICode.inverse)\(padName)\(ANSICode.reset)"
                                       : "\(ANSICode.dim)\(padName)\(ANSICode.reset)"
                let note = held?.standIn == true ? "speakers listed \u{00B7} move to choose"
                                                 : "gone \u{00B7} move to choose"
                out += ANSICode.moveTo(row: y, col: 3)
                out += "  \(dot(false, dimmed: true)) \(nameStr) \(ANSICode.dim)\(truncText(note, to: max(0, frame.width - 10 - speakerNameW)))\(ANSICode.reset)"
                y += 1

            case .eqPower:
                closeSpanDACSection()
                // Blank line before the EQ block when space allows.
                if y + 1 <= bottom {
                    y += 1
                }
                if isCursor { focusY = y }
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

            }
        }

        // No in-body key hints — the scene-aware footer already shows them.
        // A stale list is said on a pinned top line that no scroll position or
        // long group name can hide, and that never touches the status line
        // (Codex turns 33-34).
        // "Can't reach <device>. Leave it?" is PINNED to the top of the body,
        // outside the scrolling list, so no cursor position can scroll it out
        // of view while it swallows the keys. Wrapped, never cut; a body too
        // short for it shows the question and no list.
        if let question = askingLeave {
            let width = max(1, frame.width - 4)
            var ask = wrapForOutputTab(Self.leaveQuestionText(question), width: width)
            if let last = ask.last, last.count + 2 + stopUsingSpanDACKeys.count <= width {
                ask[ask.count - 1] = last + "  " + stopUsingSpanDACKeys
            } else {
                ask.append(stopUsingSpanDACKeys)
            }
            let shown = Array(ask.prefix(frame.bodyHeight))
            var pinned = ""
            for (i, line) in shown.enumerated() {
                pinned += ANSICode.moveTo(row: frame.bodyY + i, col: 3)
                    + "\(ANSICode.bold)\(ANSICode.brightWhite)\(line)\(ANSICode.reset)"
            }
            let inset = shown.count + 1      // a blank line under it
            guard inset < frame.bodyHeight else { return clear + pinned }
            return clear + pinned + outputViewport(out, bodyY: frame.bodyY, height: frame.bodyHeight,
                                                   focusY: focusY, inset: inset)
        }
        if speakerFetchFailed, frame.bodyHeight > 1 {
            let said = everLoaded ? "AirPlay speaker list unavailable; retrying \u{00B7} showing the last list"
                                  : "AirPlay speaker list unavailable; retrying"
            let warn = truncText(said, to: max(0, frame.width - 4))
            return clear + ANSICode.moveTo(row: frame.bodyY, col: 3) + "\(ANSICode.yellow)\(warn)\(ANSICode.reset)"
                + outputViewport(out, bodyY: frame.bodyY, height: frame.bodyHeight, focusY: focusY, inset: 1)
        }
        return clear + outputViewport(out, bodyY: frame.bodyY, height: frame.bodyHeight, focusY: focusY)
    }

    func handle(_ key: KeyPress) -> SceneAction {
        readinessLock.lock(); handledKeys += 1; readinessLock.unlock()
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
        // "Leave it?" is modal like the question above: y, n and Esc answer it
        // and every other key, a second Enter included, is ignored.
        if let question = askingLeave {
            switch key {
            case .char("y"), .char("Y"):
                askingLeave = nil
                // The action decides whether the question's output and epoch
                // still hold; otherwise this is an ordinary, strict attempt.
                selectMode(question.target, name: question.targetName,
                           leaveUnreached: (question.outgoing, question.epoch))
                return .redraw
            case .char("n"), .char("N"), .escape:
                askingLeave = nil
                return .redraw
            default:
                return .none
            }
        }
        // Rows can come and go with the data axis; keep the cursor on one.
        anchorHeld()
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
                anchorHeld()
                return .redraw
            }
            return .pop
        }

        // Moving off the held row removes it, and the move resolves in the
        // list without it, so taking it away is never an extra step: Down
        // lands on the row that followed it, Up on the row before it. A move
        // with nowhere to go leaves it where it is.
        if let saved = held, let h = displayRows.firstIndex(where: \.isHeld) {
            var target: Int?? = nil   // nil: not a move; .some(nil): nowhere to go
            held = nil
            let count = self.displayRows.count
            switch key {
            case .up: target = .some(h > 0 ? h - 1 : nil)
            case .down: target = .some(h < count ? h : nil)
            case .pageUp: target = .some(h > 0 ? max(0, h - 5) : nil)
            case .pageDown: target = .some(h < count ? min(count - 1, h + 4) : nil)
            case .home: target = .some(count > 0 ? 0 : nil)
            case .end: target = .some(count > 0 ? count - 1 : nil)
            default: break
            }
            switch target {
            case .some(.some(let to)):
                cursor = to
                return .redraw
            case .some(.none):
                held = saved
                anchorHeld()
                return .none
            case .none:
                held = saved
                anchorHeld()
            }
        }

        switch key {
        case .char("e"), .char("E"):
            toggleEQ()
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
                lastMutation = fetchNow()
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
            case .held, nil:
                return .none
            }
        case .left:
            let currentRow = displayRows.indices.contains(cursor) ? displayRows[cursor] : nil
            switch currentRow {
            case .speaker(let i):
                guard speakerVolumeAllowed(), speakerIsOn(rows[i]), speakerVolumeSettable(rows[i]) else { return .redraw }
                rows[i].volume = max(0, rows[i].volume - 5)
                lastMutation = fetchNow()
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
                guard speakerVolumeAllowed(), speakerIsOn(rows[i]), speakerVolumeSettable(rows[i]) else { return .redraw }
                rows[i].volume = min(100, rows[i].volume + 5)
                lastMutation = fetchNow()
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
        routeCheckLock.lock()
        routeCheckSerial += 1
        let serial = routeCheckSerial
        routeCheckLock.unlock()
        let outputEpoch = routing.epoch
        actions.run("Speaker") {
            let verifier = self.makeRouteVerifier()
            let needsCheck = active && row.kind != "computer"
            // Give the baseline a short head start without holding all later
            // actions behind a sleeping speaker. If it doesn't finish before
            // the write, discard it: a post-write baseline proves nothing.
            typealias Preparation = (playing: Bool, ip: String?, baseline: Set<TCPConnection>?)
            let prepared = LockedBox<Preparation?>(nil)
            let ready = DispatchSemaphore(value: 0)
            var preparation: Preparation?
            if needsCheck, self.routePreparationSlot.wait(timeout: .now()) == .success {
                DispatchQueue.global().async {
                    defer { self.routePreparationSlot.signal(); ready.signal() }
                    let playing = self.routePlaying(self.backend)
                    let ip = playing ? verifier.resolver.resolveIP(forSpeaker: name) : nil
                    let baseline = ip.flatMap { try? verifier.snapshot(ip: $0) }
                    prepared.set((playing, ip, baseline))
                }
                if ready.wait(timeout: .now() + 0.35) == .success { preparation = prepared.get() }
            }
            try require((try? self.backend.runMusicBlocking("set selected of AirPlay device \"\(esc)\" to \(active)", timeout: 8)) != nil,
                        "Couldn't \(active ? "add" : "remove") '\(name)'.")
            // Verify off the action queue; a later toggle or output switch
            // makes this verdict stale. Recovery stays a separate action.
            if let preparation, preparation.playing, let ip = preparation.ip, let baseline = preparation.baseline {
                // A netstat read error is NOT evidence the route is fine — the
                // old `?? true` silently passed on it, while the CLI path treats
                // the same error as not-verified. Post an honest "couldn't check"
                // instead of a false all-clear.
                DispatchQueue.global().async {
                    defer { self.routeCheckFinishedForTest?() }
                    let message: String?
                    // A read error is not evidence either way: a plain note,
                    // never the error toast that calls a working speaker broken.
                    var isError = true
                    do {
                        let verdict = try verifier.verifyEstablishment(ip: ip, baseline: baseline, timeout: 3.0)
                        message = verdict.verified ? nil : "'\(name)' selected but route NOT verified — deselect and reselect it"
                    } catch {
                        message = "'\(name)' selection requested; route not checked"
                        isError = false
                    }
                    // Paused or stopped meanwhile: the route was torn down on
                    // purpose, so a "NOT verified" now would be about the pause.
                    // The output is read AFTER that (possibly slow) player read.
                    let stillPlaying = message == nil || self.routePlaying(self.backend)
                    let sameOutput = self.routing.epoch == outputEpoch
                    self.routeCheckLock.lock()
                    if self.routeCheckSerial == serial, sameOutput, stillPlaying, let message {
                        self.status.post(message, error: isError)
                    }
                    self.routeCheckLock.unlock()
                }
            } else if needsCheck {
                self.routeCheckLock.lock()
                let current = self.routeCheckSerial == serial
                self.routeCheckLock.unlock()
                if current, preparation == nil {
                    // The head start ran out (cold Bonjour + player read, ~0.37 s
                    // measured for a Sonos) or another check holds the slot: the
                    // selection was sent, nothing was measured. A plain note, not
                    // an error that would call a working speaker broken.
                    self.status.post("'\(name)' selection requested; route not checked")
                } else if current, preparation?.playing == true {
                    // No address, or the connection table can't be read from
                    // this session (macOS 27 under tmux/SSH, 2026-10-31): the
                    // selection was sent and nothing was measured. Unknown is
                    // not broken, so the note is plain.
                    self.status.post("'\(name)' selection requested; route not checked")
                }
            }
        }
    }
    /// Asked at the keypress, BEFORE the bar moves: when the coordinator would
    /// refuse `.volume` (a SpanDAC output, or a SpanDAC play-out) nothing is
    /// changed and the refusal reaches the person as the usual action toast.
    /// The toast carries the sentence the KEYPRESS was refused with, not a
    /// second decision made when the queue runs: if routing relaxes in between
    /// (a play-out ends), a re-decided `perform` would run nothing and the
    /// keypress would vanish without a word. (The write itself, in
    /// `setVolume`, does re-decide, for the opposite race.) False means refused.
    private func speakerVolumeAllowed() -> Bool {
        guard let why = routing.refusal(for: .volume) else { return true }
        actions.run("Volume") { throw ActionError(message: why) }
        return false
    }

    /// Asked at the keypress, after the routing check: a speaker that is off
    /// has no volume to set. Music ignores `set sound volume` on an AirPlay
    /// device that is not selected and reports the Mac's own volume for it
    /// (measured 2026-11-01), so a write would change nothing and the bar
    /// would lie. Nothing changes; the person is told how to get a volume.
    /// Decided on Music's `selected` (the row's `active`), never on the
    /// device kind: the Mac's own output, when on, stays adjustable.
    private func speakerIsOn(_ row: SpeakerRow) -> Bool {
        guard !row.active else { return true }
        let message = Self.turnOnToSetVolume(row.name)
        actions.run("Volume") { throw ActionError(message: message) }
        return false
    }

    static func turnOnToSetVolume(_ name: String) -> String { "Turn '\(name)' on to set its volume." }

    /// Asked at the keypress, after `speakerIsOn`: the Mac's own row whose
    /// macOS volume is not known (no software volume, or the read failed).
    /// Nothing is written: the write is an absolute level, and one computed
    /// from a number that is not the Mac's would jump the real volume.
    private func speakerVolumeSettable(_ row: SpeakerRow) -> Bool {
        guard let why = row.macVolumeUnavailable else { return true }
        actions.run("Volume") { throw ActionError(message: why.notice) }
        return false
    }

    private func setVolume(_ row: SpeakerRow) {
        // Coalesced per speaker: holding an arrow applies only the final target.
        let esc = escapeAppleScriptString(row.name)
        let name = row.name
        let macOutput = row.isMacOutput
        speakerTargets.set(name, row.volume)
        actions.run("Volume") {
            guard let v = self.speakerTargets.take(name) else { return }
            // Through the coordinator like the global `+`/`-` (`globalVolume`):
            // the write runs only where the contract lets volume run.
            try self.routing.perform(.volume,
                musicApp: {
                    // The selection can change while this waits on the queue
                    // (turned off elsewhere), and a write to an unselected
                    // device is silently ignored: so the check and the write
                    // are one script, and "off" is reported, not claimed.
                    let reply: String?
                    if macOutput {
                        // The Mac's own output: the macOS output volume, which
                        // is what you hear. `set volume` is a Standard
                        // Additions command, so it runs here, outside any
                        // Music tell block; only the selection check asks Music.
                        let script = """
                        tell application "Music" to set isOn to selected of AirPlay device "\(esc)"
                        if isOn then
                            set volume output volume \(v)
                            return "set"
                        end if
                        return "off"
                        """
                        reply = (try? self.backend.runBlocking(script))?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        let script = """
                        if selected of AirPlay device "\(esc)" then
                            set sound volume of AirPlay device "\(esc)" to \(v)
                            return "set"
                        end if
                        return "off"
                        """
                        reply = (try? self.backend.runMusicBlocking(script))?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    try require(reply != "off", Self.turnOnToSetVolume(name))
                    // Only the script's own "set" is a done write; anything
                    // else (a failure, a blank or odd answer) is reported.
                    try require(reply == "set", "Couldn't set '\(name)' volume.")
                },
                source: { _ in },
                unaffected: {})
        }
    }
    /// EQ on/off — shared by the power row (Enter) and the 'e' shortcut.
    /// eqSetEnabled is a check-then-click, so rapid toggles stay idempotent.
    private func toggleEQ() {
        let on = !(eqState?.enabled ?? false)
        if eqState == nil { eqState = EQSnapshot(enabled: on, current: nil, presets: []) }
        else { eqState?.enabled = on }
        lastMutation = fetchNow()
        actions.run("EQ") {
            try Self.eqStep("Couldn't turn EQ \(on ? "on" : "off").") { try eqSetEnabled(self.backend, on) }
        }
    }

    /// One Equalizer-window step of an EQ action. An `EQWindowRefusal` is
    /// toasted as its own sentence (what to do when the Equalizer could not be
    /// kept off-screen), and an Accessibility denial as the hint
    /// `runMusicUIScript` translated it into (Codex r3: the toast used to say
    /// only "Couldn't turn EQ on."). Any other failure keeps the step's short
    /// message.
    private static func eqStep(_ fallback: String, _ step: () throws -> Void) throws {
        do { try step() } catch let refusal as EQWindowRefusal {
            throw ActionError(message: refusal.message)
        } catch AppleScriptBackend.ScriptError.executionFailed(let failure)
                    where failure == eqAccessibilityHint || failure == musicUIAccessibilityHint {
            throw ActionError(message: failure)
        } catch {
            throw ActionError(message: fallback)
        }
    }

    private func selectEQPreset(_ name: String) {
        if eqState == nil { eqState = EQSnapshot(enabled: true, current: name, presets: []) }
        eqState?.current = name
        eqState?.enabled = true
        lastMutation = fetchNow()
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
            try Self.eqStep("Couldn't select preset '\(target)'.") { try eqSetCurrent(self.backend, name: target) }
            try Self.eqStep("Couldn't enable EQ.") { try eqSetEnabled(self.backend, true) }
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
