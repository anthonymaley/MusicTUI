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
│       ├── Music.swift        # @main entry, 24 subcommands
│       ├── Backends/
│       │   ├── AppleScriptBackend.swift  # osascript wrapper
│       │   └── RESTAPIBackend.swift      # Apple Music API (URLSession)
│       ├── Auth/
│       │   ├── AuthManager.swift     # Config + token management
│       │   ├── JWTGenerator.swift    # ES256 JWT from .p8 key (CryptoKit)
│       │   └── AuthPage.swift        # MusicKit JS HTML for user token
│       ├── Commands/
│       │   ├── PlaybackCommands.swift   # play, pause, skip, back, stop, now, seek, shuffle, repeat
│       │   ├── LoveCommands.swift       # love/unlove (macOS 26: property is `favorited`)
│       │   ├── HistoryCommands.swift    # recent (played history), rotation (heavy rotation)
│       │   ├── SpeakerCommands.swift    # speaker list/set/add/remove/stop/wake
│       │   ├── VolumeCommands.swift     # vol get/set/up/down/per-speaker
│       │   ├── AuthCommands.swift       # auth setup/status/open/set-token
│       │   ├── SearchCommand.swift      # catalog search
│       │   ├── AddCommand.swift         # add to library / playlists
│       │   ├── PlaylistCommands.swift   # full playlist CRUD + share + temp (REST writes)
│       │   ├── DiscoveryCommands.swift  # similar, suggest, new-releases
│       │   ├── MixCommand.swift         # build mixed playlists
│       │   └── RemoveCommand.swift      # remove track from playlist
│       ├── Models/
│       │   ├── OutputFormat.swift    # --json vs human-readable
│       │   └── ResultCache.swift     # domain-specific song/speaker caches
│       └── TUI/
│           ├── Terminal.swift        # raw mode, ANSI codes, key reading
│           ├── TUILayout.swift       # shared ScreenFrame, renderShell
│           ├── MultiSelectList.swift # speaker picker, track selector
│           ├── ListPicker.swift      # quick pickers (similar/suggest)
│           ├── VolumeMixer.swift     # per-speaker volume mixer
│           ├── NowPlayingTUI.swift   # legacy now-playing rendering helpers
│           ├── PlaylistBrowserModel.swift / PlaylistDataSources.swift
│           └── Shell/                # unified tabbed shell (bare `music`)
│               ├── Shell.swift / Router.swift / Scene.swift / GlobalKeymap.swift
│               ├── NowPlayingScene / PlaylistsScene / SpeakersScene
│               ├── NowPlayingStore / PlaybackPoller / PlaybackContext
│               ├── AppQueue.swift    # app-owned playlist queue
│               └── ShellActions / ShellChrome / ShellFrame
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
Published via Claude Code marketplace. Version bumps must update all four locations (see CLAUDE.md) and rebuild via `scripts/install.sh`. Tag releases (`git tag vX.Y.Z`) and publish a GitHub release (`gh release create`) — releases had silently stopped at v1.6.1 while ten versions shipped untagged.

