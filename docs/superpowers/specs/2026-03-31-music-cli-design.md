# Music CLI — Unified Apple Music Controller

**Date:** 2026-03-31
**Status:** Draft
**Author:** Anthony Maley + Claude

## Problem

The current Apple Music plugin uses AppleScript exclusively. This works well for playback, speakers, and volume control, but cannot access the Apple Music streaming catalog (100M+ tracks). Users cannot search the catalog, add tracks to their library, get recommendations, or build playlists from music they don't already own — all from the terminal.

## Solution

A single Swift CLI binary (`music`) that serves as the unified interface for all Apple Music operations. It uses two internal backends:

- **AppleScript backend** — playback, speaker routing, volume, now playing, shuffle/repeat
- **REST API backend** — catalog search, library writes, playlist CRUD, recommendations, discovery

AppleScript handles what the REST API cannot (device control). The REST API handles what AppleScript cannot (catalog access). The CLI is the only public interface — AppleScript becomes a private implementation detail.

## Architecture

```
┌──────────────────────────────────────────┐
│              music CLI (Swift)            │
│                                          │
│  ┌─────────────┐   ┌──────────────────┐  │
│  │  AppleScript │   │    REST API      │  │
│  │   Backend    │   │    Backend       │  │
│  │              │   │                  │  │
│  │  • play/     │   │  • catalog       │  │
│  │    pause/    │   │    search        │  │
│  │    skip      │   │  • add to        │  │
│  │  • speakers  │   │    library       │  │
│  │  • volume    │   │  • playlist      │  │
│  │  • now       │   │    CRUD          │  │
│  │    playing   │   │  • similar/      │  │
│  │  • shuffle/  │   │    recommend     │  │
│  │    repeat    │   │  • new releases  │  │
│  └─────────────┘   └──────────────────┘  │
│                                          │
│  ┌──────────────────────────────────────┐│
│  │         Auth Manager                 ││
│  │  • JWT generation from .p8 key       ││
│  │  • User token cache + validation     ││
│  │  • Graceful degradation (no auth =   ││
│  │    playback-only mode)               ││
│  └──────────────────────────────────────┘│
└──────────────────────────────────────────┘
```

### Backend Selection

Commands route to the correct backend automatically:

| Command group | Backend | Auth required |
|---|---|---|
| play, pause, skip, back, stop | AppleScript | No |
| now, shuffle, repeat | AppleScript | No |
| speaker, vol | AppleScript | No |
| search | REST API | Developer token only |
| add | REST API | Developer + user token |
| playlist list, playlist tracks | REST API | Developer + user token |
| playlist create/delete/add/remove/share | REST API | Developer + user token |
| similar, suggest, new-releases | REST API | Developer + user token |
| playlist (playback) | Both | Developer + user token |

Note: All `/v1/me/...` endpoints (including playlist reads like `list` and `tracks`) require the Music User Token. Only catalog search (`/v1/catalog/...`) works with the developer token alone.

### Auth Manager

Two tokens, managed independently:

**Developer token (JWT):**
- Generated from `.p8` private key using ES256 (CryptoKit)
- Key ID: configured at setup
- Team ID: configured at setup
- Expires every 180 days, auto-regenerated
- Stored at `~/.config/music-cli/developer-token.jwt`

**User token (Music User Token):**
- Obtained via MusicKit JS in browser (one-time auth flow)
- Cached at `~/.config/music-cli/user-token`
- Validated on first catalog write request per session
- ~6 month expiry, re-auth when expired
- CLI generates an HTML page with MusicKit JS, opens in browser, user signs in and pastes token

**Config file** (`~/.config/music-cli/config.json`):
```json
{
  "keyId": "W5H3NYJ999",
  "teamId": "8NS66RKB45",
  "keyPath": "~/.config/music-cli/AuthKey.p8",
  "storefront": "us"
}
```

**Graceful degradation:**
- No config at all → playback/speaker commands work, all catalog/library commands print setup instructions
- Developer token only → catalog search (`/v1/catalog/...`) works. All `/v1/me/...` commands — including reads like `playlist list`, `playlist tracks`, `similar`, `suggest`, `new-releases`, and writes like `add`, `playlist create` — print "run `music auth` to enable this feature"
- Both tokens → full functionality

## Command Surface

### Playback (AppleScript)

