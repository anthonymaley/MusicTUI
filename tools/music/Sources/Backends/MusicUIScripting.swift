// Shared helper for the features that must drive Music through System Events
// because their scripting writes are severed in current Music builds (EQ live
// state, Genius Shuffle). Translates an Accessibility denial
// into an actionable message.
//
// EQControl and VisualizerControl (removed 2026-11-01) used to keep their own
// inline copies of the denial classifier. Folded in here 2026-08-31: three copies of one predicate
// is three chances for one of them to learn a new error code the others never
// hear about. Each still owns its own script shape and its own hint text,
// which is the part that genuinely differs.
import Foundation

let musicUIAccessibilityHint = """
This control drives Music's menus and needs Accessibility permission: \
System Settings → Privacy & Security → Accessibility → enable your terminal app, then retry.
"""

/// Whether a script failure is macOS refusing Accessibility (assistive) access,
/// as opposed to any other AppleScript error.
///
/// The single definition. Containment rather than equality because the signal
/// arrives embedded in a longer message, and deliberately narrow: translating
/// every failure into "grant Accessibility" would send the user to a settings
/// pane unrelated to their actual problem.
func isAssistiveAccessDenial(_ message: String) -> Bool {
    assistiveDenialSignals.contains { message.contains($0) }
}

/// The signals `isAssistiveAccessDenial` looks for. One list, so the
/// AppleScript form below can never learn a signal the Swift form misses.
let assistiveDenialSignals = ["assistive", "-1719", "-25211"]

/// The same classification as an AppleScript condition, for a script that
/// must re-raise a denial it would otherwise swallow (the Equalizer's menu
/// click). `textVariable` and `numberVariable` name the `on error` variables;
/// a numeric signal matches the number or the text, a word the text.
func appleScriptAssistiveDenialCondition(textVariable: String, numberVariable: String) -> String {
    assistiveDenialSignals.map { signal in
        Int(signal) != nil
            ? "\(numberVariable) is \(signal) or \(textVariable) contains \"\(signal)\""
            : "\(textVariable) contains \"\(signal)\""
    }.joined(separator: " or ")
}

func runMusicUIScript(_ backend: AppleScriptBackend, _ script: String,
                      hint: String = musicUIAccessibilityHint) throws -> String {
    do {
        return try backend.runBlocking(script)
    } catch let error as AppleScriptBackend.ScriptError {
        if case .executionFailed(let msg) = error, isAssistiveAccessDenial(msg) {
            throw AppleScriptBackend.ScriptError.executionFailed(hint)
        }
        throw error
    }
}
