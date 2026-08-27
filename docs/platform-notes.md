# Platform Notes: Scripting Apple Music on macOS

Findings from building MusicTUI against Music.app. Every entry below was observed on a
real system, with the date it was checked. Where a claim has not been re-verified
recently, it says so.

Most of this is undocumented, and several of the failures are silent. If you are
automating Music.app, start here.

Tested on macOS 26 (Tahoe), Apple Silicon, Music.app with an active Apple Music
subscription. Behaviour on earlier macOS versions is untested.

---

## Apple Event cost: the first one is expensive, the rest are nearly free

Measured 2026-07-25, five runs each, steady state after warm-up:

| Operation | Wall time |
|---|---|
| Bare process spawn (`/usr/bin/true`) | ~0 ms |
| `osascript` startup, no Apple Events (`-e 'return 1'`) | ~50 ms |
| Precompiled `.scpt` + 1 Apple Event to Music | ~140 ms |
| `osascript -e` + 1 Apple Event to Music | ~160 ms |
| Same script, 8 properties instead of 1 | ~210 ms |

Two consequences:

**Compiling the script is not the bottleneck.** A precompiled `.scpt` saves roughly
20 ms out of 160. Caching compiled scripts is close to pointless.

**Establishing the channel to Music.app is the bottleneck.** The first Apple Event
costs roughly 90 ms once you subtract `osascript` startup. Each additional property
in the same script costs about 7 ms. That is a 13x difference, so the single most
effective optimisation is putting more properties into one script rather than issuing
several.

Because the cost is per *invocation* rather than per *query*, the language calling
`osascript` is irrelevant to performance. Swift, Rust, Go, and Python all wait the
same ~150 ms.

## `current track` throws -1728 for tracks outside your library

On macOS 26, reading `current track` properties fails for anything not in the user's
library, including streamed catalog tracks:

```
error "Music got an error: Can't get name of current track." number -1728
```

The same failure hits `duration of current track` and `player position`.

