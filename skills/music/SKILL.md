---
name: music
description: "Apple Music in your terminal. Play tracks, route to AirPlay speakers and AirPods, search 100 million songs, build playlists, discover new music, favorite tracks, seek within a song, browse your listening history. This is the plugin's only entry point — there are no separate slash commands, so EVERY music request comes here: transport, playback routing, search, library, playlists, discovery, eq, equalizer, bass, treble, 'sound like'. Trigger on anything music-related: playing a song, pausing, skipping, switching speakers, adjusting volume, seeking within a track, searching the catalog, adding tracks to the library, building or managing playlists, finding similar music, checking what's playing, favoriting a song, recalling recently played music, adjusting the equalizer. Covers casual requests too: 'put on some house music', 'pause the music', 'next track', 'find me something like this', 'switch to my AirPods', 'add the bedroom to the group', 'turn down the kitchen', 'search for Gypsy Woman', 'add that track to my library', 'make a playlist from those results', 'add this to my workout playlist', 'play Kid A in the kitchen and living room at 60%', 'love this track', 'skip ahead 30 seconds', 'what was that song I played earlier', 'more bass', 'make it sound like a nightclub', 'turn off the EQ'. Handles Apple Music, AirPlay, HomePod, AirPods, Bluetooth audio, albums, artists, playlists, recommendations, new releases, listening history, heavy rotation, equalizer presets, and any audio routing on macOS."
---

# Apple Music Controller

Control Apple Music from the terminal via the `music` CLI. All commands run as bash — use `music` for structured operations, with `--json` for machine-readable output.

## If the CLI is not installed

If `command -v music` fails, do NOT improvise AppleScript fallbacks. Tell the user the CLI needs a one-time build and point them at the install script, then retry after they run it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh"   # from the plugin
# or, in the repo: scripts/install.sh
```

## Fast path: play requests

For any request shaped like "play X [on/in speakers] [at volume%] [shuffle]", forward the user's words to `music play` in ONE bash call — strip only the leading "play" and any % sign. The CLI's parser deterministically extracts speaker names (including several at once), volume, filler words ("in", "the", "and", "at", "on"), and a trailing "shuffle":

```bash
music play kid a in the kitchen and living room at 60
music play jazz for cooking kitchen 40 shuffle
```

Naming speakers routes playback to exactly those speakers (it deselects the rest). Don't pre-chain `music speaker` + `music volume` for simple play requests — `music play` does all three. If the query itself contains a speaker-like word, use the explicit flags (`--song`, `--album`, `--playlist`) instead. Named-speaker plays are verified automatically once playback starts (`✓ <speaker> verified (…)`); an unestablished route triggers an automatic heal before an honest failure message.

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
music play "Working Vibes" kitchen 20         # play on Kitchen speaker (only) at vol 20
music play "Working Vibes" kitchen 20 shuffle # routed + shuffled
music play kid a in the kitchen and living room at 60  # multi-room: filler words OK, group volume
music play deck and pool                      # resume on Deck + Pool (exactly those)
music play "Gypsy Woman" "Tom Misch"          # song + artist; catalog fallback if authenticated
music play "https://music.apple.com/...?...i=1581424482" # catalog song URL; quote it in zsh
music play --playlist "Working Vibes"         # explicit playlist flag
music play "Gypsy Woman (Quarantine Sessions)" # play matching local Library album/song
music play --album "Kid A" --artist "Radiohead" # explicit local Library album + artist
music play --song "Get It Done" --artist "Fouk"  # search library + play
music play --verbose                          # diagnostic output on stderr
music pause
music skip                                    # next track
music back                                    # previous track
music stop
music now                                     # what's playing + speakers
music now --json                              # structured: track, artist, album, speakers, state
music seek +30|-30|90|1:30                    # seek within the current track
music shuffle                                 # toggle (or: music shuffle on|off)
music repeat off|one|all
music love                                    # favorite the current track
music unlove                                  # unfavorite
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
music speaker wake                            # verify all active speakers, reset only the broken ones
music speaker wake kitchen                    # verify + wake a specific speaker
music speaker verify                          # network-truth verdict for all selected speakers
music speaker verify kitchen                  # verify one speaker (--json for structured output)
music speaker set "Kitchen"                   # hidden alias (skill compat)
music speaker add "Bedroom"                   # hidden alias
music speaker remove "Bedroom"                # hidden alias
```

`music speaker <name>` (add), `set`, and `only` verify the route automatically while playing — output gains a `✓ <speaker> verified (…)` line, and an unverified route triggers an automatic heal (away-and-back reroute, then a transport-cycle reset) before falling back to an honest failure naming the manual fix. While paused, routing can't be network-verified — it prints `Route set; will verify on next play.` and re-checks when playback starts. Scripting's own claims (`selected`, `active`) are shown as advisory only, not trusted, because they can lie. Routing to the Mac's own output is never "verified" — local output has no AirPlay session.

## Volume (no auth)

