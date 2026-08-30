# MusicTUI Guide

## What Is This?

MusicTUI controls Apple Music from the terminal: a TUI, a CLI, and a Claude Code plugin for macOS. Play music, manage AirPlay speakers, search the catalog, build playlists, play radio stations, and discover new tracks, all without leaving your coding session.

## Naming

One name for everything: **`music`**.

| Surface | Name | Example |
|---------|------|---------|
| Marketplace listing | Apple Music for Claude Code | `/plugin marketplace add anthonymaley/musictui` |
| Skill (natural language) | `/music` | `/music play kid a in the kitchen at 60`, or just talk to Claude |
| CLI binary | `music` | `music now`, `music search "Fouk"` |

The `name` field in `plugin.json` is `music`; this is what makes the skill appear as `/music` in the menu. "Apple Music" appears in descriptions and docs for discoverability. There are no per-action slash commands: the skill is the plugin's single entry point.

## Command Vocabulary

Long-form commands are the only registered surface: `music now`, `music volume`, `music speaker wake`. The CLI ships no short aliases: `music np` and `music vol` don't exist; define shell aliases yourself if you want them. Long-form keeps the README, marketplace copy, and skill reference searchable.

## How Users Interact

There are five interaction layers, from quickest to most flexible:

### 1. Media Keys (transport)

Play/pause, next, and previous live on your keyboard (⏯ ⏭ ⏮). They control Apple Music natively through macOS, from any app, with zero setup, zero tokens, and no plugin surface at all. The plugin deliberately ships no slash commands for transport: a hardware key beats any typed command.

### 2. Natural Language (Skill: `/music`)

The plugin's single entry point in Claude Code. Say what you want (playback with routing, search, library, playlists, discovery) and Claude composes the right `music` CLI calls.

```
> /music play kid a in the kitchen and living room at 60%
> play some Daft Punk on the kitchen speaker
> add the living room to the group and turn it down to 40
> find me something like what's playing and make a playlist
> what's new from Radiohead?
> make me a mix from Fouk and Floating Points
```

Play-shaped requests are a fast path: the skill forwards your words to `music play`, whose parser deterministically extracts the query, speaker names (several at once), filler words, and volume. Naming speakers plays on exactly those speakers. Everything else is composition: multiple CLI calls chained by Claude.

The skill triggers automatically when Claude detects music-related intent; `/music` invokes it explicitly. Requires the CLI to be built (one command: `scripts/install.sh`); if it's missing, the skill says so and points at the script.

### 3. Interactive TUI

Run bare `music` in a real terminal for the unified interactive shell: a tabbed interface with **Now**, **Discover**, **Library**, **Playlists**, **Radio**, and **Speakers** tabs.

```
music                           Unified shell: Now / Discover / Library / Playlists / Radio / Speakers tabs
```

Current TUI contract:

