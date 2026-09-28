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
/// Pure: both selections are passed in, as one `EffectiveSelection` (score:
/// data route and output, C-MATRIX), and the SOUND half of the two-axis
/// matrix decides. `nil` means go ahead exactly as the verb ships.
/// **A `.source` route is never "go ahead":** a gated verb has no Bridge
/// branch, so going ahead would run the MusicTUI output's body with a SpanDAC
/// selected, a silent fallback. It refuses instead (fail closed).
func cliBridgeRefusal(_ action: MusicTUIAction, selection: EffectiveSelection) -> String? {
    switch routeAction(action, selection: selection, from: .cli).sound {
    case .refused(let why): return why
    case .source:           return cliGateOnDispatchedAction
    case .musicApp, .unaffected: return nil
    }
}

/// The form that names an output only, as every caller did before the data
/// axis: MusicTUI's own data with the MusicTUI output, SpanDAC data with a
/// SpanDAC output (the coordinator's composition without a data store). For
/// callers that state a mode outright; the CLI's own gate reads both files.
func cliBridgeRefusal(_ action: MusicTUIAction, mode: PlaybackMode) -> String? {
    cliBridgeRefusal(action, selection: selectionNamingOutputOnly(mode))
}

/// Both selections as read from disk, once, for a gated verb: mode.json and
/// data.json beside it (C-AXES, C-REPAIR). Reads never write.
func liveCLISelection() -> EffectiveSelection {
    let modes = PlaybackModeStore()
    return effectiveSelection(data: DataProviderStore(beside: modes), modes: modes)
}

/// See `cliBridgeRefusal(_:mode:)`.
private func selectionNamingOutputOnly(_ mode: PlaybackMode) -> EffectiveSelection {
    mode == .musicApp ? .consistent(data: .open, output: mode) : .consistent(data: .spandacMac, output: mode)
}

/// What a gated verb says if the matrix serves its action through Bridge: the
/// verb should be dispatching, and nothing was changed.
let cliGateOnDispatchedAction =
    "Internal error: this command is served through SpanDAC but was not dispatched there; nothing was changed."

/// Refuse `action` if the two selections say so: print the reason (as JSON
/// under `--json`) and exit non-zero. Where the matrix runs the verb as it
/// ships, this returns immediately. The default reads mode.json and
/// data.json once (`liveCLISelection`).
func refuseInBridge(_ action: MusicTUIAction, json: Bool = false,
                    selection: EffectiveSelection = liveCLISelection()) throws {
    guard let why = cliBridgeRefusal(action, selection: selection) else { return }
    print(cliFailureText(why, json: json))
    throw ExitCode.failure
}

/// `refuseInBridge` for a caller that states an output only
/// (`cliBridgeRefusal(_:mode:)`).
func refuseInBridge(_ action: MusicTUIAction, json: Bool = false, mode: PlaybackMode) throws {
    try refuseInBridge(action, json: json, selection: selectionNamingOutputOnly(mode))
}

/// One CLI failure as printed: the sentence, or `{"ok":false,"error":…}` under
/// `--json`. The single formatter for the gate and the dispatcher, so a
/// dispatched refusal is byte-identical to a gated one.
func cliFailureText(_ message: String, json: Bool) -> String {
    guard json else { return message }
    let body: [String: Any] = ["ok": false, "error": message]
    // Sorted keys: a dictionary's order varies between calls, so without this
    // the same refusal printed different bytes (found by S7, 2026-09-25).
    let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
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
