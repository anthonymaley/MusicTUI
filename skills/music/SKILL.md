---
name: music
description: "Apple Music in your terminal. Play tracks, route to AirPlay speakers and AirPods, search 100 million songs, build playlists, play radio stations, discover new music, favorite tracks, seek within a song, browse your listening history, browse your library by artist, album, or track. This is the plugin's only entry point: there are no separate slash commands, so EVERY music request comes here: transport, playback routing, search, library, playlists, radio, discovery, eq, equalizer, bass, treble, 'sound like'. Trigger on anything music-related: playing a song, pausing, skipping, switching speakers, adjusting volume, seeking within a track, searching the catalog, adding tracks to the library, building or managing playlists, finding similar music, checking what's playing, favoriting a song, recalling recently played music, browsing your library by artist or album, adjusting the equalizer, playing or favoriting a radio station. Covers casual requests too: 'put on some house music', 'pause the music', 'next track', 'find me something like this', 'switch to my AirPods', 'add the bedroom to the group', 'turn down the kitchen', 'search for Gypsy Woman', 'add that track to my library', 'make a playlist from those results', 'add this to my workout playlist', 'play Kid A in the kitchen and living room at 60%', 'love this track', 'skip ahead 30 seconds', 'what was that song I played earlier', 'more bass', 'make it sound like a nightclub', 'turn off the EQ', 'put on BBC Radio 1', 'play Apple Music 1', 'what radio stations do I have', 'favorite this station', 'add this radio station'. Handles Apple Music, AirPlay, HomePod, AirPods, Bluetooth audio, albums, artists, playlists, radio stations, recommendations, new releases, listening history, heavy rotation, equalizer presets, and any audio routing on macOS."
---

# Apple Music Controller

Control Apple Music from the terminal via the `music` CLI. All commands run as bash; use `music` for structured operations, with `--json` for machine-readable output.

## If the CLI is not installed