```
music play                                    # resume playback
music play --playlist "Working Vibes"         # play a playlist
music play --song "Get It Done" --artist "Fouk"  # play specific track
music pause
music skip
music back
music stop
music now                                     # current track info
music now --json                              # structured output
music shuffle on|off
music repeat off|one|all
```

### Speakers (AppleScript)

```
music speaker list                  # all AirPlay devices + status
music speaker set <name>            # switch to single speaker
music speaker add <name>            # add to current group
music speaker remove <name>         # remove from group
```

### Volume (AppleScript)

```
music vol                           # show current volume
music vol <0-100>                   # set global volume
music vol <speaker> <0-100>         # set per-speaker volume
music vol up                        # increase by 10
music vol down                      # decrease by 10
```

### Catalog Search (REST API)

```
music search <query>                # search songs
music search --artist <name>        # search by artist
music search --album <name>         # search by album
music search --limit 20             # control result count (default 10)
```

### Library Add (REST API)

```
music add <title> <artist>          # search + add top result to library
music add --id <catalog-id>         # add by Apple Music catalog ID
```

### Playlists (Hybrid)

```
music playlist list                                         # list all playlists
music playlist tracks <name>                                # list tracks in playlist
music playlist create <name>                                # create empty playlist
music playlist delete <name>                                # delete playlist
music playlist add <playlist> <title> <artist>              # add track to playlist
music playlist add <p1>,<p2> <title> <artist>               # add to multiple playlists
music playlist remove <playlist> <title>                    # remove track from playlist
music playlist share <name> --imessage <phone-or-contact>   # share via iMessage
music playlist share <name> --email <address>               # share via email
```

### Discovery (REST API)

```
music similar                                 # tracks similar to now playing
music similar <title> <artist>                # similar to specific track
music new-releases --like-current             # new releases matching current track
music new-releases --artist <name>            # new releases from artist
music suggest <count>                         # suggest N tracks from now playing
music suggest <count> --from <playlist>       # suggest from playlist vibe
```

### Smart Playlists (Hybrid)

```
music playlist temp <title1> <title2> ...     # create, play, auto-delete when done
music playlist create-from <title1> <artist1> <title2> <artist2> ...
                                              # create + populate + play
music mix --artists "Artist1,Artist2" --count 20
                                              # build mixed playlist from artists
```

### Auth

```
music auth                          # open browser for user token setup
music auth status                   # check token validity
music auth set-token <token>        # manual token paste
music auth setup                    # full guided setup (key + token)
```

## Output Formats

Every command supports two output modes:

- **Default (human-readable):** Clean formatted text for terminal use
- **`--json` flag:** Structured JSON for Claude and scripting

```
$ music now
Kill Frenzy — Fouk [Kill Frenzy - Single]
Kitchen (vol: 60) | Sonos arc (vol: 41)

$ music now --json
{"track":"Kill Frenzy","artist":"Fouk","album":"Kill Frenzy - Single",
 "speakers":[{"name":"Kitchen","volume":60},{"name":"Sonos arc","volume":41}]}
```

Claude always uses `--json`. Humans get the clean output.

## Playlist Share Implementation

Share generates an Apple Music URL for the playlist, then sends it via the platform:

- **iMessage:** AppleScript → Messages.app → send URL to contact
- **Email:** AppleScript → Mail.app → compose with URL

## Temp Playlist Lifecycle

1. `music playlist temp` creates a playlist with a `__temp__` prefix via REST API
2. Polls for library consistency — the playlist may not appear in AppleScript immediately after REST API creation. The CLI polls `osascript` for the playlist name up to 10 times with 1-second intervals before timing out.
3. Once visible, starts playback via AppleScript
4. A background monitor (or next CLI invocation) checks if playback stopped
5. If the temp playlist finished, delete it automatically via REST API
6. Fallback: `music playlist cleanup` manually deletes all `__temp__` playlists

### Library Consistency

Apple Music does not guarantee that resources created via the REST API (`POST /v1/me/library/playlists`) are immediately visible to AppleScript or the Music app. All hybrid flows that create/populate via REST API and then hand off to AppleScript for playback must include a poll-and-retry step:

```
REST API: create/populate playlist
  → poll: osascript "get name of every playlist" until new playlist appears
  → timeout after 10s with user-facing error
  → AppleScript: play playlist
```

This applies to: `playlist temp`, `playlist create-from`, `mix`, and any flow that writes via REST then reads via AppleScript.

## Project Structure

