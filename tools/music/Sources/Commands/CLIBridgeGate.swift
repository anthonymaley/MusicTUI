// tools/music/Sources/Commands/CLIBridgeGate.swift
import ArgumentParser
import Foundation

/// Ruling 12.14 at the CLI's door (DoD 13).
///
/// `routeAction(_:in:from: .cli)` has refused playback-changing verbs in Source
/// Mode since step 1, but no CLI command asked it, so `music play` went straight
/// to Music.app while Bridge was selected: the fallback 12.14 forbids. Each verb
/// the matrix can refuse calls this FIRST, before any AppleScript, so a refusal
/// can never follow a side effect.
///
/// Pure: the mode is passed in. `nil` means go ahead exactly as the verb ships.
func cliBridgeRefusal(_ action: MusicTUIAction, mode: PlaybackMode) -> String? {
    guard case .refused(let why) = routeAction(action, in: mode, from: .cli) else { return nil }
    return why
}

/// Refuse `action` if the selected output says so: print the reason (as JSON
/// under `--json`) and exit non-zero. Music.app selected returns immediately.
func refuseInBridge(_ action: MusicTUIAction, json: Bool = false,
                    mode: PlaybackMode = PlaybackModeStore().mode()) throws {
    guard let why = cliBridgeRefusal(action, mode: mode) else { return }
    if json {
        let body: [String: Any] = ["ok": false, "error": why]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(why)
    }
    throw ExitCode.failure
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
