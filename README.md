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

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │  you:  Go find the latest deep house tracks, put them in a          │
  │        playlist, shuffle it on the kitchen at 60%, and list         │
  │        the tracks here for me.                                      │
  │                                                                     │
  │  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐  │
  │    music search "deep house 2026" --limit 15                       │
  │  │ music playlist create "Deep House Finds"                      │  │
  │    music playlist add "Deep House Finds" "Silhouette" "Kerri C"    │
  │  │ music playlist add "Deep House Finds" "Night Ride" "Fouk"     │  │
  │    ...                                                             │
  │  │ music speaker set Kitchen                                     │  │
  │    music volume Kitchen 60                                         │
  │  │ music shuffle on                                              │  │
  │    music play --playlist "Deep House Finds"                        │
  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘  │
  │                                                                     │
  │  claude:  ▶ Playing Deep House Finds on Kitchen [60]                │
  │                                                                     │
  │    ┌────┬──────────────────────┬──────────────────┬───────┐         │
  │    │  # │ Track                │ Artist           │ Album │         │
  │    ├────┼──────────────────────┼──────────────────┼───────┤         │
  │    │  1 │ Silhouette           │ Kerri Chandler   │ ...   │         │
  │    │  2 │ Night Ride           │ Fouk             │ ...   │         │
  │    │  3 │ Body Movement        │ DJ Seinfeld      │ ...   │         │
  │    │  4 │ Midnight Sun         │ Jimpster         │ ...   │         │
  │    │  5 │ Inner City Blues     │ Moodymann        │ ...   │         │
  │    │ .. │ ...                  │ ...              │ ...   │         │
  │    └────┴──────────────────────┴──────────────────┴───────┘         │
  │                                                                     │
  │  you:  It's great. Share it with Julie on iMessage.                 │
  │  claude:  ✓ Shared "Deep House Finds" with Julie via iMessage.      │
  │                                                                     │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ▶ Silhouette — Kerri Chandler  ·  Kitchen [60]                    │
  └─────────────────────────────────────────────────────────────────────┘
```

## What You Can Do

Just talk to Claude. These are real examples — not slash commands, just natural language:

```
> Look at the Working Vibes playlist. See the last ten tracks on that
  playlist. Make a separate playlist with those ten tracks and shuffle
  them. Play it on the kitchen and Sonos Arc at 60%.

> Take the current track and search for new records that match this
  style. Put them in a playlist and shuffle them.

> It's great. Share it with Julie on iMessage.

> Go find the latest deep house tracks. Play them on a playlist and
  shuffle it, but also list the tracks in an ASCII table here in
  Claude Code for me to see. Play them in the kitchen at 60% volume.

> Switch to my AirPods and turn it down to 30.

> Add the bedroom to the group and turn the kitchen down to 40.
```

Claude handles the multi-step orchestration — searching the catalog, creating playlists, routing to speakers, setting volume, sharing — all from one sentence.

All commands start with **`/music:`** — type `/music:` and tab to discover them.

## Install

### Claude Code (CLI)

```bash
# Add the marketplace
/plugin marketplace add anthonymaley/music

# Install the plugin
/plugin install music@anthonymaley-music
```

### Claude Desktop App (Cowork)

1. Click **+** next to the prompt box
2. Select **Plugins**
3. Choose **Add plugin**
4. Browse and select **Apple Music**

### Update

```bash
# CLI
claude plugin update music@anthonymaley-music

# Desktop — Manage plugins → Update
```

### Advanced Features (optional — requires Apple Developer account)

Playback, speakers, and volume work out of the box with zero setup. For catalog search, library management, playlists via API, and music discovery, you need:

1. An **Apple Developer account** ($99/year at [developer.apple.com](https://developer.apple.com))
2. The **music CLI** built from source
3. A **MusicKit key** configured via guided setup

```bash
# Build the CLI
cd ~/.claude/plugins/cache/music@anthonymaley-music
scripts/install.sh

# Guided auth setup — walks you through creating a MusicKit key
music auth setup

# Get your user token (opens browser, auto-saves)
music auth

# Verify
music auth status
```

After updating the plugin, rebuild the CLI: `scripts/install.sh`

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
| `/music:now` | Show what's currently playing |
| `/music:shuffle` | Toggle shuffle on/off |

### Volume

| Command | What it does |
|---------|-------------|
| `/music:volume 60` | Set all active speakers to 60 |
| `/music:volume up` | Volume +10 |
| `/music:volume down` | Volume -10 |
| `/music:volume kitchen 80` | Set a specific speaker to 80 |

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

### Playlists

| Command | What it does | Setup |
|---------|-------------|-------|
| `/music:playlist list` | List all your playlists | none |
| `/music:playlist tracks Working Vibes` | Show tracks in a playlist | none |
| `/music:playlist create Friday Mix` | Create an empty playlist | advanced |
| `/music:playlist delete Old Playlist` | Delete a playlist | advanced |
| `/music:playlist add "Playlist" "Song" "Artist"` | Add a track to a playlist | advanced |

### Catalog & Discovery (advanced)

| Command | What it does |
|---------|-------------|
| `/music:search Bohemian Rhapsody` | Search Apple Music catalog (100M+ tracks) |
| `/music:search Fouk` | Search by artist |
| `/music:add Get It Done Fouk` | Add a track to your library |
| `/music:similar` | Find tracks similar to what's playing |

## Natural Language

Slash commands handle quick actions. For anything multi-step, just talk — Claude composes the right sequence of CLI calls automatically. See [What You Can Do](#what-you-can-do) above for examples.

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

## What Needs Auth?

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
   ├─ music volume Kitchen 60
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
