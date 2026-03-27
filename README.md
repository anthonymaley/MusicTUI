# Apple Music for Claude Code

Control Apple Music playback, AirPlay speakers, and AirPods from the terminal. macOS only.

## What it does

- **Playback** — play, pause, skip, stop, shuffle, repeat
- **Playlists** — list, play, create, browse tracks
- **Search** — find songs, albums, and artists in your library
- **AirPlay** — route audio to any AirPlay speaker, manage multi-room groups
- **Per-speaker volume** — set different volumes on each speaker in a group
- **AirPods** — switch between speakers and AirPods/Bluetooth headphones
- **Now playing** — check current track, player state, active speakers

Everything runs through AppleScript (`osascript`) — no extra dependencies.

## Install

```bash
claude install gh:anthonymaley/music
```

## Usage

Just talk naturally:

- "Put on some music"
- "Play Working Vibes on the kitchen speaker"
- "Switch to my AirPods"
- "Add the bedroom to the group and turn it down"
- "What's playing?"
- "Turn the kitchen up to 80"
- "Play some Daft Punk"

The skill triggers on mentions of music, speakers, playlists, AirPlay, AirPods, albums, artists, or any audio control request.

## Requirements

- macOS (AppleScript is macOS-only)
- Apple Music app (comes with macOS)
- Automation permissions: System Settings → Privacy & Security → Automation → enable for your terminal app

## Limitations

- Searches your local Apple Music library only — Apple Music catalog browsing requires the Music app UI
- Queue management ("add to Up Next") is limited by AppleScript's capabilities
- Listing all albums can be slow on very large libraries
- AirPods must be connected via Bluetooth to appear as an available device

## License

MIT
