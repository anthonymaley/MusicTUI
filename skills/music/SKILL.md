---
name: music
description: "Control Apple Music playback, AirPlay speakers, AirPods, catalog search, library management, playlists, and music discovery on macOS. Use this skill whenever the user wants to play music, control playback (play, pause, skip, volume, shuffle), manage playlists, play an album or artist, search the Apple Music catalog (100M+ tracks), add tracks to their library, get music recommendations, route audio to AirPlay speakers or AirPods, add or remove speakers from a group, adjust per-speaker volume, switch between headphones and speakers, or check what's currently playing. Trigger on any mention of: Apple Music, AirPlay, speakers, playlist, play a song, what's playing, music volume, now playing, queue, HomePod, AirPods, headphones, Bluetooth audio, album, artist, search for music, add to library, recommendations, similar tracks, new releases, or any request to control audio playback on their Mac — even casual ones like 'put on some music', 'find me something like this', 'switch to my AirPods', 'add the bedroom to the group', or 'turn down the kitchen'."
---

# Apple Music Controller

Control Apple Music from the terminal via the `music` CLI. All commands run as bash — use `music` for structured operations, with `--json` for machine-readable output.

## Architecture

The music CLI has two backends:
- **AppleScript** — playback, speakers, volume, now playing (no auth needed)
- **REST API** — catalog search, library writes, playlists via API, discovery (needs auth)

## Playback (no auth)

```bash
music play                                    # resume
music play --playlist "Working Vibes"         # play a playlist (with shuffle)
music play --song "Get It Done" --artist "Fouk"  # play specific track from library
music pause
music skip                                    # next track
music back                                    # previous track
music stop
music now                                     # what's playing + speakers
music now --json                              # structured: track, artist, album, speakers, state
music shuffle on|off
music repeat off|one|all
```

## Speakers (no auth)

```bash
music speaker list                            # all AirPlay devices + status
music speaker list --json                     # structured device list
music speaker set "Kitchen"                   # switch to single speaker
music speaker add "Bedroom"                   # add to current group
music speaker remove "Bedroom"                # remove from group
music speaker stop "Bedroom"                  # same — remove from group
```

## Volume (no auth)

```bash
music vol                                     # show current volume per speaker
music vol 60                                  # set all active speakers to 60
music vol up                                  # +10 on all active speakers
music vol down                                # -10 on all active speakers
music vol Kitchen 80                          # set Kitchen to 80
```

## Catalog Search (developer token only)

```bash
music search "Bohemian Rhapsody Queen"        # search songs
music search "Fouk" --limit 20               # control result count
music search --artist "Radiohead"             # filter by artist
music search --album "OK Computer"            # filter by album
music search "query" --json                   # structured results with catalog IDs
```

## Add to Library (requires user token)

```bash
music add "Get It Done" "Fouk"                # search + add top result
music add --id 1844648631                     # add by catalog ID
```

## Playlists (requires user token for API, AppleScript fallback for local)

```bash
music playlist list                           # list all playlists
music playlist tracks "Working Vibes"         # list tracks in playlist
music playlist create "New Playlist"          # create empty playlist
music playlist delete "Old Playlist"          # delete (via AppleScript)
music playlist add "Working Vibes" "Song" "Artist"  # add track to playlist
music playlist add "P1,P2" "Song" "Artist"    # add to multiple playlists
music playlist remove "Playlist" "Song"       # remove track
music playlist share "Playlist" --imessage "+1234567890"  # share via iMessage
music playlist share "Playlist" --email "a@b.com"         # share via email
music playlist temp "Song1" "Artist1" "Song2" "Artist2"   # temp playlist, play, cleanup later
music playlist create-from "Song1" "Artist1" "Song2" "Artist2" --name "My Mix"  # create + populate
music playlist cleanup                        # delete all __temp__ playlists
```

## Discovery (requires user token)

```bash
music similar                                 # similar to now playing
music similar "Song" "Artist"                 # similar to specific track
music suggest 10                              # suggest tracks from now playing
music suggest 10 --from "Working Vibes"       # suggest from playlist vibe
music new-releases --like-current             # new releases from current artist
music new-releases --artist "Fouk"            # new releases from specific artist
music mix --artists "Fouk,Floating Points" --count 20 --name "Friday Mix"  # mixed playlist
```

## Auth Management

```bash
music auth status                             # check config + token status
music auth setup                              # guided setup (key ID, team ID, .p8 key)
music auth                                    # open browser for user token
music auth set-token <TOKEN>                  # save user token from browser
```

## Auth Tiers

| Tier | What works | What doesn't |
|------|-----------|--------------|
| No auth | play, pause, skip, back, stop, now, shuffle, repeat, speaker, vol | search, add, playlist (API), similar, suggest, new-releases, mix |
| Developer token only | Above + search | add, playlist (API), similar, suggest, new-releases, mix |
| Both tokens | Everything | — |

## Workflow: Complex Requests

For multi-step requests like "play Fouk on the kitchen speaker at 60%", compose commands:

```bash
music speaker set "Kitchen"
music vol Kitchen 60
music play --playlist "Working Vibes"
```

For "find me something like what's playing and make a playlist":

```bash
music similar --json                          # get similar tracks
music playlist create "Discovered"
# For each track: music playlist add "Discovered" "Title" "Artist"
```

## Output Modes

- **Default:** Human-readable text for terminal
- **`--json`:** Structured JSON for scripting and Claude

Always use `--json` when you need to parse the output programmatically.

## Error Handling

- **"Config not found"** — Run `music auth setup`
- **"User token required"** — Run `music auth`
- **"API request failed with status 401/403"** — Token expired, run `music auth` again
- **"No tracks found"** — Try a broader search query
- **Speaker commands fail** — Check exact speaker name with `music speaker list`