```
apple-music/
├── tools/music-cli/
│   ├── Package.swift
│   └── Sources/
│       ├── main.swift              # entry point, argument parsing
│       ├── AppleScriptBackend.swift # osascript wrapper
│       ├── RESTAPIBackend.swift     # Apple Music API client
│       ├── AuthManager.swift        # JWT + user token management
│       ├── Commands/
│       │   ├── Playback.swift       # play, pause, skip, etc.
│       │   ├── Speaker.swift        # speaker list, set, add, remove
│       │   ├── Volume.swift         # vol commands
│       │   ├── Search.swift         # catalog search
│       │   ├── Library.swift        # add to library
│       │   ├── Playlist.swift       # playlist CRUD + share
│       │   └── Discovery.swift      # similar, suggest, new-releases
│       └── Models/
│           ├── Song.swift           # song model
│           ├── Speaker.swift        # speaker model
│           └── Output.swift         # JSON + human-readable formatting
├── commands/                        # plugin slash commands (call music CLI)
├── skills/music/SKILL.md            # updated skill referencing music CLI
├── scripts/statusline.sh            # calls music now --json
└── .claude-plugin/
```

## Installation & Binary Distribution

The `music` binary must be callable by name from slash commands, the skill, and the status line script. The plugin handles this at install time:

**Build step:** The plugin includes a `scripts/install.sh` that:
1. Runs `swift build -c release` in `tools/music-cli/`
2. Symlinks the built binary to `~/.local/bin/music` (or another PATH location)
3. Verifies the binary is callable: `music --version`

**Plugin references use the full path as fallback:** All slash commands and scripts reference the binary as:
```bash
MUSIC_CLI="${MUSIC_CLI:-music}"
```
This allows overriding via environment variable if the user prefers a non-PATH location.

**First-run experience:** If the binary isn't found, commands fall back to raw `osascript` (preserving current behavior) and print a one-time hint: "Run `scripts/install.sh` to enable catalog features."

## Plugin Integration

### Slash Commands

Existing commands (`/play`, `/vol`, `/speaker`, etc.) are rewritten to call the `music` CLI, but each command is responsible for translating its current argument grammar into the appropriate CLI flags. This is not a passthrough — each command parses its own input.

The current `/play` command accepts free-form text like `play radiohead on kitchen at 60`. The wrapper must decompose this into separate CLI calls:

```markdown
---
name: play
description: Play music
---
Parse the user's input to extract query, speaker, and volume.
Then invoke the appropriate `music` commands:
  - `music speaker set <speaker>` (if speaker specified)
  - `music vol <speaker> <level>` (if volume specified)
  - `music play --song <query>` or `music play --playlist <name>`
```

Each slash command preserves its existing user-facing contract. The CLI provides the primitives; the slash commands provide the natural-language-friendly grammar.

### Skill (SKILL.md)

Updated to document the full `music` CLI surface. Claude uses `music --json` variants for structured data. The skill describes available capabilities and when to compose multiple commands for complex requests.

### Status Line

The status line script consumes `--json` output and formats it using built-in shell tools (no external dependencies):

```bash
#!/bin/bash
JSON=$(music now --json 2>/dev/null)
if [ -n "$JSON" ]; then
    TRACK=$(echo "$JSON" | grep -o '"track":"[^"]*"' | cut -d'"' -f4)
    ARTIST=$(echo "$JSON" | grep -o '"artist":"[^"]*"' | cut -d'"' -f4)
    [ -n "$TRACK" ] && echo "$TRACK — $ARTIST"
fi
```

There is no `--statusline` output mode. The CLI supports exactly two output modes: default (human-readable text) and `--json`. Any specialized formatting is the caller's responsibility. The JSON output is simple enough to parse with `grep`/`cut`; no `jq` dependency required.

## Dependencies

- **Swift 5.9+** (macOS 14+)
- **CryptoKit** (standard library — JWT signing)
- **Foundation** (standard library — URLSession, Process)
- **No third-party packages**

Optional:
- **swift-argument-parser** — for cleaner CLI argument handling (recommended but not required)

## Setup for Users

### Minimal (playback only — no setup needed)
```
music play --playlist "Working Vibes"
music speaker set kitchen
music vol 60
```

### Full (catalog + library access)
```
music auth setup
→ Guided flow: enter key ID, team ID, copy .p8 key, browser auth for user token
```

## Open Questions

1. **Playlist delete/remove/share API endpoints** — Need to verify exact REST API endpoints and behavior for these operations before implementation. The Apple Music API documentation for library playlist mutation is sparse; may need to test empirically.
