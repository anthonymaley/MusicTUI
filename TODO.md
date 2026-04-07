# TODO

## Current Session

- [x] AirPlay reset: replace per-speaker wake cycle with full reset (deselect all → 1.5s → reselect → restore volumes → 1.5s)
- [x] Add AirPlay reset to playlist browser play paths (ghost connection fix from TUI)
- [x] Loved/disliked indicators on track title (♥/↓) with safe inner try block
- [x] Fix loved/disliked breaking pollNowPlaying (inner try for unsupported track types)
- [x] Unified timeline: context-aware TUI renders full playlist with history overlay
- [x] Standalone TUI: history-only timeline (no more transient album rebuilds under shuffle)
- [x] Add <>/,. skip keybindings, remove l/d love/dislike keybindings
- [x] Add 'b' key in playlist browser to jump to Now Playing
- [x] User fixes: simplified play track by index, removed speaker wake from play.md

## What's Next

- Clean up worktree branch `worktree-airplay-resilience`
- Version bump (1.7.0?) — significant changes to AirPlay handling and TUI
- Fix /kerd:tend warnings: add kivna/input/ and kivna/output/ to .gitignore, register hooks
- End-to-end edge case testing: comma in playlist name, overlapping speakers, 200+ tracks
- TUI: progress-only redraw on poll tick (Phase 2 dirty regions)
- TUI: row-only redraw on cursor move (micro-optimization)
- TUI: deferred preview in playlist browser (300-500ms idle fetch)
- Consider: playlist browser sorting (alphabetical option)
- Test AirPlay reset reliability over multiple days (1.5s timing adequate?)

## Key Context

- Version is 1.6.1 everywhere (plugin.json, marketplace.json x2, CLI, Music.swift)
- CLI binary is `music`, installed at `~/.local/bin/music`
- **Must codesign after cp**: `codesign -f --sign - ~/.local/bin/music` — macOS kills unsigned binaries
- **AirPlay reset**: full deselect→1.5s→reselect→restore volumes→1.5s. Replaces old per-speaker wake cycle.
- **resetAirPlaySpeakers()**: called on all play paths (CLI, slash commands, playlist browser). Skipped for local-only or `--no-wake`.
- **Two timeline models**: context-aware = full playlist with history overlay; standalone = history-only (no pollSurroundingTracks)
- **Dirty regions**: cursor ↑↓ calls refreshTimelineOnly() + continue, skips poll entirely
- **Playlist name escaping**: double quotes in names escaped with `replacingOccurrences(of: "\"", with: "\\\"")`
- **2-screen flow**: PlaylistBrowser ↔ NowPlaying with PlaybackContext. b works both directions.
- **Speaker matching**: longest match wins (avoids "Office" matching before "Julie office")
- **SourceKit false positives**: cross-file symbol warnings are noise. Build compiles clean.
- **Track skip keybindings**: <> or ,. for previous/next track in both TUIs

## Backlog

- Playlist browser: incremental track loading beyond 200
- Playlist browser: artwork support (chafa + raw mode)
- Playlist browser: `/` search
- Video demo in README
- `/music:list` command for listing playlists
