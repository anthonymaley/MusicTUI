// Music.app equalizer access — two transports, by necessity:
//
//  * EQ PRESET objects (create / read bands / delete) script fine through
//    the normal Music dictionary and go through runMusic.
//  * LIVE state (EQ enabled, current preset) is severed in current
//    Music.app builds: writes error (-10006 / -1731 in every reference
//    form) and reads return stale values even while the real Equalizer
//    is on — verified live 2026-06-12. The Equalizer window's own
//    controls are the only working interface, so live state goes through
//    System Events UI scripting. That requires Accessibility permission
//    for the host terminal, and opens the Equalizer window on first use,
//    parked off-screen (see eqUIScript) and left open there.
//
// Free-function style mirrors fetchSpeakerDevices() in SpeakerCommands.swift.
import Foundation

struct EQSnapshot: Equatable {
    var enabled: Bool
    var current: String?      // nil when no preset has ever been chosen
    var presets: [String]
}

let eqAccessibilityHint = """
EQ control drives Music's Equalizer window and needs Accessibility permission: \
System Settings → Privacy & Security → Accessibility → enable your terminal app, then retry.
"""

/// Pure parse of the UI status script output: "<0|1><RS><preset name>".
func parseEQUIStatus(_ raw: String) -> (enabled: Bool, current: String?)? {
    let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\u{1E}")
    guard fields.count == 2, fields[0] == "0" || fields[0] == "1" else { return nil }
    return (fields[0] == "1", fields[1].isEmpty ? nil : fields[1])
}

/// Where the Equalizer window is parked so it never shows: far off the top
/// left. macOS clamps it to a sliver it still allows (measured -400,33 on the
/// laptop 2026-11-01), which Anthony's probe found invisible on screen.
private let eqParkedPosition = "{-3000, -3000}"

/// Wraps a System Events body targeting the Equalizer window. Anthony's ruling
/// (2026-11-01): EQ stays only if it works inside the terminal, so the window
/// must never appear on screen or come forward.
///
/// * Open: the Window-menu click alone, with no `reopen`. `launch` (not
///   `activate`) keeps the terminal frontmost. Proven once on the laptop
///   (2026-11-01 22:49, `.agents/probes/eq-offscreen.sh`): the window opened,
///   parked, toggled and read with nothing on screen.
/// * Fallback, only when the window did not appear: `reopen` (dock-click
///   semantics, the old first step) then the click again, because a
///   launched-but-never-activated Music with no windows has been seen to
///   ignore menu clicks. `reopen` restores Music's main window, so every window
///   it brought back, other than the Equalizer, is closed again by its close
///   button, even when the second click fails too (the `tell window` below then
///   reports the failure). Windows that were open before are left alone.
/// * Park: always, whether this script opened the window or found it open, so
///   a window an older MusicTUI left on screen goes off-screen at the next EQ
///   action. Best-effort: a failed move must not refuse the EQ change itself.
///
/// Variable names are long on purpose: short ones have collided with Music
/// and System Events terminology here before (`st`, `active`, `left`).
private func eqUIScript(_ body: String) -> String {
    """
    tell application "Music" to launch
    tell application "System Events"
        tell process "Music"
            if not (exists window "Equalizer") then
                try
                    click menu item "Equalizer" of menu "Window" of menu bar 1
                end try
                repeat 15 times
                    if exists window "Equalizer" then exit repeat
                    delay 0.1
                end repeat
                if not (exists window "Equalizer") then
                    set windowNamesBeforeReopen to name of every window
                    tell application "Music" to reopen
                    delay 0.5
                    try
                        click menu item "Equalizer" of menu "Window" of menu bar 1
                    end try
                    repeat 15 times
                        if exists window "Equalizer" then exit repeat
                        delay 0.1
                    end repeat
                    try
                        repeat with reopenedWindowName in (name of every window)
                            set reopenedWindowNameText to reopenedWindowName as text
                            if reopenedWindowNameText is not "Equalizer" and windowNamesBeforeReopen does not contain reopenedWindowNameText then
                                try
                                    tell window reopenedWindowNameText
                                        click (first button whose subrole is "AXCloseButton")
                                    end tell
                                end try
                            end if
                        end repeat
                    end try
                end if
            end if
            try
                set position of window "Equalizer" to \(eqParkedPosition)
            end try
            tell window "Equalizer"
                \(body)
            end tell
        end tell
    end tell
    """
}

/// Runs an Equalizer-window UI script. The denial translation lives in
/// `runMusicUIScript`; this wrapper exists only to apply the Equalizer window's
/// own script shape and hint.
private func eqUIRun(_ backend: AppleScriptBackend, _ body: String) throws -> String {
    try runMusicUIScript(backend, eqUIScript(body), hint: eqAccessibilityHint)
}

// Read the window state ONLY if the Equalizer window is already open — never
// opens it. Returns "CLOSED" otherwise. Used by the background poll, which must
// not pop the window (it steals focus, e.g. from the visualizer).
private func eqUIReadOnlyScript(_ body: String) -> String {
    """
    tell application "System Events"
        tell process "Music"
            if not (exists window "Equalizer") then return "CLOSED"
            tell window "Equalizer"
                \(body)
            end tell
        end tell
    end tell
    """
}

// Dereference into variables before coercing — `(value of checkbox 1) as string`
// coerces the unresolved specifier and errors -1700.
private let eqReadBody = """
    set cbv to value of checkbox 1
    set pv to ""
    try
        set pv to value of pop up button 1
    end try
    return (cbv as string) & (character id 30) & pv
    """

