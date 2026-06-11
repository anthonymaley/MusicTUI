# Apple Music Plugin — Complete Guide

## What Is This?

A Claude Code plugin that gives you full control over Apple Music from the terminal. Play music, manage AirPlay speakers, search the catalog, build playlists, discover new tracks — without leaving your coding session.

## Naming

One name for everything: **`music`**.

| Surface | Name | Example |
|---------|------|---------|
| Marketplace listing | Apple Music for Claude Code | `/plugin marketplace add anthonymaley/apple-music` |
| Skill (natural language) | `/music` | `/music play kid a in the kitchen at 60`, or just talk to Claude |
| CLI binary | `music` | `music now`, `music search "Fouk"` |

The `name` field in `plugin.json` is `music` — this is what makes the skill appear as `/music` in the menu. "Apple Music" appears in descriptions and docs for discoverability. There are no per-action slash commands: the skill is the plugin's single entry point.

## Command Vocabulary

Document clear long-form commands as the primary surface. Short forms are allowed as aliases, but they should not be the only documented path.

Primary examples:

- `music now`, not only `music np`
- `music volume`, not only `music vol`
- `music speaker wake`, not an implicit wake hidden behind `music play`

This keeps the command palette, README, and marketplace copy searchable while still allowing fast terminal aliases for experienced users.

## How Users Interact

There are five interaction layers, from quickest to most flexible:

### 1. Media Keys (transport)

Play/pause, next, and previous live on your keyboard (⏯ ⏭ ⏮). They control Apple Music natively through macOS — from any app, with zero setup, zero tokens, and no plugin surface at all. The plugin deliberately ships no slash commands for transport: a hardware key beats any typed command.

### 2. Natural Language (Skill — `/music`)

The plugin's single entry point in Claude Code. Say what you want — playback with routing, search, library, playlists, discovery — and Claude composes the right `music` CLI calls.

```
> /music play kid a in the kitchen and living room at 60%
> play some Daft Punk on the kitchen speaker
> add the living room to the group and turn it down to 40
> find me something like what's playing and make a playlist
> what's new from Radiohead?
> make me a mix from Fouk and Floating Points
```

Play-shaped requests are a fast path: the skill forwards your words to `music play`, whose parser deterministically extracts the query, speaker names (several at once), filler words, and volume. Naming speakers plays on exactly those speakers. Everything else is genuine composition — multiple CLI calls chained by Claude.

The skill triggers automatically when Claude detects music-related intent; `/music` invokes it explicitly. Requires the CLI to be built (one command: `scripts/install.sh`) — if it's missing, the skill says so and points at the script.

### 3. Interactive TUI

Run bare `music` in a real terminal for the unified interactive shell — a tabbed interface with **Now**, **Playlists**, and **Speakers** tabs.

```
music                           Unified shell: Now / Playlists / Speakers tabs
```

Current TUI contract:

- The Playlists tab does not fetch tracks on every playlist highlight; it loads tracks on selection. `/` filters the playlist rail as you type (arrows still navigate while filtering).
- Apple-curated playlists added to the library (AppleScript class `subscription playlist`) appear in the rail with an `APPLE` badge. They're read-only on Apple's side — edits fail with a toast, by design.
- Selecting a playlist pins it on the Now tab, which shows the full playlist and keeps `↑↓` navigation local.
- The Now tab shows the current album context, not a real Apple Music queue.
- `Enter` plays the highlighted row.
- Keys: `1/2/3` jump to a tab, `Tab`/`Shift-Tab` cycle, `↑↓` + `PgUp/PgDn/Home/End` navigate, `Space` play/pause, `</>` previous/next, `←→` seek (Now) or per-speaker volume (Speakers), `z`/`r` shuffle, `l` favorite, `+/-` master volume, `n` next-up options, `Esc` back, `q` quit.
- Speaker wake is explicit via `music speaker wake`; normal playback does not auto-reset AirPlay outputs.
- Music's Autoplay (∞) must stay OFF — playlist track-selection drives playback track-by-track and relies on each track stopping at its end.

### 4. Status Line

A passive display at the bottom of Claude Code showing what's playing — track, speakers, volume. Always visible, zero token cost.

```
┌──────────────────────────────────────────────────────────────┐
│  claude >                                                    │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  ▶ Everything In Its Right Place — Radiohead  ·  Kitchen [60]│
└──────────────────────────────────────────────────────────────┘
```

