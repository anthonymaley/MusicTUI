// Shuffle + repeat state, and Genius Shuffle. Shuffle enabled, shuffle mode,
// and song repeat all WRITE cleanly through normal AppleScript (probed) — no
// UI scripting, no Accessibility. Genius Shuffle is the exception: it's a
// one-shot action (it rebuilds the play queue from the current song) with no
// scripting property, so it goes through the Controls-menu item via System
// Events and needs Accessibility (see MusicUIScripting).
import Foundation

enum ShuffleMode: String, CaseIterable, Equatable {
    case songs, albums, groupings
    var next: ShuffleMode {
        let all = ShuffleMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Cycle order matches Music's submenu: Off → All → One.
enum RepeatMode: String, CaseIterable, Equatable {
    case off, all, one
    var next: RepeatMode {
        let all = RepeatMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct PlaybackModes: Equatable {
    var shuffleEnabled: Bool
    var shuffleMode: ShuffleMode
    var songRepeat: RepeatMode
}

let geniusShuffleAccessibilityHint = """
Genius Shuffle drives Music's Controls menu and needs Accessibility permission: \
System Settings → Privacy & Security → Accessibility → enable your terminal app, then retry.
"""

/// Parse "<bool>,<shuffle mode>,<song repeat>" from the read script.
func parsePlaybackModes(_ raw: String) -> PlaybackModes? {
    let f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard f.count == 3, f[0] == "true" || f[0] == "false",
          let mode = ShuffleMode(rawValue: f[1]),
          let rep = RepeatMode(rawValue: f[2]) else { return nil }
    return PlaybackModes(shuffleEnabled: f[0] == "true", shuffleMode: mode, songRepeat: rep)
}

func fetchPlaybackModes(_ backend: AppleScriptBackend) throws -> PlaybackModes {
    let raw = try backend.runMusicBlocking(
            "return (shuffle enabled as string) & \",\" & (shuffle mode as string) & \",\" & (song repeat as string)")
    guard let modes = parsePlaybackModes(raw) else {
        throw AppleScriptBackend.ScriptError.executionFailed("unparseable playback modes: \(raw.prefix(60))")
    }
    return modes
}

func setShuffleEnabled(_ backend: AppleScriptBackend, _ on: Bool) throws {
    _ = try backend.runMusicBlocking("set shuffle enabled to \(on)")
}

func setShuffleMode(_ backend: AppleScriptBackend, _ mode: ShuffleMode) throws {
    _ = try backend.runMusicBlocking("set shuffle mode to \(mode.rawValue)")
}

func setSongRepeat(_ backend: AppleScriptBackend, _ mode: RepeatMode) throws {
    _ = try backend.runMusicBlocking("set song repeat to \(mode.rawValue)")
}

/// One-shot: rebuilds the queue from the current song. UI-scripted; Accessibility.
func triggerGeniusShuffle(_ backend: AppleScriptBackend) throws {
    _ = try runMusicUIScript(backend, """
        tell application "System Events"
            tell process "Music"
                click menu item "Genius Shuffle" of menu "Controls" of menu bar 1
            end tell
        end tell
        """, hint: geniusShuffleAccessibilityHint)
}