- The Playlists tab does not fetch tracks on every playlist highlight; it loads tracks on selection. `/` filters the playlist rail as you type (arrows still navigate while filtering). When signed in, the focused playlist's hero shows its real cover art; built-in smart playlists (Recently Played, Top 25…) aren't API-visible and keep the generated placeholder.
- Apple-curated playlists added to the library (AppleScript class `subscription playlist`) appear in the rail with an `APPLE` badge. They're read-only on Apple's side: edits fail with a toast, by design.
- Selecting a playlist pins it on the Now tab, which shows the full playlist and keeps `↑↓` navigation local.
- The Now tab shows the current album context, not a real Apple Music queue.
- Quitting the TUI saves the app-owned queue to `~/.config/music/queue.json`; relaunch adopts it again if the same track is still playing, so an album keeps its scoped Up Next across a restart. The match is strict: if a track ended during the quit→relaunch gap, the saved queue is discarded rather than resumed one track off.
- The Library tab (no token needed) browses your library through one bulk AppleScript read of Music's Library playlist (about a second for 14,000 tracks) in three sub-views: Artists, Albums, Songs (opens on Artists), switched with `[`/`]`. Enter opens an album's tracks or drills Artist → their albums → tracks; `p` plays and `s` shuffles the focused item (albums/artists play as app-owned queues, a scoped, navigable Up Next that stops at the album's end; needs Music's Autoplay ∞ off). On the Artists list, `a` cycles a track-count filter: All → 12″/EP (artists with a 2 to 5 track release) → Albums (artists with a 6+ track album). It separates 12″s/EPs (which dominate house/electronic libraries) from full-album deep cuts, and the one-track "album" Apple creates for a loose playlist song falls in neither tier (otherwise the filter would keep the very playlist artists it's meant to drop). Drilling into an artist while a tier is active shows only that tier's albums (their 6+ LPs under Albums, their 2 to 5 releases under 12″/EP). Apple's library-artists list otherwise includes every artist with any library track, so it bloats fast. The first activation each session paints instantly from a cache (`~/.config/music/artist-tiers.json`, revalidated in the background); the match is a lowercase artist name (compilations / "feat." credits may miss). The focused album's hero shows its real cover (the track's embedded artwork, or with a developer key and sign-in Apple's library lookup as a fallback; bytes cached once in `~/.config/music/art-cache/`, gradient placeholder while loading or when no cover can be found); on kitty-protocol terminals (iTerm2 3.5+, Kitty, WezTerm, Ghostty) covers render as true pixels, elsewhere as chafa half-blocks (plain brightness-mapped blocks when chafa isn't installed), with a gradient placeholder while art loads or when there is none. Vim keys work everywhere: j/k/h/l, g/G, ctrl-d/ctrl-u (l and g/G keep their love/Genius meanings on the Now tab).
- The Discover tab (needs the user token) shows Apple's For You rails, with Recently Played hoisted to the top; the default view holds five curated rails, four items each. Navigation is three levels deep: Discover, then a rail, then a track list, and each level keeps its own cursor and scroll position. `r` refreshes the top level; `←` or `Esc` goes back a level; `→` drills in and never plays. `Enter` plays a station outright, opens a read-only track list for an album or playlist, opens the full rail for a `View all N` row, and does nothing yet for a track inside a drill-in: playing from a chosen track partway down an album is deferred, because the only mechanism that keeps a bounded queue starts a playlist from its beginning. `p` plays an album or playlist row directly, bounded to it, and does nothing on a station, a `View all N` row, or a track row. Playing this way adds the album to your library, and it stays there: Discover creates a temporary playlist to play it and removes that playlist afterward, but leaves the songs it added behind, because Apple gives no way to prove which library rows this app added versus ones you added yourself, so an automatic cleanup could delete music you added deliberately. See `docs/platform-notes.md` for the platform limits behind this.
- The Radio tab browses stations in three sub-views: Favorites, Live, Personal. It opens on Favorites, switched with `[`/`]`. Favorites needs no token at all (it reads and plays straight from disk); Live and Personal need a developer token to load.
- Radio keys: `Enter` (or `→`) plays the selected station, `f` favorites/unfavorites it. Of the vim aliases, only `j`/`k` (down/up) and `l` (→, which plays) do anything here. `h`, `g`/`G`, and ctrl-d/ctrl-u are inert on this tab.
- `/` opens a catalog search: it's the same `/` everyone reaches for everywhere else in the shell, but on Radio it runs a network search rather than filtering the current sub-view (Favorites/Live/Personal are short, scannable lists; a local filter isn't worth stealing `/` from search). Type a term, `Enter` runs it; hits land in the list, `f` favorites one, `Esc` clears back to the sub-view.
- `a` opens an add-by-URL field. Paste a station's share URL to favorite it directly: it's added from the URL immediately, so it's never lost even when the catalog can't resolve it, and a later resolve just upgrades the name and art in place. Anything that isn't a URL is rejected with a message pointing at `/` instead of being guessed at as a search term.
- Live stations show a `LIVE` badge instead of a progress bar (a livestream carries no duration). Favorites persist locally at `~/.config/music/stations.json` and do not sync across devices.
- Apple's station search is shallow (5-7 results, no pagination) and misses real stations outright. It cannot find BBC Radio 1 by name or even by its own catalog id, though the station plays perfectly once you have its URL. An unresolved station's name falls back to a title-cased slug from the URL, e.g. "Bbc Radio 1".
- `Enter` plays the highlighted row.
- Keys: `1/2/3/4/5/6` jump to a tab, `Tab`/`Shift-Tab` cycle, `[`/`]` switch Library sub-view or Radio Favorites/Live/Personal, `a` cycle Library Artists tier (All / 12″/EP / Albums) or open Radio's add-by-URL field, `↑↓` + `PgUp/PgDn/Home/End` navigate (Radio has no page/home/end jumps), `Space` play/pause, `</>` previous/next, `[ ]` seek (Now) / `←→` per-speaker volume (Speakers), `z` shuffle-play, `l` favorite (Now) / `f` favorite (Radio), `+/-` master volume, `n` next-up options, `/` filter (Playlists/Library) or search (Radio), `Esc` back, `q` quit.
- The Now tab has a **playback-control grid** (Shuffle / Order / Repeat / Genius) under the track progress, showing each value live with the active one lit. Press `←` to focus the grid and `→` to return to the Up Next list; `↑↓` move between control rows and `Enter` cycles the focused row's value (Shuffle on/off, Order Songs→Albums→Groupings, Repeat Off→All→One, Genius triggers). The `s`/`m`/`r`/`g` keys do the same from anywhere. Shuffle/order/repeat write Music's state directly (no extra permission); Genius rebuilds the queue from the current song and is UI-scripted (needs the same Accessibility permission as the equalizer). Distinct from the global `z` (footer: *Reshuffle*), which shuffle-plays the current context.
- Named-speaker `music play`, and `music speaker` add/`set`/`only`, verify the route automatically while playing (network-truth: established TCP connections to the speaker, not the AppleScript `selected` claim, which can lie) and print `✓ <speaker> verified (…)`; while paused, routing prints `Route set; will verify on next play.` instead, since a paused route can't be network-verified. An unestablished route triggers an automatic heal (an away-and-back reroute, then a transport-cycle reset) before an honest failure names the manual fix. `music speaker wake` also verifies first now and resets only the routes that are actually broken; the rest print `✓ X verified` and are left alone. Routing to the Mac's own output is never "verified": local output has no AirPlay session.
- Toggling a speaker on in the Speakers scene while playing verifies the route the same way and toasts if it couldn't be verified; toggling off, or toggling while paused, skips verification.
- The Speakers scene has an **EQ block**: an `EQ on/off` power row (`Enter` toggles it; `e` does the same from anywhere in the scene) and a `Preset` row beneath it: `Enter` expands an inline preset picker (venue pack first, then Music's built-in presets), `↑↓` to navigate, `Enter` to select and auto-enable EQ, `Escape` to collapse without changing the preset. With the Preset row highlighted but the picker collapsed, `←`/`→` quick-cycles presets one at a time.
- Below the EQ block, a **Visualizer** row toggles Music's on-screen visualizer (`Enter`, or `v` from anywhere in the scene). GUI-only: the visuals render in the Music window on the Mac's display, and turning it on brings Music forward.
- Music's Autoplay (∞) must stay OFF: playlist track-selection drives playback track-by-track and relies on each track stopping at its end.

### 4. Status Line

A passive display at the bottom of Claude Code showing what's playing: track, speakers, volume. Always visible, zero token cost.

```
┌──────────────────────────────────────────────────────────────┐
│  claude >                                                    │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  ▶ Everything In Its Right Place — Radiohead  ·  Kitchen [60]│
└──────────────────────────────────────────────────────────────┘
```

Enable in `~/.claude/settings.json` (after running `scripts/install.sh`, which installs the script to a stable, update-proof path):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.local/bin/music-statusline"
  }
}
```

### 5. Direct CLI (`music`)

For power users who want to use music outside Claude Code, in scripts, shell aliases, or other tools. The CLI has `--json` output for every command, making it scriptable.

```bash
music now --json
music search "Fouk" --limit 20 --json
music add --to "House"             # add current song to a playlist
music remove                       # remove current song from current playlist
music speaker verify --json        # network-truth verdict for selected speakers
music playlist list --json
music radio list                   # favorite stations
music radio play "bbc radio 1"     # play a favorite, or paste a station URL
```

Errors go to **stderr** (and `--json` mode emits an error object rather than corrupting the stream), so stdout stays clean for piping; previously-silent failures (a failed AirPlay route, a malformed config, dropped playlist indices) now print a `✗`/`⚠` line.

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
│  │           Swift binary, 27 subcommands              │     │
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
  Radio playback ──► station share URL, https:// swapped to music://,
                     handed to `open` — no AppleScript, no REST write;
                     favorites live in ~/.config/music/stations.json
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
5. Verifies each route (network-truth) once playback starts;
   an unestablished route heals automatically before an honest failure
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

### How a radio play executes

```
User says:  put on BBC Radio 1