```bash
music volume                                     # show current volume per speaker
music volume 60                                  # set all active speakers to 60
music volume up                                  # +10 on all active speakers
music volume down                                # -10 on all active speakers
music volume kitchen 80                          # set Kitchen to 80 (name resolved)
```

## Equalizer (no auth)

Real Music.app EQ control. Venue presets are created on first selection and
persist as real presets (visible in Music's own EQ window). Live EQ control
drives the Equalizer window via UI scripting (Music's scripting API for live
EQ state is broken): it needs Accessibility permission for the terminal and
opens the Equalizer window. On a permission error, relay the command's hint —
it names the exact System Settings toggle.

| Request | Command |
|---|---|
| "make it sound like a dungeon" / "nightclub mode" | `music eq dungeon` / `music eq nightclub` |
| "more bass" | `music eq "Bass Booster"` |
| "flat" / "turn off the EQ" | `music eq flat` / `music eq off` |
| "what's the EQ?" | `music eq` |
| "remove the venue presets" | `music eq remove-pack` |

Venue pack: Nightclub, Dungeon, Open Air, Concert Hall, Jazz Club, Stadium,
Cathedral, Late Night. Any other name forwards verbatim — Music's built-in
presets (Acoustic, Hip-Hop, Loudness, …) all resolve. Unknown names print
near-matches.

## Visualizer (no auth)

`music visualizer [on|off]` toggles Music's on-screen visualizer (the Cmd-T
visuals). Same UI-scripting + Accessibility requirement as the equalizer.
GUI-only: the visuals render in the Music window on the Mac's display (not on
AirPlay outputs), and turning it on brings Music to the front.

## Search (catalog: developer token · library: + user token)

```bash
music search "Bohemian Rhapsody Queen"        # search songs (writes to cache)
music search "Fouk" --limit 20               # control result count
music search "house" --types songs,albums,artists,playlists  # multi-type catalog search
music search "The Smiths" --library          # search YOUR library (needs user token)
music search "kid a" --library --types playlists             # library, specific types
music search --artist "Radiohead"             # narrow the query text by artist
music search --album "OK Computer"            # narrow the query text by album
music search "query" --json                   # structured results with catalog IDs
```

`--types` accepts any of `songs,albums,artists,playlists` (default `songs`). Only songs are numbered/cached for index-based `add`/quick-pick; albums, artists, and playlists print with their catalog/library ids.

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
music similar Hotel California                # similar to a specific track (--artist to narrow)
music recent                                  # recently played tracks (cached for `play N`)
music rotation                                # your heavy-rotation music
music suggest                                 # suggest tracks from now playing
music suggest 10 --from "Working Vibes"       # suggest from playlist vibe
music new-releases --like-current             # new releases from current artist
music new-releases --artist "Fouk"            # new releases from specific artist
music mix --artists "Fouk,Floating Points" --count 20 --name "Friday Mix"  # mixed playlist
```

## Interactive TUI (requires real terminal, not Claude Code)

```bash
music                                         # unified shell: Now / Playlists / Speakers / Library tabs
```

Bare `music` is the main interactive surface — a tabbed shell with **Now**, **Playlists**, **Speakers**, and **Library** tabs. (`music now` / `music now --json` and `music playlist <subcommand>` are non-interactive CLI commands, documented above.) Four one-shot quick pickers also exist for terminal/slash-command use: bare `music speaker` (AirPlay picker), bare `music volume` (mixer), and the `music similar` / `music suggest` result pickers.

TUI behavior: the Now tab shows the current album context; selecting a playlist on the Playlists tab pins it on the Now tab. Cursor movement is local and fast. On the Speakers tab, toggling a speaker on while playing verifies the route and toasts if it couldn't be verified. The Library tab (needs the Apple Music user token) browses your library in three sub-views — Albums, Artists, Songs — switched with `[`/`]`; Enter opens an album's tracks (or drills Artist → their albums → tracks), `p` plays and `s` shuffles the item in focus.

TUI controls: `1/2/3/4` switch tabs (Now / Playlists / Speakers / Library), `Tab`/`Shift-Tab` cycle tabs, `[`/`]` switch Library sub-view, `↑↓` navigate (`PgUp/PgDn/Home/End` for long lists), `Enter` play/open selected, `←→` seek (Now) or volume (Speakers), `Space` pause, `</>` previous/next track (full up/down through the playlist), `z`/`r` shuffle, `l` favorite, `+/-` volume, `n` next-up options (Now), `/` filter playlists (arrows navigate while typing), `Esc` back, `q` quit. Playlist track-play requires Music's Autoplay (∞) turned OFF — it drives playback track-by-track and needs each track to stop at its end.

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

"Play X on speaker Y at volume Z" is NOT a multi-step request — `music play` handles routing and volume natively (see Fast path above):

```bash
# ONE command, not a chain
music play Working Vibes in the kitchen at 60 shuffle
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
- Never chain `music speaker` + `music volume` + `music play` for a play request — one `music play` call does all three
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