Enable in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/cache/apple-music-marketplace/music/3.0.0/scripts/statusline.sh"
  }
}
```

### 5. Direct CLI (`music`)

For power users who want to use music outside Claude Code — in scripts, shell aliases, or other tools. The CLI has `--json` output for every command, making it scriptable.

```bash
music now --json
music search "Fouk" --limit 20 --json
music add --to "House"             # add current song to a playlist
music remove                       # remove current song from current playlist
music playlist list --json
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code Plugin                         │
│                                                              │
│        ┌──────────────┐        ┌──────────────────┐          │
│        │   Skill      │        │   Status Line    │          │
│        │   (/music)    │        │   statusline.sh  │          │
│        │   natural    │        │   now playing    │          │
│        │   language   │        │   zero tokens    │          │
│        └──────┬───────┘        └────────┬─────────┘          │
│               │                          │                    │
│               ▼                          ▼                    │
│  ┌─────────────────────────────────────────────────────┐     │
│  │                    music CLI                          │     │
│  │           Swift binary, 24 subcommands              │     │
│  │                                                     │     │
│  │  ┌─────────────────┐  ┌──────────────────────┐      │     │
│  │  │  AppleScript    │  │  REST API             │      │     │
│  │  │  Backend        │  │  Backend              │      │     │
│  │  │                 │  │                        │      │     │
│  │  │  • playback     │  │  • catalog search     │      │     │
│  │  │  • speakers     │  │  • add to library     │      │     │
│  │  │  • volume       │  │  • playlist writes    │      │     │
│  │  │  • now playing  │  │  • discovery          │      │     │
│  │  │  • seek, love   │  │  • recommendations    │      │     │
│  │  │  • shuffle      │  │  • recent / rotation  │      │     │
│  │  │  • repeat       │  │                        │      │     │
│  │  │                 │  │  Auth: JWT (ES256)     │      │     │
│  │  │  Auth: none     │  │  + user token          │      │     │
│  │  └─────────────────┘  └──────────────────────┘      │     │
│  └─────────────────────────────────────────────────────┘     │
│                                                              │
└─────────────────────────────────────────────────────────────┘

  Media keys (⏯ ⏭ ⏮) ──► Music.app directly (no plugin involved)
```

### How a play request executes

```
User says:  /music play Fouk in the kitchen and living room at 60%

1. Claude detects music intent → loads music skill
2. Fast path: forwards the words to the CLI in ONE call
   music play Fouk in the kitchen and living room at 60
3. The CLI's PlayParser (deterministic, unit-tested) extracts:
   query "Fouk" · speakers Kitchen, Living Room · volume 60
4. Routes to exactly those speakers, sets volume, plays
```

### How a composition request executes

```
User says:  "find me something like what's playing and make a playlist"

1. Claude detects music intent → loads music skill
2. Skill provides full music CLI reference to Claude
3. Claude composes commands:
   music similar --json
   music playlist create-from "Track 1" "Artist 1" "Track 2" "Artist 2" --name "Discovered"
   music play "Discovered" shuffle
4. Claude executes via Bash tool (chained with &&)
5. Claude summarizes results in natural language
```

### How the status line works

```
Every few seconds, Claude Code runs statusline.sh:

1. Script checks: is music installed?
   ├─ YES → music now --json → parse track, speakers, volume
   └─ NO  → osascript (raw AppleScript query)
