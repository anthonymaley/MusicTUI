// tools/music/Sources/TUI/Shell/SpeakersScene.swift
import Foundation

/// One AirPlay output: its name, whether it's in the active group, and its volume.
struct SpeakerRow {
    let name: String
    var active: Bool
    var volume: Int
}

/// Pure mapping from `fetchSpeakerDevices()`'s `[[String:Any]]` to typed rows.
/// Entries missing name/selected/volume are skipped.
func speakerRows(from devices: [[String: Any]]) -> [SpeakerRow] {
    devices.compactMap { d in
        guard let name = d["name"] as? String,
              let active = d["selected"] as? Bool,
              let volume = d["volume"] as? Int else { return nil }
        return SpeakerRow(name: name, active: active, volume: volume)
    }
}

/// What the Speakers scene displays, in order: speakers, the EQ power row
/// (Enter toggles on/off), the preset row (Enter expands the picker), and —
/// when the picker is expanded — one row per preset.
enum SpeakersDisplayRow: Equatable {
    case speaker(Int)        // index into the SpeakerRow array
    case eqPower
    case eq
    case preset(String)
}

func speakersDisplayRows(speakerCount: Int, expanded: Bool,
                         presetNames: [String]) -> [SpeakersDisplayRow] {
    var rows: [SpeakersDisplayRow] = (0..<speakerCount).map { .speaker($0) }
    rows.append(.eqPower)
    rows.append(.eq)
    if expanded { rows += presetNames.map { .preset($0) } }
    return rows
}

final class SpeakersScene: Scene {
    let id: SceneID = .speakers
    let tabTitle = "Speakers"
    var footerHint: String { "\u{2191}\u{2193} Move  Enter Toggle/Select  \u{2190}\u{2192} Volume/Preset  e EQ on/off" }

    private let backend: AppleScriptBackend
    private let status: StatusStore
    private let actions: ActionRunner
    private let speakerTargets = TargetAccumulator()
    private let eqTargetLock = NSLock()
    private var eqTarget: String? = nil
    private var rows: [SpeakerRow] = []
    private var cursor = 0
    private var eqState: EQSnapshot? = nil
    private var eqExpanded = false

    // Background refresh, inbox pattern: tick() kicks fetches and drains results.
    // The scene used to load once and never again — devices appearing/vanishing
    // never showed, and a failed optimistic toggle stayed wrong forever.
    private let inboxLock = NSLock()
    private var inbox: [SpeakerRow]? = nil
    private var inboxEQ: EQSnapshot? = nil   // guarded by inboxLock
    private var fetchInFlight = false                 // tick()-thread only
    private var fetchStartedAt = Date.distantPast     // tick()-thread only
    private var lastFetchKickoff = Date.distantPast   // tick()-thread only
    private var lastTickAt = Date.distantPast         // tick()-thread only
    private var lastMutation = Date.distantPast       // handle()/tick() thread only
    private var everLoaded = false

    init(backend: AppleScriptBackend, status: StatusStore, actions: ActionRunner) {
        self.backend = backend
        self.status = status
        self.actions = actions
    }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false
        // Apply a landed fetch — unless the user mutated state after it started,
        // in which case it's stale and would briefly revert the optimistic UI.
        inboxLock.lock()
        let fresh = inbox; inbox = nil
        let freshEQ = inboxEQ; inboxEQ = nil
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
        // Refresh on (re)entry — tick only runs while this scene is active, so a
        // gap since the last tick means the user just switched back — and every
        // few seconds while shown. AirPlay enumeration runs off-thread.
        let now = Date()
        let reentered = now.timeIntervalSince(lastTickAt) > 0.5
        lastTickAt = now
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
            DispatchQueue.global().async { [weak self] in
                let result = speakerRows(from: (try? fetchSpeakerDevices()) ?? [])
                let eq = try? fetchEQSnapshot(self?.backend ?? AppleScriptBackend())
                guard let self else { return }
                self.inboxLock.lock()
                self.inbox = result
                self.inboxEQ = eq
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
            try require((try? syncRun { try await self.backend.runMusic("set selected of AirPlay device \"\(esc)\" to \(active)") }) != nil,
                        "Couldn't \(active ? "add" : "remove") '\(name)'.")
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