If `command -v music` fails, do NOT improvise AppleScript fallbacks. Tell the user the CLI needs a one-time build and point them at the install script, then retry after they run it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh"   # from the plugin
# or, in the repo: scripts/install.sh
```

## Fast path: play requests

For any request shaped like "play X [on/in speakers] [at volume%] [shuffle]", forward the user's words to `music play` in ONE bash call: strip only the leading "play" and any % sign. The CLI's parser deterministically extracts speaker names (including several at once), volume, filler words ("in", "the", "and", "at", "on"), and a trailing "shuffle":

```bash
music play kid a in the kitchen and living room at 60
music play jazz for cooking kitchen 40 shuffle
```

Naming speakers routes playback to exactly those speakers (it deselects the rest). Don't pre-chain `music speaker` + `music volume` for simple play requests: `music play` does all three. If the query itself contains a speaker-like word, use the explicit flags (`--song`, `--album`, `--playlist`) instead. Named-speaker plays are verified automatically once playback starts (`✓ <speaker> verified (…)`); an unestablished route triggers an automatic heal before an honest failure message.

## Architecture

The music CLI has two backends:
- **AppleScript**: playback, speakers, volume, now playing, library browsing (no auth needed)
- **REST API**: catalog search, library writes, playlists via API, discovery (needs auth)

## When Bridge is the selected output

MusicTUI can also play through Bridge, its own built-in player, instead of
Music.app — chosen from the TUI's **Output** tab. Check which one is active
with `music now --json`: Bridge selected adds `"output": "bridge"`; nothing
there means Music.app.

With Bridge selected, transport and `music play`'s named forms play only from
Bridge's own library:

```bash
music now --json                                  # look for "output": "bridge"
music play                                        # resume
music play --playlist "Top 25 Most Played"        # plays in order
music play --playlist "Top 25 Most Played" shuffle # trailing "shuffle" shuffles it
music play --album "Kid A" --artist "Radiohead"   # in order; trailing shuffle works here too
music play --song "Idioteque" --artist "Radiohead"
music play --artist "Radiohead"
music search --library "Idioteque"                # numbered results, playable on Bridge
music play 2                                      # play result #2 from that search
music pause / music skip / music back / music stop / music seek +30
```

Bridge also serves catalog and discovery reads directly — no developer key
needed for any of these — and plays back what they find:

```bash
music search "Idioteque"                          # catalog search: songs and albums only
music play "https://music.apple.com/...?i=1440830346"  # a song link plays via Bridge
music play "https://music.apple.com/us/song/idioteque/1440830346"  # the /song/ link form works too
music radio search "apple music"
music radio play "apple music 1"                  # exact favorite name, or one unambiguous hit
music radio add "https://music.apple.com/station/..."  # favorites locally either way
music discover --json --limit 4
music playlist list
music playlist tracks "Top 25 Most Played"
music similar "Idioteque" --artist "Radiohead"
music recent
music rotation
```

What's different from Music.app mode:

- **Plain `music play <words>` refuses.** There's no fast-path parsing
  (speaker names, filler words, volume) and no bare-word search-and-play.
  Name what you want with `--song`, `--album`, `--playlist`, or `--artist`,
  run `music search --library "<query>"` then `music play N`, or search the
  catalog and play a song link (above).
- `--playlist`/`--album`/`--song`/`--artist` still play only from Bridge's own
  library — no catalog fallback for those forms.
- **Catalog search returns songs and albums only.** `music search --types
  artists` (or `playlists`) with Bridge selected refuses: `Bridge catalogue
  search returns songs and albums only in this version.`
- **Catalog playback is two forms only:** `music play N` on a catalog search
  result, and a one-argument Apple Music **song** link. Any other link
  (album, playlist, station) is treated as free words and refuses like plain
  `play <words>`.
- **A numbered result only plays back on the source and namespace that
  produced it.** A result from Music.app-mode search or history doesn't feed
  Bridge's `music play N`: `Result N came from a Music.app or catalogue
  listing, so Bridge can't play it by its own id. With Bridge selected, run:
  music search "<title>"  then  music play N`. A Bridge row — library or
  catalog — doesn't feed Music.app's `play N` either, with a sentence naming
  which kind it was.
- **Bridge catalog results can't feed `add N` or a playlist write.** If any
  resolved index came from Bridge (library or catalog search, or `similar`),
  the whole command refuses: `Result(s) N[, M] came from Bridge. Adding
  Bridge rows to your library or a playlist isn't supported yet; search again
  with Output set to Music.app.`
- **`radio play` never picks between two matches.** A favorite name (exact,
  then a unique substring) is tried first, then a station search; one match
  plays, but two or more refuse with the list instead of picking the first
  one (Music.app mode keeps its shipped first-match behavior).
- **`playlist list`/`playlist tracks`** list Bridge's own library; an
  ambiguous playlist name refuses the same way `play --playlist` does —
  exact name, then a unique substring, else a list and a request for the
  exact name.
- **`suggest` and `new-releases` still refuse in every form** — Bridge has no
  op for them, naming the Music.app switch.
- **`discover --recent` refuses**, naming the same fix: `Bridge doesn't serve
  the Recently Played rail. Switch Output to Music.app to use music discover
  --recent.`
- **Over 100 matching songs refuses** rather than queueing a huge list.
- **Volume and speaker commands refuse** (`music volume`, `music speaker
  ...`): there's no AirPlay routing from the CLI on Bridge yet. Use MusicTUI's
  Output tab, or switch Output back to Music.app.
- **`music shuffle`/`music repeat` and `music playlist temp` refuse** the
  same way.
- `music eq` and `music visualizer` are Music.app settings either way; they
  don't touch what Bridge plays.
- `music now --json` on Bridge never carries `album`, `duration`, `position`,
  `speakers`, or `live`; it adds a `queue` object while a play is still
  building. Text output tags the title `[Bridge]`, or says `Bridge is
  <state>.`/`Nothing playing on Bridge.` when idle. A play command's result
  line can say fewer were queued than requested (e.g. "Playing 39 of 42
  tracks") when Bridge skipped a song it doesn't have or a video-only track.

**Plays.** Library songs Bridge plays to the end are recorded in Music.app's
play count and last-played date via `music sync-plays`, same as before.
Catalog and Discover plays from Bridge — a catalog search result, a song
link, `similar`, `recent`, `rotation`, or a track played from the Discover
tab — are now recorded too, but only when the song has exactly one copy in
your library; with zero copies or more than one, the play isn't counted.
Radio station plays are never counted.

**Commands that read the current track still refuse**, because Music.app's
current track isn't what Bridge is playing: bare `music similar`, `music
suggest`, `music new-releases --like-current`, `music add --to` with no song,
`music remove`, `music love`/`music unlove`. Name the song explicitly instead.

Music.app mode is exactly as it ships; none of the above applies unless
Bridge is the selected output.

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
music play --album "Kid A" --artist "Radiohead" # explicit local Library album + artist; also `music play "X"` when X resolves to an album
                                                # creates temp playlist, bounded only when Autoplay off; see TUI Autoplay note
                                                # if the name matches more than one distinct album, nothing plays; add --artist or a more specific name
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
music sync-plays                              # record Bridge's finished library plays in Music.app
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

`music speaker <name>` (add), `set`, and `only` verify the route automatically while playing: output gains a `✓ <speaker> verified (…)` line, and an unverified route triggers an automatic heal (away-and-back reroute, then a transport-cycle reset) before falling back to an honest failure naming the manual fix. While paused, routing can't be network-verified, so it prints `Route set; will verify on next play.` and re-checks when playback starts. Scripting's own claims (`selected`, `active`) are shown as advisory only, not trusted, because they can lie. Routing to the Mac's own output is never "verified": local output has no AirPlay session.

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
opens the Equalizer window. On a permission error, relay the command's hint:
it names the exact System Settings toggle.

| Request | Command |
|---|---|
| "make it sound like a dungeon" / "nightclub mode" | `music eq dungeon` / `music eq nightclub` |
| "more bass" | `music eq "Bass Booster"` |
| "flat" / "turn off the EQ" | `music eq flat` / `music eq off` |
| "what's the EQ?" | `music eq` |
| "remove the venue presets" | `music eq remove-pack` |

Venue pack: Nightclub, Dungeon, Open Air, Concert Hall, Jazz Club, Stadium,
Cathedral, Late Night. Any other name forwards verbatim; Music's built-in
presets (Acoustic, Hip-Hop, Loudness, …) all resolve. Unknown names print
near-matches.

## Visualizer (no auth)

`music visualizer [on|off]` toggles Music's on-screen visualizer (the Cmd-T
visuals). Same UI-scripting + Accessibility requirement as the equalizer.
GUI-only: the visuals render in the Music window on the Mac's display (not on
AirPlay outputs), and turning it on brings Music to the front.

## Radio (favorites/URL: no auth · search: developer token)

```bash
music radio list                              # your favorite stations
music radio play "bbc radio 1"                # play a favorite by name (fuzzy match)
music radio play "https://music.apple.com/us/station/apple-music-1/ra.978194965"  # play a URL directly
music radio add "https://music.apple.com/us/station/apple-music-1/ra.978194965"   # favorite a station by URL
music radio search "deep house"               # search catalog stations
```

`music radio play <name|url>` is the entry point for casual requests: "put on
BBC Radio 1", "play Apple Music 1", "put on some radio". It checks favorites
first (no network), then treats the argument as a URL if it looks like one,
then falls back to catalog search, which needs a developer token. A station
plays via its share URL with the scheme swapped from `https://` to `music://`;
no AppleScript, no MusicKit, and the current AirPlay route survives.