/// Best-effort EQ state from the scripting layer, for when the window isn't open
/// and we don't want to open it. The live reads can be stale after UI changes,
/// but on a fresh launch (before the window is ever opened) they're accurate.
private func eqSnapshotFromScripting(_ backend: AppleScriptBackend, names: [String]) -> EQSnapshot {
    let raw = (try? backend.runMusicBlocking("""
            set en to (EQ enabled) as string
            set cur to ""
            try
                set cur to name of current EQ preset
            end try
            return en & (character id 30) & cur
            """))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let f = raw.components(separatedBy: "\u{1E}")
    return EQSnapshot(enabled: f.first == "true",
                      current: (f.count > 1 && !f[1].isEmpty) ? f[1] : nil,
                      presets: names)
}

/// `openWindow: true` (CLI status, user actions) opens the Equalizer window to
/// read the true live state. `false` (the TUI poll) never opens it — it reads
/// only if already open, else falls back to the scripting layer.
func fetchEQSnapshot(_ backend: AppleScriptBackend, openWindow: Bool = true) throws -> EQSnapshot {
    // Preset names: the scripting dictionary path still works for these.
    let namesRaw = try backend.runMusicBlocking("""
            set us to character id 31
            set nameList to ""
            repeat with p in EQ presets
                if nameList is not "" then set nameList to nameList & us
                set nameList to nameList & (name of p)
            end repeat
            return nameList
            """).trimmingCharacters(in: .whitespacesAndNewlines)
    let names = namesRaw.isEmpty ? [] : namesRaw.components(separatedBy: "\u{1F}")

    let raw: String
    if openWindow {
        raw = try eqUIRun(backend, eqReadBody)
    } else {
        let out = try runMusicUIScript(backend, eqUIReadOnlyScript(eqReadBody), hint: eqAccessibilityHint)
        if out.trimmingCharacters(in: .whitespacesAndNewlines) == "CLOSED" {
            return eqSnapshotFromScripting(backend, names: names)
        }
        raw = out
    }
    guard let ui = parseEQUIStatus(raw) else {
        throw AppleScriptBackend.ScriptError.executionFailed("unparseable EQ state: \(raw.prefix(80))")
    }
    return EQSnapshot(enabled: ui.enabled, current: ui.current, presets: names)
}

/// Ten band gains (32 Hz–16 kHz) of a named preset, for the status
/// sparkline. Preamp is not included.
func fetchEQBands(_ backend: AppleScriptBackend, name: String) throws -> [Double] {
    let esc = escapeAppleScriptString(name)
    let raw = try backend.runMusicBlocking("""
            tell EQ preset "\(esc)"
                return (band 1 as string) & "," & (band 2 as string) & "," & (band 3 as string) & "," & (band 4 as string) & "," & (band 5 as string) & "," & (band 6 as string) & "," & (band 7 as string) & "," & (band 8 as string) & "," & (band 9 as string) & "," & (band 10 as string)
            end tell
            """)
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: ",").compactMap(Double.init)
}

/// Close the Equalizer window if it's open (its close button — the Window-menu
/// item only opens/focuses, it doesn't toggle shut). Used before starting the
/// visualizer so the EQ panel doesn't surface over it and steal focus.
func closeEqualizerWindowIfOpen(_ backend: AppleScriptBackend) {
    _ = try? runMusicUIScript(backend, """
        tell application "System Events"
            tell process "Music"
                if exists window "Equalizer" then
                    click button 1 of window "Equalizer"
                end if
            end tell
        end tell
        """)
}

func eqSetEnabled(_ backend: AppleScriptBackend, _ on: Bool) throws {
    _ = try eqUIRun(backend, """
        set cbv to value of checkbox 1
        if (cbv as integer) is not \(on ? 1 : 0) then click checkbox 1
        """)
}

func eqSetCurrent(_ backend: AppleScriptBackend, name: String) throws {
    let esc = escapeAppleScriptString(name)
    _ = try eqUIRun(backend, """
        tell pop up button 1
            click
            delay 0.2
            if exists menu item "\(esc)" of menu 1 then
                click menu item "\(esc)" of menu 1
            else
                key code 53
                error "preset '\(esc)' is not in the Equalizer menu"
            end if
        end tell
        """)
}

/// Create a venue preset if absent. An existing preset with the same name is
/// used as-is — we never overwrite bands (spec: lifecycle semantics).
func eqEnsurePreset(_ backend: AppleScriptBackend, preset: VenuePreset) throws {
    let esc = escapeAppleScriptString(preset.name)
    let bandSets = preset.bands.enumerated()
        .map { "set band \($0.offset + 1) to \($0.element)" }
        .joined(separator: "\n                ")
    _ = try backend.runMusicBlocking("""
            if not (exists EQ preset "\(esc)") then
                make new EQ preset with properties {name:"\(esc)"}
                tell EQ preset "\(esc)"
                    \(bandSets)
                    set preamp to \(preset.preamp)
                end tell
            end if
            """)
}

/// Returns true if a preset was deleted, false if it didn't exist.
func eqDeletePreset(_ backend: AppleScriptBackend, name: String) throws -> Bool {
    let esc = escapeAppleScriptString(name)
    let raw = try backend.runMusicBlocking("""
            if exists EQ preset "\(esc)" then
                delete EQ preset "\(esc)"
                return "deleted"
            end if
            return "absent"
            """)
    return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "deleted"
}
