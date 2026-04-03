# Interactive Now Playing + Radio Station

## Summary

Two features: (1) interactive now-playing TUI with a real-time timeline bar and playback controls, (2) a `music radio` command that starts an Apple Music station from the current track.

## Feature 1: Interactive Now Playing

### Trigger

Bare `music now` with a TTY → interactive mode. With `--json`, args, or piped stdout → current static output (no change to existing behavior). Same `isBareInvocation("now") && isTTY()` gate used by speaker/volume/similar.

### Layout

```
  ♫  Now Playing

  Everything In Its Right Place — Radiohead
  Kid A

  ██████████████░░░░░░░░░░░░░░░░  2:14 / 4:56

  Kitchen (vol: 60) | Sonos Arc (vol: 40)

  ╭──────────────────────────────────────────╮
  │ ←→ skip  ␣ pause/resume  r radio  q quit │
  ╰──────────────────────────────────────────╯
```

### Controls

| Key | Action |
|-----|--------|
| `←` | Previous track (`previous track` AppleScript) |
| `→` | Next track (`next track` AppleScript) |
| `␣` (space) | Toggle pause/resume |
| `r` | Start radio station from current track (see Feature 2) |
| `q` / `Esc` | Exit interactive mode |

### Timeline Bar

- Bar width: 30 characters (same as VolumeMixer)
- Filled portion: `█` (green), empty: `░` (dim) — matches volume mixer style
- Time display: `M:SS / M:SS` (position / duration)
- When paused, show `⏸` indicator in the header instead of `♫`

### Real-time Updates

- Poll AppleScript every 1 second for: track name, artist, album, duration, position, player state, active speakers
- Reuse the existing `showNowPlaying` AppleScript query (already returns all needed fields: `t|a|al|d|p|state|speakers`)
- On track change (detected by comparing track name), refresh all fields immediately
- On pause/resume, update the header icon

### Implementation

New function `runNowPlayingTUI()` in `PlaybackCommands.swift` (or a new `NowPlayingTUI.swift` in TUI/). Follows the same pattern as `runVolumeMixer`:
- `TerminalState.shared.enterRawMode()` with defer exit
- Render loop with `ANSICode.cursorHome + clearScreen`
- `KeyPress.read()` with a 1-second timeout for auto-refresh

The 1-second polling needs a non-blocking key read. Current `KeyPress.read()` blocks indefinitely. Options:
- **Option A**: Add a timeout parameter to `KeyPress.read()` using `select()` or `poll()` on stdin fd before reading. This is the cleanest approach — the render loop calls `KeyPress.read(timeout: 1.0)`, gets `nil` on timeout (triggering a re-render), or a key press.
- Choose Option A.

### Changes to Now command

In `Now.run()`, add the TUI gate:

```swift
if isBareInvocation(command: "now") && isTTY() {
    runNowPlayingTUI()
    return
}
// ... existing static output
```

## Feature 2: Radio Station Command

### Command

`music radio` — starts an Apple Music station from the currently playing track.

### AppleScript

The Music app's "Start Station" creates a station seeded from a track. The AppleScript approach:

```applescript
tell application "Music"
    set t to current track
    -- Convert track to a station and play it
    open location "itmss://music.apple.com/station/" & (database ID of t as text)
end tell
```

If `open location` doesn't work for stations, fall back to:

```applescript
tell application "Music"
    set t to current track
    set trackName to name of t
    set trackArtist to artist of t
    -- Use the "play" verb with a station-creation idiom
end tell
```

**Note:** The exact AppleScript for station creation needs verification. Apple's scripting dictionary for Music.app includes `make new station` but the parameters vary by macOS version. The implementation should try `open location` with the track's store URL first, then fall back to alternative approaches. This will need hands-on testing during implementation.

### Slash Command

New `/music:radio` slash command. Shell script:

```bash
if command -v music &>/dev/null; then
    music radio
else
    osascript -e 'tell application "Music" to ...'
fi
```

### Integration with Now Playing TUI

The `r` key in the interactive now-playing calls the same station-creation logic, prints "Started radio station from: Track — Artist" and continues the TUI (the station plays as a new context, so the now-playing display updates automatically on the next poll).

### Output

```
Started radio station from: Everything In Its Right Place — Radiohead
```

## Files to Create/Modify

| File | Change |
|------|--------|
| `Sources/TUI/Terminal.swift` | Add timeout parameter to `KeyPress.read()` |
| `Sources/TUI/NowPlayingTUI.swift` | New file: `runNowPlayingTUI()` |
| `Sources/Commands/PlaybackCommands.swift` | Add `Now` TUI gate, add `Radio` command struct, register in Music.swift |
| `Sources/Music.swift` | Register `Radio` subcommand |
| `commands/radio.md` | New slash command |

## Out of Scope

- Scrubbing (seeking to a position via timeline) — would need `set player position to X` AppleScript, but the ←→ keys are more intuitive as skip
- Album art display — terminal doesn't support images in raw mode
- Lyrics display — separate feature