**Apple's station search is shallow and unreliable**: roughly 5-7 results, no
pagination, and it misses real stations outright. It can't find BBC Radio 1 at
all, not even by its own catalog id, though the station plays fine once you
have its URL. When `music radio search` or `music radio play <term>` comes
back empty, do NOT tell the user the station doesn't exist; ask them for the
station's share URL from music.apple.com (or the Music app's share menu) and
play or favorite that instead:

```bash
music radio play "https://music.apple.com/us/station/<slug>/<id>"
music radio add "https://music.apple.com/us/station/<slug>/<id>"
```

Favorites are stored locally at `~/.config/music/stations.json` and don't sync
to other devices.

## Search (catalog: developer token · library: no auth)

```bash
music search "Bohemian Rhapsody Queen"        # search songs (writes to cache)
music search "Fouk" --limit 20               # control result count
music search "house" --types songs,albums,artists,playlists  # multi-type catalog search
music search "The Smiths" --library          # search YOUR library (no token, Music's own library)
music search "kid a" --library --types playlists             # library, specific types
music search --artist "Radiohead"             # narrow the query text by artist (on --library these filter the library, not the query text)
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
music play --song "Teardrop"                 # plays exactly that song, then stops
music play "Teardrop" "Massive Attack"       # same, title + artist

music playlist temp "Song1" "Artist1" "Song2" "Artist2"   # temp playlist, play; hidden from the rail, cleanup is manual
music playlist create-from "Song1" "Artist1" "Song2" "Artist2" --name "My Mix"  # create + populate
music playlist cleanup                        # delete unused __temp__ and __album__ playlists; spares one in active playback
```

