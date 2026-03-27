# Apple Music for Claude Code

```
     ___              __        __  ___         _
    / _ | ___  ___   / /__     /  |/  /_ _____ (_)___
   / __ |/ _ \/ _ \ / / -_)   / /|_/ / // (_-</ / __/
  /_/ |_/ .__/ .__/_/\__/   /_/  /_/\_,_/___/_/\__/
       /_/  /_/
                         for Claude Code
```

Control Apple Music, AirPlay speakers, and AirPods — right from your terminal. Just say what you want.

```
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │   > play radiohead kid a                                     │
  │                                                              │
  │   Playing Kid A from the top — Everything In Its Right       │
  │   Place. Shuffle's off so it plays in album order.           │
  │                                                              │
  │   > add living room speaker                                  │
  │                                                              │
  │   Living Room added — playing on Kitchen and Living Room.    │
  │                                                              │
  │   > volume 40                                                │
  │                                                              │
  │   Done, Kitchen's at 40.                                     │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘
```

## Install

```
/plugin marketplace add anthonymaley/music
/plugin install music
/reload-plugins
```

To update:

```
/plugin update music
```

## What you can do

```
  ╔══════════════════╦═══════════════════════════════════════════╗
  ║  Playback        ║  play, pause, skip, stop, shuffle,       ║
  ║                  ║  repeat, resume                          ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  Playlists       ║  list all, play by name or number,       ║
  ║                  ║  browse tracks, create new                ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  Search          ║  find songs, albums, artists in your     ║
  ║                  ║  library                                  ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  AirPlay         ║  route to any speaker, multi-room        ║
  ║                  ║  groups, per-speaker volume               ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  AirPods         ║  switch between speakers and headphones  ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  Now Playing     ║  current track, player state, active     ║
  ║                  ║  speakers                                 ║
  ╚══════════════════╩═══════════════════════════════════════════╝
```

Zero dependencies. Everything runs through macOS AppleScript.

## Quick commands

Instant controls — no AI reasoning, just runs.

```
  /music:np                  what's playing?
  /music:play                resume
  /music:pause               pause
  /music:skip                next track
  /music:back                previous track
  /music:stop                stop

  /music:speaker list        show all speakers
  /music:speaker kitchen     switch to kitchen
  /music:speaker airpods     switch to AirPods
  /music:speaker add bedroom add speaker to group
  /music:speaker remove bed  remove from group
```

## Status line

See what's playing at the bottom of Claude Code — always visible, no token cost.

```
  ┌──────────────────────────────────────────────────────────────┐
  │  claude >                                                    │
  │                                                              │
  │                                                              │
  │                                                              │
  ├──────────────────────────────────────────────────────────────┤
  │  ▶ Everything In Its Right Place — Radiohead                 │
  └──────────────────────────────────────────────────────────────┘
```

To enable, add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/music/scripts/statusline.sh"
  }
}
```

## Natural language

For anything more complex, just talk naturally. No commands to memorize.

### Play music

```
> play some Daft Punk
> play radiohead kid a
> put on some music
> shuffle playlist Working Vibes
```

### Control playback

```
> pause
> volume 40
> volume to 80
> skip
> stop
```

### Playlists

```
> list playlists
> play Friday on the Deck
> play playlist 18
> what's in the House playlist?
```

### AirPlay speakers

```
> play on the kitchen speaker
> add living room speaker
> remove the bedroom from the group
> turn the kitchen up to 80
```

### AirPods & headphones

```
> switch to my AirPods
> switch back to the kitchen speaker
```

### Now playing

```
> what's playing?
> what speakers are active?
```

## Real session

Here's what it actually looks like in practice:

```
  ❯ play radiohead kid a

  Playing Kid A from the top — Everything In Its Right Place.
  Shuffle's off so it plays in album order. Looks like you've
  got Kid A, Kid A Mnesia, and Amnesiac in there.

  ❯ add living room speaker

  Living Room added — playing on Kitchen and Living Room now.

  ❯ volume 40

  Done, Kitchen's at 40.

  ❯ list playlists

  1. Bluecoats 2024 "Change is everything"
  2. Cool As ...
  3. Electronic Albums
  4. Floating Points Boiler Room NYC
  5. Friday on the Deck
  6. House Bangers
  7. Jazz
  8. Microhouse Essentials
  9. Working Vibes
  ... and 50 more

  ❯ play 5

  Friday on the Deck — Migas 2000 by The Limiñanas.

  ❯ shuffle playlist and put volume to 50

  Shuffle was already on from earlier. Kitchen volume set to 50.

  ❯ switch to my AirPods

  Switched output to Anthony's AirPods Pro.

  ❯ pause

  Paused.
```

## Requirements

```
  ┌────────────────────────────────────────────────────┐
  │  macOS           Required (AppleScript is macOS    │
  │                  only)                             │
  │                                                    │
  │  Apple Music     Comes with macOS                  │
  │                                                    │
  │  Permissions     System Settings > Privacy &       │
  │                  Security > Automation > enable    │
  │                  for your terminal app             │
  │                                                    │
  │  AirPods         Must be connected via Bluetooth   │
  │                  to appear as a device             │
  └────────────────────────────────────────────────────┘
```

## How it works

The plugin teaches Claude how to control Apple Music through AppleScript (`osascript`). When you mention anything music-related, Claude builds and runs the right AppleScript commands behind the scenes. You never have to write any scripts yourself — just describe what you want in plain English.

```
  You: "play Kid A on the kitchen speaker"
   │
   ├─ osascript: route audio to Kitchen
   ├─ osascript: search library for "Kid A"
   └─ osascript: play first result
   │
  Claude: "Playing Kid A — Everything In Its Right Place."
```

## Limitations

- Searches your **local Apple Music library** only — catalog browsing requires the Music app
- Queue management ("add to Up Next") is limited by AppleScript
- Listing all albums can be slow on very large libraries
- AirPods must be connected via Bluetooth to appear as a device

## License

MIT
