# AirPlay Resilience & CLI Polish

Improve AirPlay speaker reliability with a wake cycle, add missing TUI state indicators, and improve CLI feedback during operations.

## Problem

AirPlay speakers often report `selected = true` but don't actually play audio — the "ghost speaker" problem. The only known fix is a deselect/reselect cycle. Today the CLI has no awareness of this failure mode: speaker commands are fire-and-forget, errors in the TUI are silently swallowed, and there's no way to diagnose what went wrong.

Secondary friction: the Now Playing TUI doesn't show play/pause or shuffle/repeat state, long operations (library sync, playlist creation) are silent, and there's no verbose/debug mode.

## Scope

**In scope (this round):**
- AirPlay wake cycle on routed playback
- Explicit `music speaker wake` command
- Better speaker error messages
- TUI play/pause + shuffle/repeat indicators
- Progress feedback on silent waits
- `--verbose` flag

**Out of scope (later):**
- Full osascript timeout plumbing everywhere
- Full error taxonomy redesign
- Cache management surface
- Seek/scrub in TUI
- Queue display beyond +/-4 tracks
- NO_COLOR support

## Architecture: Three Layers

Each layer is independently shippable. Layer N depends on layer N-1.

---

## Layer 1 — Plumbing

### `--verbose` flag

- Add `--verbose` (`-v`) to the root `Music` command via ArgumentParser.
- Store as `Music.verbose: Bool` — set once at process start, read-only thereafter.
- When enabled, print diagnostic lines prefixed `[verbose]` to stderr.
- Stderr keeps verbose output out of JSON output and piped workflows.
- `--verbose` is always allowed, even with `--json`. JSON goes to stdout, verbose goes to stderr. They don't interfere. This follows the Unix convention: stderr is for diagnostics regardless of output format.
- Similarly expose `Music.isJSON: Bool` for `withStatus` suppression (withStatus is suppressed in JSON mode because it's UX chrome, not diagnostics).

Verbose output in this round:
- Speaker name resolution: `[verbose] resolved "kitchen" -> "Kitchen HomePod"`
- Wake cycle steps: `[verbose] deselecting Kitchen HomePod...`
- AppleScript commands: `[verbose] osascript: set selected of AirPlay device "Kitchen HomePod" to false`
- Error details: `[verbose] osascript stderr: <raw error text>`

### Speaker error types

Extend `ScriptError` with three new cases:

```swift
case speakerNotFound(String)      // name didn't match any AirPlay device
case speakerUnavailable(String)   // device exists but operation failed
case timeout(String)              // osascript didn't return in time; String = operation description
```

Keep existing `executionFailed` for everything else. This is not a full taxonomy — just enough for actionable speaker messages.

### `withStatus` utility

```swift
func withStatus<T>(_ message: String, body: () async throws -> T) async rethrows -> T
```

Behavior:
- Print message to stderr only when stdout is a TTY.
- Suppress in `--json` mode.
- Clear on both success and failure (overwrite line with spaces via `\r`).
- Only show if operation exceeds ~200ms threshold — avoid flickering on fast operations.
- If `--verbose` is on, verbose lines print beneath the status message without fighting it.
- Do NOT use inside interactive TUI screens — TUIs use their own inline status region.

### Files touched

- `Music.swift` — add `--verbose` flag, `Music.verbose` and `Music.isJSON` static properties
- `ScriptError` (in Models/) — add three new cases
- New: `StatusReporter.swift` (or similar) — `withStatus` function

---

## Layer 2 — AirPlay Resilience

### Wake cycle function

```swift
struct WakeResult {
    let name: String
    let deselectSucceeded: Bool
    let reselectSucceeded: Bool
    let verifiedSelected: Bool
}

func wakeSpeakers(_ names: [String], backend: AppleScriptBackend) async -> [WakeResult]
```

Sequence:
1. For each speaker: `set selected of AirPlay device "{name}" to false`
2. Wait ~500ms (let AirPlay stack release)
3. For each speaker: `set selected of AirPlay device "{name}" to true`
4. Wait ~500ms (let AirPlay stack reconnect)
5. For each speaker: check `selected of AirPlay device "{name}"` — record in `verifiedSelected`

Wrapped in `withStatus("Waking speakers...")`. Verbose mode logs each step.

Post-cycle verification framing: this is "post-cycle selection verification", not "confirmed working". The deselect/reselect cycle materially improves reliability, but `selected == true` after the cycle does not prove audio is flowing. The ghost-state bug can survive superficial checks. The real value is the toggle itself.

If a speaker fails verification, report with `.speakerUnavailable(name)`.

### Automatic wake on routed playback

**Two entry points exist for routed playback — both must be covered:**

1. **Slash command path (primary public surface):** `/music:play X kitchen 60%` is handled by `commands/play.md`, which orchestrates separate CLI calls: `music speaker set` → `music volume` → `music play`. The Swift `Play` command never sees the speaker context. Wake cycle must be integrated here.

2. **Direct CLI path:** `music speaker set kitchen && music play` — used by scripts and advanced users. Wake cycle lives in the Swift `SpeakerCommands` and is available via `music speaker wake`.

**Slash command integration (`commands/play.md`):**

Current sequence:
1. Resolve speaker from args
2. `music speaker set "$SPEAKER"`
3. `music volume "$SPEAKER" "$VOL"`
4. `music play --playlist "$Q"` or `music play`

New sequence:
1. Resolve speaker from args
2. **`music speaker wake "$SPEAKER"`** (replaces `music speaker set`)
3. `music volume "$SPEAKER" "$VOL"`
4. `music play --playlist "$Q"` or `music play`

The wake command already does deselect → wait → reselect, so it subsumes `speaker set` for the routed-play case. If `--no-wake` is needed, fall back to `music speaker set` directly.

For the inherited-session case (no explicit speaker, but non-local AirPlay outputs active): add a check in `play.md` before step 4 — query active speakers, and if any non-local device is selected, run `music speaker wake` (no args) before playback.

**Trigger conditions** — wake when ANY of these are true:
- A speaker was explicitly passed in the play command
- The play command is resuming with active non-local AirPlay outputs (at least one AirPlay device other than the local machine has `selected = true`)

Do NOT wake when:
- `music play` resuming with only local speakers active (no non-local AirPlay device selected)
- `--no-wake` flag passed

Conservative scope: only wake speakers you intend to use. Do not cycle forgotten speakers the user didn't mention.

### `music speaker wake` command

Explicit mid-session recovery:
- `music speaker wake` — cycles all currently selected speakers
- `music speaker wake kitchen` — cycles only the named speaker (after resolution)
- Reports what was cycled and per-speaker verification status
- Uses the same `wakeSpeakers()` function

Add `.wake(name: String?)` case to `SpeakerParser`.

### Better speaker error messages

**Speaker not found:**
Current: `resolveSpeakerName()` silently returns the user's raw input, then AppleScript fails with an opaque error.
New: throw `.speakerNotFound("kitchen")` immediately. User sees:
```
Speaker "kitchen" not found. Available: Kitchen HomePod, Bedroom, AirPods Pro
```

**Speaker unavailable:**
Current: generic `ScriptError.executionFailed` with raw AppleScript text.
New: throw `.speakerUnavailable("Kitchen HomePod")`. User sees:
```
Kitchen HomePod is not responding. Try: music speaker wake
```

**Timeout:**
Current: process hangs indefinitely.
New: throw `.timeout("select AirPlay device Kitchen HomePod")`. User sees:
```
Timed out selecting Kitchen HomePod. Speaker may be offline.
```

**TUI error feedback:**
Replace `try?` (silent swallow) in TUI speaker operations (`s` and `v` keys) with actual error handling. On failure, flash a short-lived message on the TUI's bottom status line (e.g., "Kitchen HomePod not responding") for ~2 seconds, then clear.

### Files touched

- `SpeakerCommands.swift` — `wakeSpeakers()`, `.wake` parser case, error message improvements, `resolveSpeakerName()` throws on no match
- `AppleScriptBackend.swift` — timeout support on osascript execution (for speaker operations)
- `NowPlayingTUI.swift` — replace `try?` with error-reporting pattern in speaker/volume modal calls
- `Music.swift` — add `--no-wake` flag to the root command

### Command updates

- `commands/speaker.md` — add `wake` as a new action case (alongside add/remove/only/stop). Not a separate command file — `wake` is a speaker subcommand.
- `commands/play.md` — replace `music speaker set` with `music speaker wake` when speaker is specified. Add inherited-session detection (query active non-local AirPlay devices before playback, wake if any are selected). Respect `--no-wake` by falling back to `music speaker set`.

---

## Layer 3 — TUI & Feedback

### Now Playing state indicators

**Play/pause indicator:**
- Show `▶` or `⏸` next to the track title on the title row: `▶ Track Name`
- Data source: `player state` (already polled, returns `playing` or `paused`) — just not currently displayed
- Update on each poll cycle

**Shuffle/repeat indicators:**
- Display in the status area, near speaker info / progress bar
- Compact, low-noise presentation:
  - `Shuffle` when shuffle is on (hidden when off)
  - `Repeat` / `Repeat One` when repeat is on (hidden when off)
- Data source: add `shuffle enabled` and `song repeat` to the existing poll AppleScript
- Read-only indicators — toggling is via existing `music shuffle` / `music repeat` commands

Layout:
```
▶ Song Title
  Artist — Album
   advancement/progress bar
  Speaker (vol: 85) | Shuffle | Repeat
```

Keep indicators close to playback metadata. Do not scatter across the screen.

### Progress feedback on waits

Apply `withStatus` to known silent waits:

| Operation | Current UX | New UX |
|-----------|-----------|--------|
| Library sync after `music add` | 4s silence | `Syncing library...` |
| Playlist create/add with tracks | Silent per-track pauses | `Adding tracks... 3/10` |
| `music play` with speaker routing | Silent | `Waking speakers...` then `Starting playback...` |
| Speaker list fetch | Silent | `Fetching speakers...` (only if >200ms) |

Counter format for loops: `Adding tracks... 3/10` — stable counter, redraws cleanly.

Speaker list fetch: only show status if fetch exceeds ~200ms threshold. Avoid flicker on instant returns.

**TUI vs CLI boundary:**
- Normal command flows: use `withStatus`
- TUI flows: use in-place bottom-line transient messages
- Never print CLI-style status lines that fight the TUI renderer

### Files touched

- `NowPlayingTUI.swift` — play/pause indicator, shuffle/repeat indicators, poll AppleScript additions
- `PlaybackCommands.swift` — `withStatus` around library sync wait
- `PlaylistCommands.swift` — `withStatus` counter around track addition loops
- `SpeakerCommands.swift` — `withStatus` around speaker list fetch (with threshold)

---

## Version

This work ships as v1.4.0. Update version in:
- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json` (both `metadata.version` and `plugins[0].version`)

## Testing

- Wake cycle: test with speaker that exhibits ghost state; verify deselect/reselect cycle
- Wake targeting (local only): `music play` with only local speakers active → NO wake triggered
- Wake targeting (inherited session): `music play` with non-local AirPlay device selected → wake triggered
- Wake targeting (explicit speaker): `/music:play "Playlist" kitchen 60%` → wake triggered for kitchen
- Slash command path: verify `commands/play.md` calls `music speaker wake` instead of `music speaker set` when speaker is specified
- `--no-wake`: verify it suppresses the cycle and falls back to `music speaker set`
- `--verbose`: verify output goes to stderr, not stdout; verify verbose works alongside `--json`
- Speaker not found: verify actionable error with available speaker list
- TUI indicators: verify play/pause and shuffle/repeat update in real time
- `withStatus` threshold: verify no flicker on fast operations
- JSON mode: verify `withStatus` suppressed; verify `--verbose` still works (stderr)