## Discovery (requires user token)

```bash
music similar                                 # similar to now playing
music similar Hotel California                # similar to a specific track (--artist to narrow)
music discover                                # your Discover feed: curated rails + recently played
music discover --all                          # every rail the API returns, in Apple's own order
music discover --recent                       # just the Recently Played rail (mixed types)
music discover --json --limit 5               # rails as JSON
music recent                                  # recently played tracks (needs user token; cached for `play N`)
music rotation                                # your heavy-rotation music
music suggest                                 # suggest tracks from now playing
music suggest 10 --from "Working Vibes"       # suggest from playlist vibe
music new-releases --like-current             # new releases from current artist
music new-releases --artist "Fouk"            # new releases from specific artist
music mix --artists "Fouk,Floating Points" --count 20 --name "Friday Mix"  # mixed playlist
```

## Interactive TUI (requires real terminal, not Claude Code)

```bash
music                                         # unified shell: Now / Discover / Library / Playlists / Radio / Output tabs
```

Bare `music` is the main interactive surface: a tabbed shell with **Now**, **Discover**, **Library**, **Playlists**, **Radio**, and **Output** tabs. (`music now` / `music now --json` and `music playlist <subcommand>` are non-interactive CLI commands, documented above.) Four one-shot quick pickers also exist for terminal/slash-command use: bare `music speaker` (AirPlay picker), bare `music volume` (mixer), and the `music similar` / `music suggest` result pickers.

