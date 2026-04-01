# Apple Music for Claude Code

```
     ___              __        __  ___         _
    / _ | ___  ___   / /__     /  |/  /_ _____ (_)___
   / __ |/ _ \/ _ \ / / -_)   / /|_/ / // (_-</ / __/
  /_/ |_/ .__/ .__/_/\__/   /_/  /_/\_,_/___/_/\__/
       /_/  /_/
                         for Claude Code
```

Control Apple Music, AirPlay speakers, and AirPods — right from your terminal.

All commands start with **`/music:`** — type `/music:` and tab to discover them.

## Install

```
/install anthonymaley/music
```

## Commands

Every command runs instantly — no AI reasoning, no chat clutter.

### Playback

| Command | What it does |
|---------|-------------|
| `/music:play` | Resume playback |
| `/music:play Working Vibes` | Play a playlist (shuffled) |
| `/music:play Radiohead` | Search and play an artist |
| `/music:play kid a` | Search and play an album or song |
| `/music:play Fouk kitchen 60%` | Play on a specific speaker at a volume |
| `/music:pause` | Pause |
| `/music:skip` | Next track |
| `/music:back` | Previous track |
| `/music:stop` | Stop playback |
| `/music:stop kitchen` | Remove kitchen from the speaker group |
| `/music:np` | Show what's currently playing |
| `/music:shuffle` | Toggle shuffle on/off |

### Volume

| Command | What it does |
|---------|-------------|
| `/music:vol 60` | Set all active speakers to 60 |
| `/music:vol up` | Volume +10 |
| `/music:vol down` | Volume -10 |
| `/music:vol kitchen 80` | Set a specific speaker to 80 |

### Speakers

| Command | What it does |
|---------|-------------|
| `/music:speaker` | List all AirPlay devices |
| `/music:speaker list` | List all AirPlay devices |
| `/music:speaker kitchen` | Switch to kitchen (deselects others) |
| `/music:speaker only kitchen` | Same — switch to kitchen only |
| `/music:speaker airpods` | Switch to AirPods |
| `/music:speaker add bedroom` | Add bedroom to the current group |
| `/music:speaker remove kitchen` | Remove kitchen from the group |
| `/music:speaker stop kitchen` | Same — remove kitchen from the group |
| `/music:speaker remove kitchen add bedroom` | Chain actions in one command |

### Catalog & Library (requires music CLI)

| Command | What it does |
|---------|-------------|
| `/music:search Bohemian Rhapsody` | Search Apple Music catalog (100M+ tracks) |
| `/music:search Fouk` | Search by artist |
| `/music:add Get It Done Fouk` | Add a track to your library |
| `/music:similar` | Find tracks similar to what's playing |

### Playlists (requires music CLI)

| Command | What it does |
|---------|-------------|
| `/music:playlist list` | List all your playlists |
| `/music:playlist tracks Working Vibes` | Show tracks in a playlist |
| `/music:playlist create Friday Mix` | Create an empty playlist |
| `/music:playlist delete Old Playlist` | Delete a playlist |
| `/music:playlist add "Playlist" "Song" "Artist"` | Add a track to a playlist |

## Natural Language

For anything more complex, just talk to Claude. No commands to memorize.

```
> play some Daft Punk on the kitchen speaker
> add the living room to the group and turn it down to 40
> play my top 25 most played and list the tracks
> find me something like what's playing and make a playlist
> what's new from Radiohead?
> make me a mix from Fouk and Floating Points
```

## Status Line

See what's playing at the bottom of Claude Code — always visible, no token cost.

```
┌──────────────────────────────────────────────────────────────┐
│  claude >                                                    │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  ▶ Everything In Its Right Place — Radiohead  ·  Kitchen [60]│
└──────────────────────────────────────────────────────────────┘
```

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/music/scripts/statusline.sh"
  }
}
```

## Music CLI (optional, unlocks catalog features)

The plugin works out of the box for playback, speakers, and volume using AppleScript. For catalog search, library management, playlists via API, and music discovery, install the `music` CLI:

```bash
scripts/install.sh
```

Then set up Apple Music API auth:

```bash
music auth setup     # guided setup: key ID, team ID, .p8 key
music auth           # opens browser to get user token
music auth status    # check what's configured
```

### What needs auth?

| Feature | No auth | Developer token | + User token |
|---------|---------|----------------|-------------|
| Play, pause, skip, stop, shuffle, repeat | Yes | Yes | Yes |
| Speakers, volume, now playing | Yes | Yes | Yes |
| Catalog search | — | Yes | Yes |
| Add to library | — | — | Yes |
| Playlist CRUD via API | — | — | Yes |
| Similar, suggestions, new releases, mix | — | — | Yes |

## How It Works

```
  /music:play kid a kitchen 60%
   │
   ├─ music speaker set Kitchen
   ├─ music vol Kitchen 60
   ├─ music play --song "kid a"
   │
  ▶ Playing Kid A — Everything In Its Right Place
```

The plugin routes through the `music` CLI when installed. Without it, playback and speaker commands fall back to raw AppleScript.

```
  Slash Commands ──► music CLI ──► AppleScript (playback, speakers, volume)
       │                   └──► REST API (catalog, library, playlists, discovery)
       └──► AppleScript (fallback when music CLI not installed)
```

## Requirements

- **macOS** — AppleScript is macOS only
- **Apple Music** — comes with macOS
- **Automation permission** — System Settings > Privacy & Security > Automation > enable for your terminal
- **Swift 5.9+** — only if building the music CLI
- **AirPods** — must be connected via Bluetooth to appear as a device

## License

MIT
