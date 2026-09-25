// tools/music/Sources/Commands/CLIBridgeGate.swift
import ArgumentParser
import Foundation

/// The CLI's Bridge gate, for verbs that do not dispatch (DoD 13).
///
/// A verb the matrix can refuse and that does not go through `cliDispatch`
/// calls this FIRST, before any AppleScript, so a refusal can never follow a
/// side effect. Verbs Bridge serves dispatch instead (`CLIBridgeDispatch.swift`,
/// slice 3 S6 onward).
///
/// Pure: the mode is passed in. `nil` means go ahead exactly as the verb ships.
/// **A `.source` route is never "go ahead":** a gated verb has no Bridge
/// branch, so going ahead would run Music.app with Bridge selected, a silent
/// fallback. It refuses instead (fail closed).
func cliBridgeRefusal(_ action: MusicTUIAction, mode: PlaybackMode) -> String? {
    switch routeAction(action, in: mode, from: .cli) {
    case .refused(let why): return why
    case .source:           return cliGateOnDispatchedAction
    case .musicApp, .unaffected: return nil
    }
}

/// What a gated verb says if the matrix serves its action through Bridge: the
/// verb should be dispatching, and nothing was changed.
let cliGateOnDispatchedAction =
    "Internal error: this command is served through Bridge but was not dispatched there; nothing was changed."

/// Refuse `action` if the selected output says so: print the reason (as JSON
/// under `--json`) and exit non-zero. Music.app selected returns immediately.
func refuseInBridge(_ action: MusicTUIAction, json: Bool = false,
                    mode: PlaybackMode = PlaybackModeStore().mode()) throws {
    guard let why = cliBridgeRefusal(action, mode: mode) else { return }
    print(cliFailureText(why, json: json))
    throw ExitCode.failure
}

/// One CLI failure as printed: the sentence, or `{"ok":false,"error":…}` under
/// `--json`. The single formatter for the gate and the dispatcher, so a
/// dispatched refusal is byte-identical to a gated one.
func cliFailureText(_ message: String, json: Bool) -> String {
    guard json else { return message }
    let body: [String: Any] = ["ok": false, "error": message]
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Which action a verb is, when its flags decide
//
// Decided from each command's own branches (survey 2026-09-22), not from names:
// the same verb names a song explicitly or falls back to Music.app's current
// track, and only the second half is refused (Anthony, 2026-09-16 13:36).

/// `music similar [title]`: no title means the current track (DiscoveryCommands.swift:20).
func similarAction(query: [String]) -> MusicTUIAction {
    query.isEmpty ? .similarToCurrentTrack : .similar
}

/// `music suggest [--from playlist]`: without `--from` it seeds from the current track.
func suggestAction(from playlist: String?) -> MusicTUIAction {
    playlist == nil ? .suggestFromCurrentTrack : .suggest
}

/// `music new-releases [--artist X] [--like-current]`: `--artist` wins when both are given.
func newReleasesAction(artist: String?, likeCurrent: Bool) -> MusicTUIAction {
    artist == nil && likeCurrent ? .newReleasesLikeCurrentTrack : .newReleases
}

/// `music add [query|index] [--id X] [--to P]`: only `--to` with no song named
/// reads the current track (AddCommand.swift:128).
func addAction(query: [String], id: String?, to: [String]) -> MusicTUIAction {
    id == nil && query.isEmpty && !to.isEmpty ? .addCurrentTrackToPlaylist : .addToLibrary
}
