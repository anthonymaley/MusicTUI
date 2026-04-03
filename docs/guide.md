# Apple Music Plugin — Complete Guide

## What Is This?

A Claude Code plugin that gives you full control over Apple Music from the terminal. Play music, manage AirPlay speakers, search the catalog, build playlists, discover new tracks — without leaving your coding session.

## Naming

One name for everything: **`music`**.

| Surface | Name | Example |
|---------|------|---------|
| Marketplace listing | Apple Music for Claude Code | `/install anthonymaley/music` |
| Slash commands | `/music:*` | `/music:play`, `/music:stop` |
| CLI binary | `music` | `music now`, `music search "Fouk"` |
| Skill (natural language) | `music` | just talk to Claude |

The `name` field in `plugin.json` is `music` — this controls the slash command prefix. "Apple Music" appears in descriptions and docs for discoverability.

## How Users Interact

There are four interaction layers, from quickest to most flexible:

### 1. Slash Commands (`/music:*`)

Fast, instant, no AI reasoning. Type `/music:` and tab to discover all 13 commands.

Every slash command has `disable-model-invocation: true` — they execute immediately as shell scripts, with zero token cost. The output appears directly in the chat.

**Playback**

```
/music:play                      Resume playback
/music:play Working Vibes        Play a playlist
/music:play Working Vibes shuffle  Play with shuffle
/music:play 3                    Play result #3 from last search
/music:pause                     Pause
/music:skip                      Next track
/music:back                      Previous track
/music:stop                      Stop all playback
/music:stop kitchen              Remove kitchen from the speaker group
/music:now                       What's currently playing
/music:shuffle                   Toggle shuffle on/off
```

**Speakers**

```
/music:speaker                   Interactive picker (TUI) — toggle + ←→ volume
/music:speaker list              List all AirPlay devices
/music:speaker kitchen           Add kitchen to active speakers
/music:speaker kitchen 40        Add kitchen and set volume to 40
/music:speaker kitchen stop      Remove kitchen from the group
/music:speaker airpods only      Switch to AirPods only
/music:speaker 1 2 5             Add speakers by index from last list
```

**Volume**

```
/music:volume                       Interactive mixer (TUI)
/music:volume 60                    Set all active speakers to 60
/music:volume up                    Volume +10
/music:volume down                  Volume -10
/music:volume kitchen 80            Set a specific speaker to 80
```

**Catalog & Library** (requires music CLI + auth)

```
/music:search Bohemian Rhapsody  Search Apple Music catalog
/music:search Fouk               Search by artist
/music:add Get It Done Fouk      Add a track to your library
/music:add 3                     Add result #3 from last search
/music:similar                   Interactive browser for similar tracks (TUI)
music add --to "House"           Add current song to a playlist
music remove                     Remove current song from current playlist
```

**Playlists** (requires music CLI + auth)

```
/music:playlist                  Interactive browser (TUI) — list/shuffle/play
/music:playlist list             List all your playlists
/music:playlist tracks Working Vibes    Show tracks in a playlist
/music:playlist create Friday Mix       Create an empty playlist
/music:playlist create Friday Mix 1 3 5  Create from search results
/music:playlist add "House" 1 3 5        Add search results to playlist
/music:playlist delete Old Playlist     Delete a playlist
```

### 2. Natural Language (Skill)

For complex, multi-step requests — just talk normally. Claude uses the `music` skill to understand what you want and composes the right CLI calls.

```
> play some Daft Punk on the kitchen speaker
> add the living room to the group and turn it down to 40
> play my top 25 most played and list the tracks
> find me something like what's playing and make a playlist
> what's new from Radiohead?
> make me a mix from Fouk and Floating Points
```

The skill triggers automatically when Claude detects music-related intent. No special invocation needed.

