---
name: music
description: "Apple Music in your terminal. Play tracks, route to AirPlay speakers and AirPods, search 100 million songs, build playlists, discover new music. Works on macOS with zero setup for playback and speakers. Trigger on anything music-related: playing a song, switching speakers, adjusting volume, searching for tracks, building or managing playlists, finding similar music, checking what's playing. Covers casual requests too: 'put on some house music', 'find me something like this', 'switch to my AirPods', 'add the bedroom to the group', 'turn down the kitchen', 'add this to my workout playlist'. Handles Apple Music, AirPlay, HomePod, AirPods, Bluetooth audio, albums, artists, playlists, recommendations, new releases, and any audio routing on macOS."
---

# Apple Music Controller

Control Apple Music from the terminal via the `music` CLI. All commands run as bash — use `music` for structured operations, with `--json` for machine-readable output.

## Architecture

The music CLI has two backends:
- **AppleScript** — playback, speakers, volume, now playing (no auth needed)
- **REST API** — catalog search, library writes, playlists via API, discovery (needs auth)

## Playback (no auth)

```bash
music play                                    # resume (shows now playing + speakers)
music play "Working Vibes"                    # play a playlist by name
music play "Working Vibes" shuffle            # play with shuffle
music play 3                                  # play result #3 from last search
music play --playlist "Working Vibes"         # explicit playlist flag
music play --song "Get It Done" --artist "Fouk"  # search library + play
music pause
music skip                                    # next track
music back                                    # previous track
music stop
music now                                     # what's playing + speakers
music now --json                              # structured: track, artist, album, speakers, state
music shuffle on|off
music repeat off|one|all
music radio                                   # start radio station from current track
```

## Speakers (no auth)

```bash
music speaker list                            # all AirPlay devices + status (writes to cache)
music speaker list --json                     # structured device list
music speaker kitchen                         # add kitchen (prefix match)
music speaker kitchen 40                      # add kitchen at volume 40
music speaker kitchen stop                    # remove kitchen from group
music speaker airpods only                    # deselect all, select airpods only
music speaker 1 2 5                           # add speakers by index from last list
music speaker set "Kitchen"                   # hidden alias (skill compat)
music speaker add "Bedroom"                   # hidden alias
music speaker remove "Bedroom"                # hidden alias
```

## Volume (no auth)

```bash
music volume                                     # show current volume per speaker
music volume 60                                  # set all active speakers to 60
music volume up                                  # +10 on all active speakers
music volume down                                # -10 on all active speakers
music volume kitchen 80                          # set Kitchen to 80 (name resolved)
```

## Catalog Search (developer token only)

```bash
music search "Bohemian Rhapsody Queen"        # search songs (writes to cache)
music search "Fouk" --limit 20               # control result count
music search --artist "Radiohead"             # filter by artist
music search --album "OK Computer"            # filter by album
music search "query" --json                   # structured results with catalog IDs
```

## Add to Library (requires user token)

```bash
music add "Get It Done" "Fouk"                # search + add top result
music add 3                                   # add result #3 from last search
music add --id 1844648631                     # add by catalog ID
music add --to "House"                        # add current song to playlist
music add --to "House" --to "Chill"           # add current song to multiple playlists
music add 3 --to "House"                      # add result #3 to playlist
```

## Remove from Playlist (requires user token)

```bash
music remove                                  # remove current song from current playlist
music remove "House"                          # remove current song from "House"
music remove all                              # remove current song from all playlists
```

## Playlists (requires user token for API, AppleScript fallback for local)

```bash
music playlist list                           # list all playlists
music playlist tracks "Working Vibes"         # list tracks in playlist
music playlist create "New Playlist"          # create empty playlist
music playlist create "New Playlist" 1 3 5    # create from result indices
music playlist add "House" 1 3 5              # add result indices to existing playlist
music playlist add "Working Vibes" "Song" "Artist"  # add track by name
music playlist delete "Old Playlist"          # delete (via AppleScript)
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
music suggest                                 # suggest tracks from now playing
music suggest 10 --from "Working Vibes"       # suggest from playlist vibe
music new-releases --like-current             # new releases from current artist
music new-releases --artist "Fouk"            # new releases from specific artist
music mix --artists "Fouk,Floating Points" --count 20 --name "Friday Mix"  # mixed playlist
```

## Result Cache

Search, similar, suggest, new-releases, and playlist tracks write results to `~/.config/music/last-songs.json`. Speaker list writes to `last-speakers.json`. Follow-up commands reference results by index:

```bash
music search "house"        # results cached as 1, 2, 3...
music play 3                # play result #3
music add 3                 # add #3 to library
music add 3 --to "House"    # add #3 to playlist
music playlist create "House" 1 3 5  # create playlist from results
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
| No auth | play, pause, skip, back, stop, now, shuffle, repeat, speaker, volume | search, add, playlist (API), similar, suggest, new-releases, mix |
| Developer token only | Above + search | add, playlist (API), similar, suggest, new-releases, mix |
| Both tokens | Everything | — |

## Workflow: Complex Requests

**Minimize tool calls.** Chain independent commands with `&&` in a SINGLE bash call where possible.

For multi-step requests like "play Fouk on the kitchen speaker at 60%":

```bash
# ONE bash call — chain with &&
music speaker kitchen 60 && music play "Working Vibes" shuffle
```

For "find house tracks and make a playlist":

```bash
# Step 1: search to find tracks (results cached automatically)
music search "house Fouk Chris Lake FISHER" --limit 20 --json
```

```bash
# Step 2: create playlist from cached results by index
music playlist create "House Vibes" 1 3 5 7 9
```

```bash
# Step 3: play it
music play "House Vibes" shuffle
```

For bulk operations where you have title/artist pairs, use `create-from` (ONE command for all tracks):

```bash
music playlist create-from "Losing It" "FISHER" "Coconuts" "Fouk" "Stay With Me" "Chris Lake" --name "House Vibes"
```

**Rules:**
- Use result indices (`music playlist create "Name" 1 3 5`) when building from search results
- Use `create-from` when you have title/artist pairs from other sources
- Chain speaker + volume + play into a single `&&` bash call
- Use `--json` on search to get structured results for parsing
- Both `create-from` and index-based create handle errors gracefully

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