1. Claude detects music intent → loads music skill
2. Skill resolves to: music radio play "bbc radio 1"
3. RadioPlay checks favorites first (no network) — if it's not
   there, and the argument looks like a music.apple.com station
   URL, plays it directly
4. Otherwise falls back to catalog search (needs a developer
   token); the first hit plays
5. Playback is a URL scheme swap — the station's share URL with
   https:// rewritten to music:// — handed to `open`. No
   AppleScript, no MusicKit; the current AirPlay route survives
6. If search finds nothing (Apple's station search is shallow and
   misses real stations, e.g. BBC Radio 1), Claude asks for the
   station's music.apple.com URL instead of claiming it doesn't
   exist
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
├── .github/workflows/pages.yml  # Deploys site/ to GitHub Pages (musictui.com)
├── site/                        # musictui.com — static page + assets
├── media/                       # README screenshots + demo gif
├── skills/music/
│   └── SKILL.md                 # Conversational skill (music CLI reference)
├── scripts/
│   ├── statusline.sh            # Status line (now playing)
│   ├── airplay-live-probe.sh    # AirPlay route diagnostics
│   └── install.sh               # Build + install music CLI
├── tools/music/                 # Swift CLI source
│   ├── Package.swift            # SPM manifest
│   ├── Sources/
│   │   ├── Music.swift          # @main, all 27 subcommands registered
│   │   ├── StatusReporter.swift # --verbose diagnostics on stderr
│   │   ├── Backends/
│   │   │   ├── AppleScriptBackend.swift   # osascript wrapper + watchdog timeout
│   │   │   ├── AppleScriptEscaping.swift  # one escaping helper
│   │   │   ├── LibraryLookup.swift        # one library-track lookup script
│   │   │   └── RESTAPIBackend.swift
│   │   ├── Auth/
│   │   │   ├── AuthManager.swift
│   │   │   ├── JWTGenerator.swift
│   │   │   └── AuthPage.swift
│   │   ├── Commands/
│   │   │   ├── PlaybackCommands.swift     # play/pause/skip/back/stop/now/seek/shuffle/repeat
│   │   │   ├── PlayParser.swift           # play arg parser: query/speakers/volume/shuffle
│   │   │   ├── PlayResolution.swift       # play query resolution order
│   │   │   ├── LoveCommands.swift         # love/unlove
│   │   │   ├── HistoryCommands.swift      # recent/rotation
│   │   │   ├── SpeakerCommands.swift
│   │   │   ├── VolumeCommands.swift
│   │   │   ├── AuthCommands.swift
│   │   │   ├── SearchCommand.swift
│   │   │   ├── AddCommand.swift
│   │   │   ├── RemoveCommand.swift
│   │   │   ├── PlaylistCommands.swift
│   │   │   ├── RadioCommands.swift        # radio list/play/add/search
│   │   │   ├── DiscoveryCommands.swift
│   │   │   └── MixCommand.swift
│   │   ├── Models/
│   │   │   ├── OutputFormat.swift
│   │   │   └── ResultCache.swift
│   │   └── TUI/
│   │       ├── Terminal.swift             # raw mode + key parsing (timed ESC disambiguation)
│   │       ├── ArtworkStore.swift         # cover-art fetch/cache + render ladder
│   │       ├── KittyGraphics.swift        # kitty graphics protocol (true-pixel covers)
│   │       ├── NowArtwork.swift           # Now-tab REST artwork lookup
│   │       ├── VimKeys.swift              # j/k/h/l, g/G, ctrl-d/u aliases
│   │       ├── LibraryDataSources.swift   # library browse: one AppleScript bulk read, grouped in Swift
│   │       ├── LibraryNav.swift           # Library tab navigation reducer
│   │       ├── RadioCatalog.swift         # catalog station search/resolve (REST)
│   │       ├── RadioNav.swift             # Radio tab navigation reducer
│   │       ├── StationStore.swift         # local favorites (stations.json)
│   │       ├── StationPlayback.swift      # https:// → music:// URL rewrite
│   │       ├── PlaylistBrowserModel.swift, PlaylistDataSources.swift
│   │       ├── NowPlayingTUI.swift, TUILayout.swift
│   │       ├── ListPicker.swift, MultiSelectList.swift, VolumeMixer.swift
│   │       └── Shell/                     # unified tabbed shell (bare `music`)
│   │           ├── Shell.swift, Router.swift, Scene.swift
│   │           ├── GlobalKeymap.swift, ShellActions.swift, ControlGrid.swift
│   │           ├── NowPlayingScene.swift, LibraryScene.swift, PlaylistsScene.swift
│   │           ├── RadioScene.swift, SpeakersScene.swift
│   │           ├── NowPlayingStore.swift, PlaybackPoller.swift, PlaybackContext.swift
│   │           ├── AppQueue.swift         # app-owned playlist queue
│   │           ├── QueueResume.swift      # queue save/restore across TUI restarts
│   │           └── ShellChrome.swift, ShellFrame.swift
│   └── Tests/MusicTests/                  # unit suite (parsers, layout, stores, key parsing)
├── docs/
│   └── guide.md                 # This document
├── README.md                    # GitHub-facing docs
└── LICENSE                      # MIT
```

## Auth

The plugin works at three levels depending on what's configured:

| Level | What you need | What you get |
|-------|--------------|-------------|
| **No auth** | Just install the plugin | Playback, speakers, volume, now playing, shuffle, repeat, radio favorites (list/play/add by URL), Library tab (artists, albums, songs), library search (`music search --library`), playlist create and add by index from a library search |
| **Developer token** | Apple Developer account + MusicKit key | Above + catalog search (100M+ tracks), radio catalog search |
| **Full auth** | Above + user token from browser | Above + add to library, playlist CRUD, similar tracks, suggestions, new releases, mixes, recently played, heavy rotation, Discover |

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

All three are written owner-only: files `0600` in a `0700` directory (since 3.7.1; the embedded auth-page server writes the token the same way). Tighten a pre-3.7.1 install with `chmod 700 ~/.config/music && chmod 600 ~/.config/music/{config.json,user-token,AuthKey.p8}`.

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
| Speaker shows selected but stays silent (ghost) | Music's `selected`/`active` scripting read-backs can lie about the real session | Run `music speaker verify --json` before touching anything — keep the output as evidence |
| Radio search misses real stations (BBC Radio 1 unresolvable even by id) | Apple's station search/lookup API is shallow and incomplete | Paste the station's share URL — `music radio play <url>` / `music radio add <url>` always works |
| `play track N of playlist X` silently broken | macOS 26 scripting regression | App-owned queue drives playback track-by-track (Autoplay ∞ off) |
| `loved` property errors | macOS 26 renamed it `favorited` | `music love`/`unlove` write `favorited` |
| `current track` reads throw -1728 on streamed tracks | macOS 26 scripting bug (filed FB19908171) | Queue resume anchors by name+artist when the persistent-id read throws |

## Version

Current version: v3.10.1. All five locations stay in sync:
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`
- `tools/music/Sources/Music.swift` → `CommandConfiguration(version:)` (rebuild via `scripts/install.sh` so `music --version` matches)
- this line, which carries the version in prose