2. Output: "▶ Track — Artist  ·  Speaker [Volume]"
3. Displayed at bottom of terminal, no tokens consumed
```

## File Structure

```
apple-music/
├── .claude-plugin/
│   ├── plugin.json              # Plugin metadata (name: "music")
│   └── marketplace.json         # Marketplace listing
├── skills/music/
│   └── SKILL.md                 # Conversational skill (music CLI reference)
├── scripts/
│   ├── statusline.sh            # Status line (now playing)
│   └── install.sh               # Build + install music CLI
├── tools/music/                  # Swift CLI source
│   ├── Package.swift            # SPM manifest
│   └── Sources/
│       ├── Music.swift           # @main, all 24 subcommands registered
│       ├── StatusReporter.swift  # --verbose diagnostics on stderr
│       ├── Backends/
│       │   ├── AppleScriptBackend.swift   # osascript wrapper + watchdog timeout
│       │   ├── AppleScriptEscaping.swift  # one escaping helper
│       │   ├── LibraryLookup.swift        # one library-track lookup script
│       │   └── RESTAPIBackend.swift
│       ├── Auth/
│       │   ├── AuthManager.swift
│       │   ├── JWTGenerator.swift
│       │   └── AuthPage.swift
│       ├── Commands/
│       │   ├── PlaybackCommands.swift     # play/pause/skip/back/stop/now/seek/shuffle/repeat
│       │   ├── PlayParser.swift           # play arg parser: query/speakers/volume/shuffle
│       │   ├── PlayResolution.swift       # play query resolution order
│       │   ├── LoveCommands.swift         # love/unlove
│       │   ├── HistoryCommands.swift      # recent/rotation
│       │   ├── SpeakerCommands.swift
│       │   ├── VolumeCommands.swift
│       │   ├── AuthCommands.swift
│       │   ├── SearchCommand.swift
│       │   ├── AddCommand.swift
│       │   ├── RemoveCommand.swift
│       │   ├── PlaylistCommands.swift
│       │   ├── DiscoveryCommands.swift
│       │   └── MixCommand.swift
│       ├── Models/
│       │   ├── OutputFormat.swift
│       │   └── ResultCache.swift
│       └── TUI/
│           ├── Terminal.swift
│           ├── MultiSelectList.swift
│           ├── ListPicker.swift
│           ├── VolumeMixer.swift
│           ├── NowPlayingTUI.swift
│           ├── PlaylistBrowserModel.swift
│           ├── PlaylistDataSources.swift
│           ├── TUILayout.swift
│           └── Shell/               # unified tabbed shell (bare `music`)
│               ├── Shell.swift, Router.swift, Scene.swift
│               ├── GlobalKeymap.swift, ShellActions.swift
│               ├── NowPlayingScene.swift, PlaylistsScene.swift, SpeakersScene.swift
│               ├── NowPlayingStore.swift, PlaybackPoller.swift, PlaybackContext.swift
│               ├── AppQueue.swift       # app-owned playlist queue
│               └── ShellChrome.swift, ShellFrame.swift
├── docs/
│   ├── guide.md                 # This document
│   └── playbook.md              # How to rebuild from scratch
├── kivna/                       # Session logs
├── CLAUDE.md                    # Project instructions for Claude
├── AGENTS.md                    # Project instructions for other AI agents
├── README.md                    # GitHub-facing docs
├── TODO.md                      # Current state + next steps
└── LICENSE                      # MIT
```

## Auth

The plugin works at three levels depending on what's configured:

| Level | What you need | What you get |
|-------|--------------|-------------|
| **No auth** | Just install the plugin | Playback, speakers, volume, now playing, shuffle, repeat |
| **Developer token** | Apple Developer account + MusicKit key | Above + catalog search (100M+ tracks) |
| **Full auth** | Above + user token from browser | Above + add to library, playlist CRUD, similar tracks, suggestions, new releases, mixes |

### Setting up auth

```bash
# 1. Configure your Apple Developer credentials
music auth setup
# Prompts for: Key ID, Team ID, path to .p8 key

# 2. Get a user token (opens browser)
music auth
# MusicKit JS page on localhost:8537 → authorize → token saved

# 3. Verify
music auth status
```

### Config files

```
~/.config/music/
├── config.json      # Key ID, Team ID, key path, storefront
├── AuthKey.p8       # Apple MusicKit private key (ES256)
└── user-token       # User token from MusicKit JS (~6 month expiry)
```

## Known Gotchas

| Issue | Cause | Solution |
|-------|-------|---------|
| Parameter error (-50) | AppleScript can't set speaker + play in one call | Split into separate osascript calls (music does this) |
| Auth page won't load | MusicKit JS rejects `file://` origins | Auth page served via localhost:8537 HTTP server |
| MusicKit framework hangs | macOS CLI + MusicKit framework = deadlock | Use pure REST API + CryptoKit JWT instead |
| `MusicLibrary.add()` missing | iOS-only API | Library writes go through REST API |
| Library sync delay | REST writes take 1-3s to appear in AppleScript | LibrarySync model polls and retries |
| AirPods apostrophe | Names like "Anthony's AirPods Pro" break quoting | Speaker commands use fuzzy matching |
| Play shows "Nothing playing" | AppleScript `current track` unavailable during cold start | Retry loop waits up to 3s for track to load |
| ArgumentParser crash on bare invocation | Property wrappers crash when read on directly-constructed structs | Shared logic extracted to standalone functions |

## Version

v3.0.0 — all four locations stay in sync:
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`
- `tools/music/Sources/Music.swift` → `CommandConfiguration(version:)` (rebuild via `scripts/install.sh` so `music --version` matches)