### 3. Status Line

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
    "command": "~/.claude/plugins/music/scripts/statusline.sh"
  }
}
```

### 4. Direct CLI (`music`)

For power users who want to use music outside Claude Code — in scripts, shell aliases, or other tools. The CLI has `--json` output for every command, making it scriptable.

```bash
music now --json
music search "Fouk" --limit 20 --json
music playlist list --json
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code Plugin                         │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ Slash Commands│  │   Skill      │  │   Status Line    │   │
│  │ /music:*     │  │   (music)     │  │   statusline.sh  │   │
│  │ 13 commands  │  │   natural    │  │   now playing    │   │
│  │ instant exec │  │   language   │  │   zero tokens    │   │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘   │
│         │                 │                    │              │
│         ▼                 ▼                    ▼              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │                    music CLI                          │     │
│  │           Swift binary, 19 subcommands              │     │
│  │                                                     │     │
│  │  ┌─────────────────┐  ┌──────────────────────┐      │     │
│  │  │  AppleScript    │  │  REST API             │      │     │
│  │  │  Backend        │  │  Backend              │      │     │
│  │  │                 │  │                        │      │     │
│  │  │  • playback     │  │  • catalog search     │      │     │
│  │  │  • speakers     │  │  • add to library     │      │     │
│  │  │  • volume       │  │  • playlist CRUD      │      │     │
│  │  │  • now playing  │  │  • discovery          │      │     │
│  │  │  • shuffle      │  │  • recommendations    │      │     │
│  │  │  • repeat       │  │                        │      │     │
│  │  │                 │  │  Auth: JWT (ES256)     │      │     │
│  │  │  Auth: none     │  │  + user token          │      │     │
│  │  └─────────────────┘  └──────────────────────┘      │     │
│  └─────────────────────────────────────────────────────┘     │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │              AppleScript Fallback                    │     │
│  │  When music is not installed, slash commands          │     │
│  │  fall back to raw osascript for basic playback,     │     │
│  │  speakers, and volume control.                      │     │
│  └─────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### How a slash command executes

```
User types:  /music:play Fouk kitchen 60%

1. Claude Code runs commands/play.md as a shell script
2. Script checks: is music installed?
   ├─ YES → parses args, extracts speaker + volume + query
   │        music speaker kitchen 60
   │        music play "Fouk"
   └─ NO  → osascript -e 'tell application "Music" to play'
3. Output printed directly to chat
```

### How the skill works

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
│   ├── plugin.json              # Plugin metadata (name: "music", v1.3.0)
│   └── marketplace.json         # Marketplace listing
├── commands/                    # 13 slash commands
│   ├── play.md                  # /music:play [query] [speaker] [vol%]
│   ├── pause.md                 # /music:pause
│   ├── skip.md                  # /music:skip
│   ├── back.md                  # /music:back
│   ├── stop.md                  # /music:stop [speaker]
│   ├── now.md                    # /music:now
│   ├── shuffle.md               # /music:shuffle
│   ├── volume.md                   # /music:volume <level> | <speaker> <level>
│   ├── speaker.md               # /music:speaker <action> [name]
│   ├── search.md                # /music:search <query>
│   ├── add.md                   # /music:add <title> <artist>
│   ├── similar.md               # /music:similar
│   └── playlist.md              # /music:playlist <action> [args]
├── skills/music/
│   └── SKILL.md                 # Conversational skill (music CLI reference)
├── scripts/
│   ├── statusline.sh            # Status line (now playing)
│   └── install.sh               # Build + install music CLI
├── tools/music/                  # Swift CLI source
│   ├── Package.swift            # SPM manifest
│   └── Sources/
│       ├── Music.swift           # @main, all subcommands registered
│       ├── Backends/
│       │   ├── AppleScriptBackend.swift
│       │   └── RESTAPIBackend.swift
│       ├── Auth/
│       │   ├── AuthManager.swift
│       │   ├── JWTGenerator.swift
│       │   └── AuthPage.swift
│       ├── Commands/
│       │   ├── PlaybackCommands.swift
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
│       │   ├── ResultCache.swift
│       │   └── LibrarySync.swift
│       └── TUI/
│           ├── Terminal.swift
│           ├── MultiSelectList.swift
│           ├── ListPicker.swift
│           ├── VolumeMixer.swift
│           ├── NowPlayingTUI.swift
│           └── TUILayout.swift
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

v1.3.0 — all three locations stay in sync:
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`
