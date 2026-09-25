// tools/music/Sources/TUI/Shell/SpeakersScene.swift
import Foundation

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

/// What the Speakers scene displays, in order: speakers, the EQ power row
/// (Enter toggles on/off), the preset row (Enter expands the picker), and —
/// when the picker is expanded — one row per preset.
enum SpeakersDisplayRow: Equatable {
    /// Output mode first: it is the only control that changes WHERE audio goes,
    /// so it sits above the speakers it governs (ruling 12.4).
    case mode(PlaybackMode)
    case speaker(Int)        // index into the SpeakerRow array
    case eqPower
    case eq
    case preset(String)
    case visualizer
}

func speakersDisplayRows(speakerCount: Int, expanded: Bool,
                         presetNames: [String],
                         showModes: Bool = true) -> [SpeakersDisplayRow] {
    var rows: [SpeakersDisplayRow] = showModes ? [.mode(.musicApp), .mode(.source)] : []
    rows += (0..<speakerCount).map { .speaker($0) }
    rows.append(.eqPower)
    rows.append(.eq)
    if expanded { rows += presetNames.map { .preset($0) } }
    rows.append(.visualizer)
    return rows
}

final class SpeakersScene: Scene {
    let id: SceneID = .speakers
    let tabTitle = "Output"
    var footerHint: String { "\u{2191}\u{2193} Move  Enter Toggle/Select  \u{2190}\u{2192} Volume/Preset  e EQ  v Visualizer" }

    private let backend: AppleScriptBackend
    private let status: StatusStore
    private let actions: ActionRunner
    private let routing: RoutingCoordinator
    /// How the client is built. Injectable so a test can drive readiness without
    /// a socket; production uses the real one.
    private let makeSourceClient: () -> SourceAppClient
    /// The three external refreshes `tick()` fires on entry and every 5s.
    /// Injectable so a test can prove it never reaches AppleScript or the real
    /// speaker cache; production uses the real global functions, unchanged.
    private let fetchSpeakers: () throws -> [[String: Any]]
    private let fetchEQ: (AppleScriptBackend) throws -> EQSnapshot
    private let fetchVisualizer: (AppleScriptBackend) throws -> Bool

