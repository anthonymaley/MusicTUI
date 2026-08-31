// Shared helper for the features that must drive Music through System Events
// because their scripting writes are severed in current Music builds (EQ live
// state, the visualizer, Genius Shuffle). Translates an Accessibility denial
// into an actionable message.
//
// EQControl and VisualizerControl used to keep their own inline copies of the
// denial classifier. Folded in here 2026-08-31: three copies of one predicate
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
    message.contains("assistive") || message.contains("-1719") || message.contains("-25211")
}

func runMusicUIScript(_ backend: AppleScriptBackend, _ script: String,
                      hint: String = musicUIAccessibilityHint) throws -> String {
    do {
        return try syncRun { try await backend.run(script) }
    } catch let error as AppleScriptBackend.ScriptError {
        if case .executionFailed(let msg) = error, isAssistiveAccessDenial(msg) {
            throw AppleScriptBackend.ScriptError.executionFailed(hint)
        }
        throw error
    }
}
