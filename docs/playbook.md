# Playbook: Apple Music

How to rebuild this project from scratch.

## Tech Stack
Claude Code plugin with two layers:
- **music CLI** — Swift 5.9+ binary using AppleScript (playback/speakers) + Apple Music REST API (catalog/library)
- **Plugin shell** — slash commands, skill, status line script that delegate to music CLI (with AppleScript fallback)

## Setup
1. Install the plugin: `/plugin marketplace add anthonymaley/music` then `/plugin install music@anthonymaley-music`
2. Grant automation permissions: System Settings > Privacy & Security > Automation
3. Build music CLI: `scripts/install.sh` (optional, unlocks catalog features)
4. Set up Apple Music auth: `music auth setup` then `music auth` (optional, unlocks library/discovery)
5. Optional: enable status line in `~/.claude/settings.json` (see README)

## Architecture

```
apple-music/
├── tools/music/               # Swift CLI binary
│   ├── Package.swift          # SPM manifest (swift-argument-parser)
│   └── Sources/
│       ├── Music.swift        # @main entry, 20 subcommands
│       ├── Backends/
│       │   ├── AppleScriptBackend.swift  # osascript wrapper
│       │   └── RESTAPIBackend.swift      # Apple Music API (URLSession)
│       ├── Auth/
│       │   ├── AuthManager.swift     # Config + token management
│       │   ├── JWTGenerator.swift    # ES256 JWT from .p8 key (CryptoKit)
│       │   └── AuthPage.swift        # MusicKit JS HTML for user token
│       ├── Commands/
│       │   ├── PlaybackCommands.swift   # play, pause, skip, back, stop, now, shuffle, repeat
│       │   ├── SpeakerCommands.swift    # speaker list/set/add/remove/stop
│       │   ├── VolumeCommands.swift     # vol get/set/up/down/per-speaker
│       │   ├── AuthCommands.swift       # auth setup/status/open/set-token
│       │   ├── SearchCommand.swift      # catalog search
│       │   ├── AddCommand.swift         # add to library
│       │   ├── PlaylistCommands.swift   # full playlist CRUD + share + temp
│       │   ├── DiscoveryCommands.swift  # similar, suggest, new-releases
│       │   ├── MixCommand.swift         # build mixed playlists
│       │   └── RemoveCommand.swift      # remove track from playlist
│       ├── Models/
│       │   ├── OutputFormat.swift    # --json vs human-readable
│       │   ├── ResultCache.swift     # domain-specific song/speaker caches
│       │   └── LibrarySync.swift     # poll-and-retry for REST→AppleScript sync
│       └── TUI/
│           ├── Terminal.swift        # raw mode, ANSI codes, key reading
│           ├── TUILayout.swift       # shared ScreenFrame, renderShell
│           ├── MultiSelectList.swift # speaker picker, track selector
│           ├── ListPicker.swift      # playlist browser (2-pane)
│           ├── VolumeMixer.swift     # per-speaker volume mixer
│           └── NowPlayingTUI.swift   # now playing with album art + queue
├── commands/                  # Slash commands (delegate to music CLI, osascript fallback)
├── skills/music/SKILL.md      # Conversational skill documenting music CLI surface
├── scripts/
│   ├── install.sh             # Build + symlink music to ~/.local/bin/
│   └── statusline.sh          # Now playing for Claude Code status bar
└── .claude-plugin/            # plugin.json and marketplace.json
```

### Backend Selection
- **AppleScript** — playback, speakers, volume, now playing (no auth)
- **REST API** — catalog search (developer token), library writes + playlists + discovery (both tokens)

### Auth Tiers
| Tier | Commands available |
|------|-------------------|
| No auth | play, pause, skip, back, stop, now, shuffle, repeat, speaker, vol |
| Developer token | Above + search |
| Both tokens | Everything (add, playlist API, similar, suggest, new-releases, mix) |

### Config Location
- `~/.config/music/config.json` — key ID, team ID, key path, storefront
- `~/.config/music/AuthKey.p8` — Apple MusicKit private key
- `~/.config/music/user-token` — Apple Music user token (~6 month expiry)

## Integrations
- macOS Music app (via AppleScript/osascript)
- Apple Music REST API (via URLSession, JWT auth)
- AirPlay speakers and Bluetooth audio devices
- Messages.app and Mail.app (for playlist sharing)

## Deployment
Published via Claude Code marketplace. Version bumps must update all three locations (see CLAUDE.md).

## Gotchas
- **Parameter error (-50)** — Split AirPlay routing and playback into separate osascript calls
- **MusicKit JS requires HTTP origin** — Auth page served via localhost:8537, not file://
- **MusicKit framework hangs on macOS CLI** — Use pure REST API + CryptoKit JWT instead
- **`MusicLibrary.add()` is iOS-only** — macOS library writes go through REST API
- **Library sync delay** — REST API writes may take 1-3 seconds to appear in AppleScript
- User must grant Automation permissions on first use
- macOS only — AppleScript doesn't exist on other platforms
- AirPods names often contain apostrophes — escape in bash: `'Anthony'\''s AirPods Pro'`
- **Ghost speaker problem** — AirPlay speakers report `selected = true` but don't play audio. Fix: deselect→wait→reselect (wake cycle). v1.4.0 does this automatically on routed playback.
- **ArgumentParser flag shadowing** — `@Flag var verbose` on a ParsableCommand shadows the global `verbose()` function. Use `@Flag var verboseFlag` with explicit `name: [.customShort("v"), .customLong("verbose")]`.
- **Error enum payload formatting** — Don't embed full sentences in error enum payloads when `errorDescription` also wraps them. Use structured fields (e.g., `speakerNotFound(name:, available:)`).
- **AppleScript string escaping** — Always route user/catalog-supplied values through `escapeAppleScriptString()` (Backends/AppleScriptEscaping.swift) before interpolating into a script. It escapes backslash *then* quote — order matters. Never hand-roll a quote-only escape; a name with a `\` (e.g. `AC\DC`) corrupts the script otherwise.
- **Poll error vs stop** — `pollNowPlaying()` returns `PollOutcome` (`active`/`stopped`/`unavailable`), not an optional. Treat `.unavailable` (transient read failure) differently from `.stopped`: never auto-advance or blank the UI on a single transient hiccup.

## Current Status
v1.7.0 — AppleScript escaping hardened: one `escapeAppleScriptString()` helper (backslash-then-quote) handles every user/catalog-supplied value (playlists, speakers, albums, tracks, message recipients); `repeat` mode validated against {off,one,all}. TUI poll handling distinguishes genuine stop from transient read error via `PollOutcome` — a hiccup no longer skips a track (context mode) or blanks the screen. SIGWINCH wired to clear stale artifacts on resize. Dead code removed (`RightPaneMode`, queue/history row builders, `LibrarySync`, `RESTAPIBackend.delete`). Unit tests for escaping + timeline overlay/dedup (34 total). Earlier in the line: full AirPlay reset (deselect all → reselect → restore volumes) on all play paths; unified timeline (context = full playlist with history overlay, standalone = history-only); `<>`/`,.` track skip; bidirectional `b` (browser ↔ now playing); ♥/↓ rating indicators (display only — no keybindings). 14 slash commands, conversational skill, status line.