    /// Bridge's own last-reported state. Owned by the main loop and written ONLY
    /// in `tick()`; background work posts to `inboxReadiness` instead.
    private var bridgeReadiness: SourceReadiness = .checking
    private let readinessLock = NSLock()
    private var inboxReadiness: SourceReadiness? = nil      // guarded by readinessLock
    private var readinessInFlight = false
    /// Counts actual probes, so a test can prove this refreshes on entry and
    /// does NOT poll while the tab sits open.
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
         fetchSpeakers: @escaping () throws -> [[String: Any]] = fetchSpeakerDevices,
         fetchEQ: @escaping (AppleScriptBackend) throws -> EQSnapshot = { try fetchEQSnapshot($0, openWindow: false) },
         fetchVisualizer: @escaping (AppleScriptBackend) throws -> Bool = visualizerStatus) {
        self.backend = backend
        self.status = status
        self.actions = actions
        self.routing = routing
        self.makeSourceClient = makeSourceClient
        self.fetchSpeakers = fetchSpeakers
        self.fetchEQ = fetchEQ
        self.fetchVisualizer = fetchVisualizer
    }

    /// Ask Bridge how it is, once, off the input thread.
    ///
    /// **Called at the activation boundary, never on a timer.** The answer is a
    /// socket round trip, and the rest of the session should not pay for a status
    /// a person only reads here.
    ///
    /// **The result comes back through the inbox**, not by assignment. The first
    /// version wrote `bridgeReadiness` directly from `ActionRunner`'s background
    /// queue while `render` read it on the main loop — a data race that happened
    /// to be invisible because the write never ran at all.
    /// The one way a background result reaches `bridgeReadiness`.
    private func publishReadiness(_ readiness: SourceReadiness) {
        readinessLock.lock()
        inboxReadiness = readiness
        readinessLock.unlock()
    }

    private func kickReadinessProbe() {
        guard !readinessInFlight else { return }
        readinessInFlight = true
        readinessProbeCount += 1
        let make = makeSourceClient
        DispatchQueue.global().async { [weak self] in
            let readiness = make().readiness()
            self?.publishReadiness(readiness)
        }
    }

    /// Enter on a mode row. Ruling 12.3's transaction lives in the coordinator:
    /// pause the outgoing player, drop its queue, save, commit — and refuse the
    /// whole switch if any step cannot be confirmed.
    private func selectMode(_ target: PlaybackMode) {
        actions.run("Output") { [weak self] in
            guard let self else { return }
            // Through the injected factory, like the probe. Building a real
            // client here made this path unmockable AND meant a test drove the
            // live app's socket instead of a stub.
            let client = self.makeSourceClient()
            let result = try self.routing.switchMode(
                to: target,
                readiness: { client.readiness() },
                pauseOutgoing: { outgoing in
                    switch outgoing {
                    case .musicApp:
                        return try confirmMusicAppNotPlaying(session: liveMusicAppPauseSession,
                                                             isRunning: liveMusicAppMayBeRunning)
                    case .source:
                        return try confirmBridgeNotPlaying(client.control)
                    }
                },
                dropQueue: { outgoing in
                    switch outgoing {
                    case .musicApp: break   // MusicTUI's own queue, cleared below
                    case .source:   try client.control.stop()
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
                self.publishReadiness(client.readiness())
                self.status.post(mode == .source ? "Output: Bridge" : "Output: Music.app")
            }
        }
    }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false
        // Apply a landed fetch — unless the user mutated state after it started,
        // in which case it's stale and would briefly revert the optimistic UI.
        // Bridge readiness: drained here so the only writer is the main loop.
        readinessLock.lock()
        let freshReadiness = inboxReadiness; inboxReadiness = nil
        readinessLock.unlock()
        if let freshReadiness {
            readinessInFlight = false
            if freshReadiness != bridgeReadiness {
                bridgeReadiness = freshReadiness
                changed = true
            }
        }

        inboxLock.lock()
        let fresh = inbox; inbox = nil
        let freshEQ = inboxEQ; inboxEQ = nil
        let freshVis = inboxVis; inboxVis = nil
        inboxLock.unlock()
        if let fresh {
            fetchInFlight = false
            if fetchStartedAt > lastMutation {
                let cursorName = rows.indices.contains(cursor) ? rows[cursor].name : nil
                rows = fresh
                everLoaded = true
                if let name = cursorName, let i = rows.firstIndex(where: { $0.name == name }) { cursor = i }
                let displayCount = speakersDisplayRows(speakerCount: rows.count, expanded: eqExpanded,
                                                       presetNames: pickerPresetNames).count
                if cursor >= displayCount { cursor = max(0, displayCount - 1) }
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
        // ONE probe per entry. `reentered` is the activation boundary: tick only
        // runs while this scene is shown, so a gap since the last one means the
        // person just arrived. Deliberately not tied to the 5s speaker poll
        // below — readiness is a question you ask on opening the tab, not a
        // heartbeat against the app's socket.
        if reentered || bridgeReadiness == .checking { kickReadinessProbe() }
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

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        var y = frame.bodyY
        out += ANSICode.moveTo(row: y, col: 3)
        out += "\(ANSICode.bold)\(ANSICode.cyan)AirPlay Outputs\(ANSICode.reset)"
        y += 2

        let displayRows = speakersDisplayRows(speakerCount: rows.count, expanded: eqExpanded,
                                              presetNames: pickerPresetNames)
        let nameW = 18
        let barW = 16
        let bottom = frame.bodyY + frame.bodyHeight - 1

        for (dispIdx, dispRow) in displayRows.enumerated() {
            guard y <= bottom else { break }
            let isCursor = dispIdx == cursor
            switch dispRow {
            case .mode(let mode):
                // Ruling 12.15: the user-facing output is Bridge; "MusicTUI
                // Source" stays internal. Ruling 12.13: ready or unavailable
                // WITH the reason, on one line a person can act on.
                out += ANSICode.moveTo(row: y, col: 3)
                let selected = routing.mode == mode
                let dot = selected ? "\(ANSICode.lime)\u{25CF}\(ANSICode.reset)"
                                   : "\(ANSICode.dim)\u{25CB}\(ANSICode.reset)"
                let title = mode == .musicApp ? "Music.app" : "Bridge"
                let padTitle = title + String(repeating: " ", count: max(0, nameW - title.count))
                let titleStr = isCursor ? "\(ANSICode.inverse)\(padTitle)\(ANSICode.reset)"
                                        : (selected ? "\(ANSICode.brightWhite)\(padTitle)\(ANSICode.reset)"
                                                    : "\(ANSICode.dim)\(padTitle)\(ANSICode.reset)")
                // DoD 12: ready OR unavailable-with-reason. Showing a note only
                // on failure made "ready" and "not asked yet" render identically,
                // which is exactly the ambiguity that hid the wiring defect.
                var note = ""
                if mode == .source {
                    let text = truncText(bridgeReadiness.label, to: max(0, frame.width - nameW - 12))
                    note = "  \(ANSICode.dim)\(text)\(ANSICode.reset)"
                }
                out += "  \(dot) \(titleStr)\(note)"
                y += 1

            case .speaker(let i):
                let row = rows[i]
                out += ANSICode.moveTo(row: y, col: 3)
                let marker = " "
                let dot = row.active ? "\(ANSICode.lime)\u{25CF}\(ANSICode.reset)" : "\(ANSICode.dim)\u{25CB}\(ANSICode.reset)"
                let name = truncText(row.name, to: nameW)
                let padName = name + String(repeating: " ", count: max(0, nameW - name.count))
                // Same selection language as the other tabs: inverse-video cursor.
                let nameStr: String
                if isCursor {
                    nameStr = "\(ANSICode.inverse)\(padName)\(ANSICode.reset)"
                } else if row.active {
                    nameStr = "\(ANSICode.brightWhite)\(padName)\(ANSICode.reset)"
                } else {
                    nameStr = "\(ANSICode.dim)\(padName)\(ANSICode.reset)"
                }
                let bar = meterBar(value: row.volume, width: barW)
                let vol = String(format: "%3d", row.volume)
                out += "\(marker) \(dot) \(nameStr) \(bar) \(vol)"
                y += 1

            case .eqPower:
                // Blank line before the EQ block when space allows.
                if y + 1 <= bottom {
                    y += 1
                }
                guard y <= bottom else { break }
                out += ANSICode.moveTo(row: y, col: 3)
                let on = eqState?.enabled == true
                let dot = on
                    ? "\(ANSICode.lime)\u{25CF}\(ANSICode.reset)"
                    : "\(ANSICode.dim)\u{25CB}\(ANSICode.reset)"
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
                out += "  \(dot) \(labelStr)"
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
                let dot = on
                    ? "\(ANSICode.lime)\u{25CF}\(ANSICode.reset)"
                    : "\(ANSICode.dim)\u{25CB}\(ANSICode.reset)"
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
                out += "  \(dot) \(labelStr)"
                y += 1
            }
        }

        // Show a status message in the speaker section when there are no speakers.
        if rows.isEmpty && y <= bottom {
            out += ANSICode.moveTo(row: y, col: 3)
            let msg = everLoaded ? "No AirPlay outputs found." : "Loading speakers\u{2026}"
            out += "\(ANSICode.dim)\(msg)\(ANSICode.reset)"
        }

        // No in-body key hints — the scene-aware footer already shows them.
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // Vim aliases: j/k/h/l/g/G/ctrl-d/ctrl-u — this scene has no raw-text
        // capture mode, so the full list-scene set is safe everywhere.
        let key = vimAlias(key, listScene: true)
        let displayRows = speakersDisplayRows(speakerCount: rows.count, expanded: eqExpanded,
                                              presetNames: pickerPresetNames)
        let rowCount = displayRows.count   // always ≥ 1 (EQ row always present)

        // Collapse the picker when Escape is pressed; otherwise pop.
        if case .escape = key {
            if eqExpanded {
                eqExpanded = false
                // Clamp cursor: it may have been on a preset row that no longer exists.
                let collapsed = speakersDisplayRows(speakerCount: rows.count, expanded: false,
                                                   presetNames: pickerPresetNames)
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
            case .mode(let target):
                selectMode(target)
                return .redraw
            case .speaker(let i):
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
                    let collapsed = speakersDisplayRows(speakerCount: rows.count, expanded: false,
                                                       presetNames: pickerPresetNames)
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
