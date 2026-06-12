// Music.app equalizer access. Reads combine into one script; unrelated
// mutations are never combined in one call (parameter-error-50 rule) —
// creating a preset and initialising its own bands is one transaction.
// Free-function style mirrors fetchSpeakerDevices() in SpeakerCommands.swift.
import Foundation

struct EQSnapshot: Equatable {
    var enabled: Bool
    var current: String?      // nil when Music has never had a preset set (-1728)
    var presets: [String]
}

/// Pure parse of the RS/US-separated snapshot script output. Field separator
/// is RS (0x1E), preset-name separator is US (0x1F) — names can contain commas.
func parseEQSnapshot(_ raw: String) -> EQSnapshot? {
    let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\u{1E}")
    guard fields.count == 3, fields[0] == "true" || fields[0] == "false" else { return nil }
    return EQSnapshot(
        enabled: fields[0] == "true",
        current: fields[1].isEmpty ? nil : fields[1],
        presets: fields[2].isEmpty ? [] : fields[2].components(separatedBy: "\u{1F}"))
}

func fetchEQSnapshot(_ backend: AppleScriptBackend) throws -> EQSnapshot {
    let raw = try syncRun {
        try await backend.runMusic("""
            set rs to character id 30
            set us to character id 31
            set curName to ""
            try
                set curName to name of current EQ preset
            end try
            set nameList to ""
            repeat with p in EQ presets
                if nameList is not "" then set nameList to nameList & us
                set nameList to nameList & (name of p)
            end repeat
            return ((EQ enabled) as string) & rs & curName & rs & nameList
            """)
    }
    guard let snap = parseEQSnapshot(raw) else {
        throw AppleScriptBackend.ScriptError.executionFailed("unparseable EQ snapshot: \(raw.prefix(80))")
    }
    return snap
}

/// Ten band gains (32 Hz–16 kHz) of a named preset, for the status
/// sparkline. Preamp is not included.
func fetchEQBands(_ backend: AppleScriptBackend, name: String) throws -> [Double] {
    let esc = escapeAppleScriptString(name)
    let raw = try syncRun {
        try await backend.runMusic("""
            tell EQ preset "\(esc)"
                return (band 1 as string) & "," & (band 2 as string) & "," & (band 3 as string) & "," & (band 4 as string) & "," & (band 5 as string) & "," & (band 6 as string) & "," & (band 7 as string) & "," & (band 8 as string) & "," & (band 9 as string) & "," & (band 10 as string)
            end tell
            """)
    }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: ",").compactMap(Double.init)
}

func eqSetEnabled(_ backend: AppleScriptBackend, _ on: Bool) throws {
    _ = try syncRun { try await backend.runMusic("set EQ enabled to \(on)") }
}

func eqSetCurrent(_ backend: AppleScriptBackend, name: String) throws {
    let esc = escapeAppleScriptString(name)
    _ = try syncRun { try await backend.runMusic("set current EQ preset to EQ preset \"\(esc)\"") }
}

/// Create a venue preset if absent. An existing preset with the same name is
/// used as-is — we never overwrite bands (spec: lifecycle semantics).
func eqEnsurePreset(_ backend: AppleScriptBackend, preset: VenuePreset) throws {
    let esc = escapeAppleScriptString(preset.name)
    let bandSets = preset.bands.enumerated()
        .map { "set band \($0.offset + 1) to \($0.element)" }
        .joined(separator: "\n                ")
    _ = try syncRun {
        try await backend.runMusic("""
            if not (exists EQ preset "\(esc)") then
                make new EQ preset with properties {name:"\(esc)"}
                tell EQ preset "\(esc)"
                    \(bandSets)
                    set preamp to \(preset.preamp)
                end tell
            end if
            """)
    }
}

/// Returns true if a preset was deleted, false if it didn't exist.
func eqDeletePreset(_ backend: AppleScriptBackend, name: String) throws -> Bool {
    let esc = escapeAppleScriptString(name)
    let raw = try syncRun {
        try await backend.runMusic("""
            if exists EQ preset "\(esc)" then
                delete EQ preset "\(esc)"
                return "deleted"
            end if
            return "absent"
            """)
    }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "deleted"
}