Confirmed by Apple DTS on the Developer Forums
([thread 798267](https://developer.apple.com/forums/thread/798267), verified
2026-07-25). Quinn "The Eskimo!" at DTS: *"if I had to guess I'd say this is just a
bug."* A second DTS engineer noted it "could be interpreted as either a bug or an
enhancement request", and a filed report was later classified as a duplicate of a bug
assigned to the Music app team. Filed separately from here as FB19908171.

Verified 2026-07-25 that library tracks are unaffected: reading `name` and
`persistent ID` of a paused library track returns normally. The breakage is scoped to
non-library sources, which matches the forum thread.

**Workaround:** never assume identity reads succeed. Fall back to name plus artist
when `persistent ID` throws, and treat a missing `duration` as a valid state rather
than an error.

## Pre-release tracks are in your library and silently refuse to play

An album added before its release date appears in the library with a full tracklist.
The unreleased tracks report `cloud status = prerelease`, and `play track N of
playlist "Library"` on one of them **does nothing**. No error, no audio, no change to
`player state`.

Verified 2026-07-25 on an album releasing 2026-08-28:

```
osascript -e 'tell application "Music" to get cloud status of \
  tracks of playlist "Library" whose album is "Mere Mortals"'
→ prerelease, subscription, prerelease, prerelease, prerelease, subscription, ...
```

12 of 14 tracks were `prerelease`. Only two would play.

**Workaround:** filter by `cloud status` before queueing, and use a *denylist*, not an
allowlist. Exclude `prerelease`, `removed`, and `no longer available`. Local files
report other values including `unknown` and must stay playable, so allowlisting breaks
them.

## A library album's artist credit does not always match its stored album artist

The artist string shown by the Apple Music API can differ from the `album artist`
stored in the local library. Observed divergences on the same album:

- Separator: `"A, B"` from the API versus `"A & B"` in the library.
- Per-track soloists: on classical and collaborative releases, `artist` differs on
  nearly every track.

So this matches nothing:

```applescript
tracks of playlist "Library" whose album is X and (artist is A or album artist is A)
→ 0 tracks
```

while `whose album is X` alone returns all 14.

**Workaround:** match on album title, then disambiguate in your own code with
punctuation folded (`", "`, `" & "`, case). Do not fold `"and"`, which changes real
titles.

Found 2026-07-24, fixed in MusicTUI 3.8.1.

## A `whose` fetch returns tracks in Library position order, not album order

`every track of playlist "Library" whose album is X` yields tracks in ascending
Library `index` order, which need not match the album's track order. Observed
2026-07-27 on a 14-movement album: the fetch arrived with Movement 2 first and
Movement 1 third. A player that queues the fetch result as it arrives can start an
album mid-way.

**Workaround:** read `disc number` and `track number` per track and sort in your own
code. Every track tested returned a positive integer for both; guard the reads
anyway, since other per-track reads (`cloud status`) can throw on local files.
MusicTUI treats 0 or a failed read as no number, sorting those tracks last in
fetched order.

Found 2026-07-27, fixed in MusicTUI 3.8.2.

## AppleScript has no concept of a radio station

Verified 2026-07-25: the string `station` does not appear **anywhere** in Music.app's
scripting definition.

```
sdef /System/Applications/Music.app | grep -ci station
→ 0
```

What does exist is `radio tuner`, `radio tuner playlist`, and `radio tuner playlists`.
These are vestigial legacy Internet Radio, holding `URL track`s whose `address` is a
plain stream URL. They are unrelated to Apple Music stations.

A station URL sitting in your library as a `URL track` is an inert bookmark. Calling
`play` on it stops the player silently: no error, no stream, no audio.

**What does work** (observed 2026-07-15, re-verified 2026-08-25): take the station's
REST `url` and rewrite the scheme from `https://` to `music://`, then `open` it.

```
open "music://music.apple.com/us/station/apple-music-1/ra.978194965"
```

Music.app comes forward, `player state` becomes `playing`, audio starts, and an
existing AirPlay route survives. The same URL with `https://` opens Safari instead,
so the scheme rewrite is the entire trick.

Verified 2026-08-25 for a personal station too (`ra.u-…`, the "Made for You" station,
`format: tracks`, `hasDrm: false`), not just the live ones: opening its URL switched
playback away from an unrelated playing track and started station audio.

### The scheme is a station play verb, not a general play verb

Measured 2026-08-25, three ways, all negative:

```
open "music://music.apple.com/us/album/glory-single/6795095658"          → no playback
open "music://music.apple.com/us/album/glory/6795095658?i=6795095659"    → no playback
osascript -e 'tell application "Music" to open location "music://…?i=…"' → no playback
```

Music.app did not come forward and `player state` did not change in any of the three.
The control in the same session, a station URL, played immediately. A station URL is an
action, so it autoplays; an album or song URL is a location, and Music.app treats it as
one. There is no known way to make a catalog album play from a URL.

A playing station has no track model. It surfaces as a `URL track` whose `name`,
`artist`, and `album` update per song, but `duration` is `missing value`,
`player position` pins at `0.0`, and `current stream title` stays `missing value`.

## The stations REST endpoint has no browse-all

Catalog stations need only a developer token, no user token. But an unfiltered
`GET /v1/catalog/{storefront}/stations` returns `400 Missing Parameter`. You must pass
`ids`, `filter[featured]=apple-music-live-radio`, or `filter[identity]=personal`.

Station `playParams` contain `{format: stream, hasDrm: true, kind: radioStation,
stationHash: …}`. The DRM'd handle is why no AppleScript path exists.

Observed 2026-07-15, not re-verified.

## Personal and artist stations have a track feed, live stations do not

Undocumented, found 2026-08-25 by probing. A `GET` returns `405 Method Not Allowed`
rather than `404`, which is what gives the route away:

```
GET  /v1/me/stations/next-tracks/{stationId}  → 405 Method Not Allowed
POST /v1/me/stations/next-tracks/{stationId}  → 200, two catalog songs
```

Five successive POSTs to a personal station returned ten distinct songs with no repeat,
so it behaves as a rolling feed rather than a fixed list. It requires a Music User Token
(`403` without one) and it returns full catalog song objects, ids included.

The DRM boundary holds exactly where `playParams` says it does. A live station
(`format: stream`, `hasDrm: true`, for example Apple Music 1) returns `{"data": []}`.
Only `format: tracks` stations, which is what personal, Discovery, and
"& Similar Artists" stations are, produce songs.

Not established: whether draining this feed advances the station's real playback state
for the listener.

## The library API is add only

Verified 2026-08-25 against a Music User Token. Adding works, removing does not:

```
POST   /v1/me/library?ids[songs]=…       → 202 Accepted
DELETE /v1/me/library/songs/{id}         → 401
DELETE /v1/me/library/playlists/{id}     → 401
```

Every deletion has to go through AppleScript (`delete` on the track or playlist), which
succeeds without an error and without raising a confirmation dialog. The practical
consequence is that nothing can clean up a library write unless Music.app is running and
scriptable, so there is no such thing as a headless cleanup pass.

Timing note for the add: the response is `202`, not `200`, and materialization is
asynchronous. One song appeared in `/v1/me/library/songs` after about 2 seconds, four
songs after about 6 seconds. Any fixed sleep after an add is a race.

## Adding a catalog song to a playlist also adds it to your library

Measured 2026-08-25. Creating a library playlist with catalog song ids in
`relationships.tracks` does not just populate the playlist:

```
POST /v1/me/library/playlists  with 4 catalog song ids
→ playlists 52 → 53,  songs 14167 → 14171,  albums 2958 → 2959
```

Deleting the playlist afterwards leaves the songs and the album behind. A playlist is
therefore not a lighter-touch container for catalog content than the library itself.
This happens server side through the API, so Music.app's own "add to library" preference
does not govern it.

## Deleting a library track collapses the queue that pointed at it

Measured 2026-08-25, and the two halves are different:

Deleting the **currently playing** track does not stop it. A track removed from the
library mid-play kept playing normally, well past the point of removal.

Deleting the **rest of the queue** destroys it. After adding a four track album, playing
it, and then removing all four tracks from the library, `next track` became a silent
no-op: the position simply advanced on the one track still sounding. Music.app's play
queue holds references to library rows rather than copies, so the playing track survives
on already buffered audio while everything behind it becomes unreachable.

Deleting the **playlist** the queue came from is safe. With the same album played from a
temporary playlist, deleting that playlist mid-play left the queue intact and
`next track` continued to advance through the remaining tracks. The queue depends on the
library rows, not on the container that seeded it.

## The EQ scripting interface reports state that disagrees with the UI

`EQ enabled`, `EQ preset`, and `current EQ preset` are all declared in the scripting
definition. They do not all work, and one of them lies.

Four reads taken back to back on 2026-07-25, same moment, nothing touching the app:

| Read | Result |
|---|---|
| `name of every EQ preset` | works, returns the full list |
| `EQ enabled` | `false` |
| `name of current EQ preset` | `-1728` error |
| Music.app's own EQ window | **on, preset "Small Speakers"** |

So enumerating presets is fine, reading the current preset throws the same `-1728` seen
on `current track`, and `EQ enabled` returns a value that contradicts the actual state
of the app.

The obvious explanation, that the EQ was simply switched off and therefore had no
current preset, does not survive. The equalizer was on the whole time.

**Caveat on which one is right.** The "on, Small Speakers" reading comes from the
equalizer window rather than from AppleScript, so strictly this documents a
*disagreement* between two interfaces to the same state. Confirming which is ground
truth means opening Music's Equalizer window and looking. Either way, the two do not
agree, and code that trusts `EQ enabled` will be wrong at least some of the time.

**Workaround:** do not trust EQ reads. Probe every EQ read and write, and treat a
returned value as a hint rather than as state. If you need the real setting, read the
equalizer window through the Accessibility API instead.

## Kitty graphics: deleting a placement does not keep the image data

If you render cover art with the [kitty graphics
protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/), do not assume
transmit-once works.

The protocol's delete actions suggest that `d=i` removes placements while keeping
image data resident, so a later `a=p` could re-display an already-transmitted image
without resending bytes. **This does not hold on real terminals.** Re-placing without
re-transmitting renders nothing.

The failure mode is nasty: each image displays correctly exactly once per session.
Scroll a list down and back up and every cover is blank. It is invisible in long
lists, because nobody re-checks a cover they already scrolled past.

Worse, this was pinned by a passing unit test asserting that the second call returned
no transmit escape. The test encoded the bug, so it stayed green permanently.

**Workaround:** re-send the cached transmit escape whenever the placement changes.
Cache the encoded PNG, not the decision to skip sending it.

Also worth knowing:

- Send `q=2` on every command. Without it, terminal replies corrupt a raw-mode key loop.
- `f=100` accepts PNG only. Convert JPEG first.
- A placement stretches to fill its cell rectangle, while `chafa` letterboxes. Clamp
  the rectangle to a square equivalent (cells are roughly 1:2) or art comes out
  stretched.

Found 2026-07-15 as a shipped bug in MusicTUI 3.6.0, fixed the same day.

---

## `include=library` tells you what a user owns, never who added it

Verified 2026-08-27, both directions, against a real library.

`GET /v1/catalog/{sf}/songs?ids=a,b,c&include=library` reports library membership
for many catalog songs in a single request, with a user token. A song the user
owns comes back with one entry under `relationships.library.data`, and that
entry's `id` is the library id, for example `i.OWGzxc4eMxPv`. A song they do not
own comes back with an empty array.

Membership is three valued in practice, and the distinction matters if you plan
to act on it. Only an explicitly present empty array proves absence. An absent
`relationships` block, an absent `library` key, an absent `data` key, a `data`
value that is not an array, and an entry carrying no `id` all mean the API said
nothing useful. Treating any of those as "not in the library" is how you end up
deleting somebody's music.

The important limit is what this cannot tell you. It reports **ownership at the
moment you ask**, not **authorship**. Check before an add and check again after,
and all you have proved is that a row appeared between two observations. If the
user added the same catalog song in Music.app during that window, the identical
library id and persistent id appear, and nothing distinguishes their action from
yours. Apple exposes no created-by attribution for a library row, so any cleanup
built on a before and after comparison can delete music the user added
deliberately.

## There is no safe automatic cleanup for catalog tracks you add

Following from the two notes above, and measured 2026-08-27.

Playing catalog content requires copying it into the library first, because
`music://` plays only stations and the REST API has no play verb. Removing those
rows afterwards is where it breaks down.

Two AppleScript forms exist and neither is usable for automatic cleanup:

| Form | Effect |
|---|---|
| `delete track N of playlist "<a user playlist>"` | Unlinks from that playlist only. Library count did not move, 14192 to 14192, while the playlist emptied. |
| `delete (every track of playlist "Library" whose persistent ID is "...")` | Deletes the library row, 14192 to 14191. |

The first is the intuitive one and it is a silent no op on the library. Cleanup
built on it reports success, empties the playlist, and leaves every song behind.

The second does delete, and that is the problem: it will delete whatever you name,
and per the note above you cannot prove you are the one who added it.

AppleScript also cannot address a REST library id at all. Its dictionary exposes
`id` as an integer, `database ID` as an integer, and `persistent ID` as sixteen
hex characters. None of them is or derives from `i.OWGzxc4eMxPv`. Measured on a
single real track: `database ID 28277`, `id 49796`, `persistent ID
4AA20FFE48BCDF9C`, against a REST library id of `i.1YEo2uLBV16r`. Any pairing has
to be built while a playlist containing the rows still exists, using position as
the join key, and it is unrecoverable once that playlist is gone.

Matching on name is not an escape. The same probe found five separate rows titled
"Hand In Glove" in one library.

The conclusion this project reached: delete only containers you created and can
prove you created, by their own name prefix, and leave library rows alone. If
cleanup matters, it belongs in an explicit command that lists what it will remove
and asks first, not in an automatic sweep claiming an authorship the platform
cannot establish.

## Playing catalog content from a browse surface grows the library permanently

Measured 2026-08-27, and a direct consequence of the two notes above.

MusicTUI's Discover tab plays a catalog album by creating a temporary playlist
from catalog ids and playing that. The temporary playlist is removed afterwards.
The songs are not, and cannot safely be.

So playing an album from Discover adds it to your library and it stays there. A
four track EP adds four songs and one album. This is documented rather than
hidden because it is the actual price of playing catalog content on a platform
with no write free play verb, and a user deserves to know that pressing play
touches their library.

## `play playlist` is bounded, `play track N of playlist` is not

Measured 2026-08-27 against a five track temp playlist, checking `current
playlist` and stepping to the end each time.

| AppleScript | `current playlist` becomes | What happens at the end |
|---|---|---|
| `play playlist "X"` | `X` | plays the five tracks and stops |
| `play track N of playlist "X"` | `Music` | queue is library rooted and continues into unrelated artists |
| `play playlist "X"`, then `play track N of playlist "X"` | `Music` | worse, `next track` becomes a permanent no op |

The second form reads like a scoped play and is not one. It is a track play
command that happens to name a playlist: Music.app plays the song, discards the
playlist as context, and roots the queue in the library. The first form
establishes a real playlist context, and `next track` then navigates inside it.

This matters for any tool that builds a temporary playlist to play a specific
album. If you start it with `play track N` you get correct audio for that track
and a queue that wanders into the rest of the library once the album ends, which
looks like a queue bug and is not.

`set current playlist` is not writable, so there is no way to attach a context
after the fact. It fails with error `-10006`.

One workaround exists and is worth knowing about, though this project chose not
to ship it. `play playlist "X"`, then `pause`, then `next track` repeated, then
`play`, keeps the bounded context the whole way and lands on any chosen track
silently. It costs one Apple Event per step, it has only been verified for
sequential non shuffled playback, and on a setup where transport control travels
over AirPlay that is a lot of control traffic to start one song.

## Corrections

If any of this is wrong or has changed in a later macOS release, please open an issue.
Dated observations are more useful than confident ones, and a correction with a
version number is the most useful thing you can send.