TUI behavior: the Now tab shows the current album context; selecting a playlist on the Playlists tab pins it on the Now tab. Cursor movement is local and fast. On the Output tab, toggling a speaker on while playing verifies the route and toasts if it couldn't be verified. The Library tab (no token needed) browses your library in three sub-views: Artists, Albums, Songs (opens on Artists), switched with `[`/`]`; Enter opens an album's tracks (or drills Artist → their albums → tracks), `p` plays and `s` shuffles the item in focus. On the Artists list, `a` cycles a track-count filter: All → 12″/EP (artists with a 2 to 5 track release) → Albums (artists with a 6+ track album), separating 12″s/EPs from full-album deep cuts; the raw list otherwise includes every artist with any library track (even one pulled in by a single playlist song). Library and Playlists heroes show real cover art (fetched once, disk-cached; gradient placeholder while loading or when no cover can be found). The Discover tab (needs the user token) shows Apple's For You rails with **Recently Played** hoisted to the top, five curated rails at four items each by default; navigation is three levels deep, Discover then a rail then a track list, each level keeping its own cursor and scroll position. `r` refreshes the top level, `←`/`Esc` backs out a level, `→` drills in and never plays. `Enter` plays a station outright, opens a read-only track list for an album or playlist, opens the full rail for a `View all N` row, and plays a track inside a drill-in from that track to the end of the container (it slices the temporary playlist from the chosen track onward, so the bounded play form still starts from a beginning, and it turns shuffle off first so the chosen track is the one that starts; `p` leaves shuffle alone). `p` plays an album or playlist row directly, bounded to it, and does nothing on a station, a `View all N` row, or a track row. Playing this way adds the album to the user's library permanently: Discover creates a temporary playlist to play it and removes that playlist afterward, but the songs it added stay, because Apple gives no way to prove which library rows this app added versus ones the user added themselves, so an automatic cleanup could delete music they added on purpose (the temporary playlist goes when the TUI quits, or at a later launch when the app could not confirm it was the one playing; a Discover play pressed while the startup cleanup is still running waits for it to finish first, with a toast saying so) (see docs/platform-notes.md for the platform limits behind this). The Radio tab browses **Favorites · Live · Personal** stations, switched with `[`/`]` (Favorites needs no token; Live and Personal need a developer token). `Enter`/`→` plays, `f` favorites/unfavorites, `/` opens a catalog search (hits land in the list, `Esc` clears back to the sub-view), `a` opens an add-by-URL field: paste a station URL to favorite it directly; anything that isn't a URL redirects to `/` instead of being guessed at. Only `↑↓`/`j`/`k` and `Enter`/`→`/`l` are wired; no page/home/end jumps.

TUI controls: `1/2/3/4/5/6` switch tabs (Now / Discover / Library / Playlists / Radio / Output), `Tab`/`Shift-Tab` cycle tabs, `[`/`]` switch Library sub-view or Radio Favorites/Live/Personal, `↑↓` navigate (`PgUp/PgDn/Home/End` for long lists, Now/Playlists/Output/Library only), `Enter` play/open selected, `←→` seek (Now) or volume (Output), `Space` pause, `</>` previous/next track (full up/down through the playlist), `z` shuffle-play (`s`/`m`/`r`/`g` shuffle/order/repeat/Genius on Now), `l` favorite (Now), `f` favorite (Radio), `+/-` volume, `n` next-up options (Now), `/` filter playlists (arrows navigate while typing) or search the Radio catalog (Enter runs the search), `Esc` back, `q` or `Ctrl-C` quit (Ctrl-C quits even from inside a search or filter field). Playlist track-play requires Music's Autoplay (∞) turned OFF: it drives playback track-by-track and needs each track to stop at its end. CLI album playback (`music play --album`) is bounded the same way and needs the same setting.

## Result Cache

Search, similar, suggest, new-releases, and playlist tracks write results to `~/.config/music/last-songs.json`. Speaker list writes to `last-speakers.json`. Follow-up commands reference results by index:

```bash
music search "house"        # results cached as 1, 2, 3...
music play 3                # play result #3
music add 3                 # add #3 to library
music add 3 --to "House"    # add #3 to playlist
music playlist create "House" 1 3 5  # create playlist from results
```

Rows from `music search --library` are tagged as library rows; index follow-ups on them (`add`, `playlist add`, `playlist create`) need no token, and `music add N` on one reports that it is already in your library instead of calling the API.

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
| No auth | play, pause, skip, back, stop, now, shuffle, repeat, speaker, volume, radio list/play/add, search --library | search, add, playlist (API), similar, suggest, new-releases, mix, radio search |
| Developer token only | Above + search, radio search | add, playlist (API), similar, suggest, new-releases, mix |
| Both tokens | Everything | — |
| Bridge selected (any token tier) | play (named forms and `N`), search (catalog and `--library`), a song link, radio list/search/play/add, discover, playlist list/tracks, similar, recent, rotation — none of these need a developer key | shuffle, repeat, speaker, volume, playlist temp, suggest, new-releases, mix, add, playlist (API) |