## Gotchas
- **Apple-curated playlists are class `subscription playlist`, not `user playlist`** — `every user playlist` silently omits them (verified live: 49 user + 9 subscription + 1 library = 59). Resolve by bare name (`playlist "Loops"`) and they work like any playlist for reads/playback; they're read-only for writes. Their `smart` property errors with -1700 on coercion — always try-wrap it.
- **`gh release create --notes` via a quoted heredoc (`<<'EOF'`) keeps backslash escapes literal** — `\\`` shows up verbatim in the published body. Backticks need no escaping inside a quoted heredoc. Read the body back (`gh release view --json body`) before calling it done.
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
- **`every track of playlist` is a per-element trap** — `repeat with t in (every track of playlist "X")` accessing `name of t`/`artist of t` does an Apple Event round-trip *per element*: ~3.77s for 200 tracks of the 13.6k-track library playlist. Fetch properties in bulk: `set total to count of tracks of playlist "X"`, then `name of tracks 1 thru n of playlist "X"` + `artist of tracks 1 thru n` (clamp `n` to `total`, guard `n > 0`), join in-memory. ~0.21s (~18×). Never enumerate per-element for track properties.
- **Version lives in 4 places** — keep `plugin.json`, `marketplace.json` (metadata + plugins[0]), AND `tools/music/Sources/Music.swift` `CommandConfiguration(version:)` in sync; rebuild via `scripts/install.sh` so `music --version` matches.
- **`play track N of playlist X` is broken in macOS 26.x — the app owns the playlist queue now** (see `Sources/TUI/Shell/AppQueue.swift`). Exhaustively verified live: (1) `play track N of playlist X` sets `current playlist` to the library and, at track end, bleeds into Autoplay — no navigable queue at all; (2) `play playlist X` keeps context but resumes at the playlist's *sticky* position (NOT track 1) and backward nav FLOORS there, so "tracks above" can't reach track 1; (3) a fresh temp-playlist copy *also* starts mid-list and clutters the user's iCloud library. None give "playlist positioned at N with full up/down." **Resolution:** don't rely on Music's queue — the app holds the ordered track list (`AppQueue`) and drives playback itself: `play track N of playlist X` for one track, and `PlaybackPoller` plays the next when it stops at end. `next`/`prev`/`Enter` navigate our list (full up/down, immune to the regression). **Hard dependency: Music's Autoplay (∞) must be OFF** — `once` is ignored, so with Autoplay on a single track bleeds into the library before the poller can advance. Whole-playlist `play playlist X` (the `p` key) still uses Music's gapless native queue.
- **Native radio = the "Create Station" menu, not a verb** — Music.app's AppleScript dictionary has NO station/radio/genius command. The only route to start a station is System Events clicking `Song ▸ Create Station`, which needs (a) Music FRONTMOST (`tell application "Music" to activate` first, then restore the prior front app) and (b) the clicking process to hold **Accessibility** permission. Apple Events permission (control Music) ≠ Accessibility permission (click its UI): the `music` binary gets the former via the terminal but apparently not the latter, so the click silently no-ops. Treat native radio as fragile / possibly unavailable from the CLI.
- **`runMusic` wraps in `tell application "Music"`** — do NOT route System Events / GUI-automation scripts through it; nesting a `tell application "System Events"` click inside the `tell Music` block is a no-op. Use the raw `backend.run()` for those.
- **Shell unit tests are pure-model only** — they cover zones/parsing/router/frame math and prove NOTHING about playback context, AirPlay, or macOS permissions. For anything AppleScript/Music.app/TCC-dependent, build-green ≠ verified; confirm live, and after one live failure on a symptom, change layers rather than ship another same-shape patch.
- **Live verification of the Now tab must cover BOTH playback context modes** — app-owned queue (track picked in the TUI) AND Music-native context (`p`/`s`, `music play <playlist>`). The 1.14.1 regression hid in the native mode the bundle-2 verification didn't exercise; the two modes take different code paths for Enter, next/prev, and Up Next sourcing.
- **`swift build` green ≠ `swift test` green — run the test target after any refactor.** The executable target and the test target compile separately, so a refactor (e.g. removing `radio`, adding `AppQueueStore` to `NowPlayingScene.init`) can leave `swift build` passing while the test target *won't even compile*. Worse, the compiler halts at the first batch of errors per file, so an initial `swift test` reports only the *floor* of the drift — fix those, re-run, and more surfaces (this is how `QueueEndTests` stayed hidden behind `SceneInputModeTests`/`GlobalKeymapTests`). Iterate `swift test` to actual green; one run is not a clean bill. Keys that moved in 1.11.0: continuation menu shuffle is `s` (was radio `r`); global `r` now aliases shuffle.
- **Concatenated AppleScript batches fail all-or-nothing under concurrent load** — `onMeta` builds one script for N playlists; at startup the poller + preview fetches hammer Music in parallel, so a batch can transiently error and (with `try? syncRun`) silently return `[:]` — blanking exactly `chunkSize` rows (the giveaway: 8 missing = one failed batch of 8). Each individual playlist works when retried alone. Fixes: (a) wrap each playlist's clause in its own `try` so one bad entry can't abort the batch and partial results survive; (b) the background refresh retries any index that didn't come back, with backoff, until all resolve. Playlist rail metadata is cached to `~/.config/music/playlist-meta.json` (keyed by name) and seeded on launch for an instant paint; the off-thread refresh rewrites it.

## Current Status
**1.17.0 — Apple-curated playlists in the TUI rail.** Curated playlists added to the library are class `subscription playlist`, not `user playlist` — the rail's `every user playlist` omitted all 9 of the user's (Loops, Replay 20xx, Microhouse/Nu Cumbia Essentials, Gliding); only manual duplicates ever showed. `fetchUserPlaylistNames` now enumerates both classes in one call (`U`/`S` + unit-separator lines; pure `parseRailPlaylistNames` tested), `PlaylistsScene` badges them APPLE (radio > recent > apple > smart). Downstream untouched — everything resolves `playlist "name"` generically (bulk reads verified live on "Loops"). Writes fail honestly via toast (Apple-side read-only). Suite 112. Live-verified: rail + track browse in tmux; playing one NOT yet verified (user's music was playing).

**1.16.1 — docs synced with reality, first GitHub release since v1.6.1.** README TUI key tables regenerated from `GlobalKeymap.swift` + scene handlers (the old table predated the tabbed shell); guide.md counts (14 commands / 24 subcommands), source tree, and 4-location version rule refreshed; SKILL.md description gained favorites/seek/listening-history triggers; playbook tree updated (Shell/, LoveCommands, HistoryCommands). Tagged `v1.16.1` + GitHub release published (notes digest 1.7.0→1.16.1). Tend audit: structure clean; OPEN — the `.gitignore` "Dev-only files" block is a no-op (its files are tracked); decide intent, then remove the dead entries + on-disk `.DS_Store`s.

**1.16.0 — review backlog cleared (verified live).** TUI: PgUp/PgDn/Home/End everywhere + Shift-Tab reverse cycle; arrows navigate WHILE filtering (fzf-style); one selection language (inverse-video cursor on all tabs); empty Now tab is an on-ramp ("press 2 / z"); art skipped below 52 cols (it corrupted narrow frames); `l` favorites the current track (toast feedback). CLI: `music seek +30|90|1:30` (gotcha: `round (player position)` inline errors -1700 — assign to a var first; and the position readback lags a `set` while paused, hence the `delay 0.2`), `music love`/`unlove` (macOS 26: property is `favorited`; `loved` errors -10001, verified live), `music recent` (gotcha: docs say `/recent/played-tracks` but the live API serves `/recent/played/tracks` — hyphenated 404s; verified live, results feed ResultCache so `play N` chains), `music rotation` (endpoint reachable; this account's heavy-rotation is empty). Field delimiter hardening: track-data scripts/parsers use ASCII unit separator (`asFieldSep`) instead of `|` — titles like "Intro | Outro" no longer shift fields. Plugin: `/music:repeat` added (14 commands now), play.md collapsed to the CLI's native smart parsing, statusline prefers jq. Hygiene: AppQueueStore step/jump/shuffle-order finally tested (the 1.10.0 core), OutputFormat.renderHuman deterministic. Suite: 107 tests green.

**1.15.0 — AirPlay performance + stability, CLI ergonomics (verified live).** AppleScriptBackend has a watchdog: every osascript is killed after `timeout` (default 45s) and throws `ScriptError.timeout` — before this, one hung `set selected` (sleeping HomePod) blocked the shell's whole serial action queue for up to the 2-minute Apple Event timeout or forever; pipes are now read before `waitUntilExit` (deadlock fix); -1728 "Can't get AirPlay device" maps to the actionable `speakerUnavailable`. `fetchSpeakerDevices` is ONE bulk script (4 Apple Events total — measured 6x faster than the per-device loop: 0.21s vs 1.23s for 11 devices), linefeed-block format immune to commas in device names, write-through to the speakers cache; `resolveSpeakerName` is cache-first (named speaker/volume commands: 3 spawns → 1, measured 0.28s). `showNowPlaying` no longer enumerates AirPlay inside its 10× retry loop. `speaker X only` selects the target FIRST (the old deselect-all-then-select could leave NO outputs if the target failed) with per-device try. `speaker wake` verifies each speaker is actually back in the group and prints "Lost X" honestly (it used to claim Reset for silently dropped speakers); SpeakersScene un-wedges a stuck background fetch after 30s. Ergonomics: `music similar Hotel California` parses as one title (+`--artist`); `music shuffle` toggles with no arg (slash command simplified); `music volume abc` errors instead of silent exit-0; `playlist delete` confirms on a TTY (`--force` skips); `--json` honored on remove/volume/shuffle/playlist create/add/delete; dead `--no-wake` flag removed. Docs: bare `music` is the MAIN TUI; the four quick pickers (speaker/volume/similar/suggest) are blessed one-shots backing the slash commands. NOT live-tested: the watchdog firing on a real hang (no sleeping HomePod available during the session) — logic is simple and unit-reasoned, tagged for the next natural occurrence.

**1.14.1 — wrong-track-on-Enter / library-collapse fix (verified live).** Two stacked bugs in the Now tab. (1) The 1.12.0 fast-publish made the cursor snap consume a track change against the PREVIOUS context's rows — the cursor parked on a stale position and never re-snapped; Enter then played a row the user didn't pick. Fix: `snapCursorIndex` only matches a row that is current AND is the new track; an unconsumed change retries next tick. **Gotcha for any future early-publish: every consumer keying off "the snapshot changed" must tolerate a snapshot whose secondary fields are stale.** (2) Pre-existing: with a native whole-playlist play (`p`/`s`, `music play <playlist>` — no app queue), Enter played the row from the Library, collapsing Music's context to the alphabetical library (the R5-class symptom). Fix: Enter now ADOPTS the app-owned queue from the context playlist (fetch tracks, verify the row lines up, take over at that position); album/library contexts still fall back to the library lookup.

**1.14.0 — REST playlist writes (verified live end-to-end).** Playlist create/add go through the Apple Music API directly: `createPlaylist(name:songIDs:)` creates and seeds tracks in ONE call (`relationships.tracks`), `addTracksToPlaylist` posts catalog IDs straight to `/v1/me/library/playlists/{id}/tracks`. The `addToLibrary → sleep 4s → AppleScript "duplicate" by title` dance is gone from all six call sites (playlist create/add/create-from, add --to, discovery create/shuffle, mix). Measured: create-with-2-tracks 0.56s (was 4s+), add 1.2s. Every user-created playlist is API-visible (verified live; only built-in smart playlists aren't) — the AppleScript duplicate survives only as `duplicateLibraryTrack` fallback. New `libraryTrackLookupScript` is the one definition of the exact-then-contains library lookup (was ~10 hand-rolled copies); the last manual `.replacingOccurrences` escape chains are gone. Server→local sync is fast but not instant (~2s for the playlist, tracks trickle) — `waitForLocalPlaylist` polls (bounded) before AppleScript plays an API-created playlist. Behavior change: playlist adds no longer copy songs into the library as a side effect.

**1.13.0 — TUI feedback channel (verified live in tmux).** The shell now has an error/feedback path: a `StatusStore` toast borrows the footer line for ~3s (amber info, red error). Every user-initiated AppleScript action moved off the input loop onto one serial `ActionRunner` queue — failures post a toast instead of vanishing into `try?`. Master volume (relative) and per-speaker volume (absolute) keypresses are coalesced, so holding a key never builds an osascript backlog. SpeakersScene loads async ("Loading speakers…") and refreshes on re-entry + every 5s, with a staleness guard so a refresh that started before a user mutation can't revert the optimistic UI. Playlist full-track lists load async with a "Loading…" pane (Enter on a 13.7k-track playlist no longer freezes the shell). Continuation menu: Quiet moved `q`→`x` (`q` quits even with the menu up), Esc dismisses auto menus. `playLibraryTrack` reports PLAYED/NONE so "not found in library" surfaces. Live-verified: speakers async load + refresh reconcile, big-playlist async tracks, responsive input throughout. Known cosmetic finding: inactive AirPlay devices report the master volume (they move in lockstep) — platform behavior, visible now that the scene refreshes.

**1.12.0 — TUI responsiveness (verified live in tmux).** Track changes publish metadata within one poll cycle: the poller writes the new track's snapshot immediately (cached-or-blank art) before the context fetch + artwork extract+chafa chain, instead of after it. Rendered art is cached per album|artist. The 1s poll script is lean (no AirPlay enumeration, no loved/disliked — nothing rendered them). Playlist preview fetches moved off the input loop (serial queue + inbox, same pattern as the meta refresh) — cursoring the rail no longer freezes input per uncached row. The shell repaints only on change (store generation counter + scene `tick() -> Bool` dirty flag + keypress + resize) instead of ~10 full truecolor frames/sec, wrapped in synchronized-output escapes. Verified live: first paint, all tabs, preview async fill, app-queue step reflected in ≤1.2s.

**1.11.2 — review fixes.** Album-context Enter-jump no longer uses the regressed `play track N of current playlist` — it plays the row by library title/artist lookup, the same verb the poller's auto-advance uses (duplicate titles resolve to the first match). `music remove` now escapes the playlist name (was the one unescaped interpolation site). Dead code from the 1.10/1.11 refactors deleted (`nextEnrichmentBatch`, `splitTrackLine`, `clearBlock`, `playTrackInCurrentPlaylist`, unused `TimelineRow` fields); suite is 77 tests green.

**1.11.0/1.11.1 — one TUI.** Standalone `music now`/`music playlist browse` TUIs and radio removed (~1500 lines); bare `music` is the only interactive surface, shuffle (`z`/`r`) replaced radio. Scene-aware footer + prominent ♪ playlist name on the Now tab. Playlist rail metadata cached to disk (1.10.1) for instant paint.

**1.10.0 — app-owned playlist queue (routes around the macOS 26.x regression).** Picking a track in a playlist now registers an in-memory `AppQueue` (full ordered track list) and drives playback track-by-track; `PlaybackPoller` auto-advances on natural end, `next`/`prev`/`Enter` navigate our list — full up/down restored, immune to Apple's broken `play track N of playlist X`. **Requires Music Autoplay OFF** (verified live). **Radio removed** from the shell (Accessibility-walled, unfixable) and replaced by **shuffle** (`z`/`r`, and the end-of-queue menu's `[S]`). Whole-playlist `p`/`s` still use Music's native gapless queue.

**1.9.0 — unified TUI shell.** Bare `music` launches one navigable app: a single `runShell` loop, `Router` scene stack, `ShellFrame`, global keymap, and a background `PlaybackPoller`/`NowPlayingStore`. Three scenes: **Now Playing**, **Playlists** (3-zone browser as a tab), **Speakers**. The 13 slash commands, conversational skill, and status line are unchanged; the shell is only what bare `music` opens in a TTY.

**Architecture decision (researched + verified):** AppleScript (control of Music.app) + REST (catalog/library/recommendations data) is the only viable stack for a no-paid-account, native-macOS CLI. MusicKit/MediaPlayer/MediaRemote/browser are evaluated-and-rejected. Native radio is a permission gap (removed); the playlist-queue gap is now solved app-side.
