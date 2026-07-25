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

**What does work** (observed 2026-07-15, not re-verified since): take the station's
REST `url` and rewrite the scheme from `https://` to `music://`, then `open` it.

```
open "music://music.apple.com/us/station/apple-music-1/ra.978194965"
```

Music.app comes forward, `player state` becomes `playing`, audio starts, and an
existing AirPlay route survives. The same URL with `https://` opens Safari instead,
so the scheme rewrite is the entire trick. Tested only with a live station
(`isLive=true`); track-based and personal stations are untried.

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

## Corrections

If any of this is wrong or has changed in a later macOS release, please open an issue.
Dated observations are more useful than confident ones, and a correction with a
version number is the most useful thing you can send.