## Workflow: Complex Requests

**Minimize tool calls.** Chain independent commands with `&&` in a SINGLE bash call where possible.

"Play X on speaker Y at volume Z" is NOT a multi-step request: `music play` handles routing and volume natively (see Fast path above):

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
- Never chain `music speaker` + `music volume` + `music play` for a play request: one `music play` call does all three
- Use `--json` on search to get structured results for parsing
- Both `create-from` and index-based create handle errors gracefully
- After `music search "query" --library`, build playlists by index without a token: `music playlist create "Name" 1 2 3`. Mixed catalog and library rows need the user token for the catalog rows only; library rows are added either way.

## Output Modes

- **Default:** Human-readable text for terminal
- **`--json`:** Structured JSON for scripting and Claude

Always use `--json` when you need to parse the output programmatically.

## Error Handling

- **"Config not found"**: Run `music auth setup`
- **"User token required"**: Run `music auth`
- **"API request failed with status 401/403"**: Token expired, run `music auth` again
- **"No tracks found"**: Try a broader search query
- **"No station found for..."**: Radio search is shallow; ask the user for the station's share URL from music.apple.com and use `music radio play <url>` / `music radio add <url>` instead
- **Speaker commands fail**: Check exact speaker name with `music speaker list`
- **"Bridge output is selected, and ... isn't available from the CLI on Bridge yet."**: That command isn't wired to Bridge (volume, speakers, shuffle/repeat, `playlist temp`, plain `play <words>` and any non-song Apple Music link). Use MusicTUI, or switch Output to Music.app on the Output tab.
- **"Bridge output is selected, and music suggest needs Apple Music account reads Bridge doesn't serve."** / **"...music new-releases needs a catalogue artist lookup Bridge doesn't serve."**: Bridge has no op for either read. Switch Output to Music.app to use them.
- **"Bridge doesn't serve the Recently Played rail. Switch Output to Music.app to use music discover --recent."**: same reason, for `discover --recent` specifically; plain `music discover` is served.
- **"Bridge catalogue search returns songs and albums only in this version."**: drop `--types artists`/`playlists` when Bridge is selected, or switch Output to Music.app.
- **"Bridge output is selected, so Music.app's current track is not what you are hearing."**: The command reads the "current track" (bare `similar`, `suggest`, `new-releases --like-current`, `add --to` with no song, `remove`, `love`/`unlove`), which would be wrong while Bridge plays something else. Name the song explicitly instead.
- **"Result N came from a Music.app or catalogue listing, so Bridge can't play it by its own id."** / **"...came from Bridge's library, which Music.app can't play by identity."** / **"...came from Bridge's catalogue search, which Music.app can't play by identity."**: A numbered result only plays back on the source and namespace that produced it. Search again with the matching Output selected (add `--library` for Bridge's library; drop it for the catalog).
- **"Result(s) N came from Bridge. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app."**: `add N` and `playlist create/add` can't take a Bridge row (library or catalog) by index yet.
- **"'<name>' matches N favourite stations..."** / **"'<name>' matches N stations..."**: `radio play` on Bridge never guesses between two or more matches; use the exact name or paste the station URL.
- **"Output is being switched; nothing was changed. Try again."** / **"Output changed to Music.app/Bridge while this command ran; nothing was changed."**: Another MusicTUI process (the TUI, most likely) changed the Output tab at the same moment. Retry the command.
- **"Bridge is still playing."** (from `music pause`): Bridge didn't confirm it stopped playing. Try `music pause` again, or check MusicTUI.
