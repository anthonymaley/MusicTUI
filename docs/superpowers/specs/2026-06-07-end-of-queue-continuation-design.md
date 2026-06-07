# End-of-Queue Continuation — Design

**Date:** 2026-06-07
**Status:** Approved (design); pending implementation plan
**Scope:** When a playlist/queue ends and Apple Music falls into library autoplay, offer a card menu in the Now Playing scene to redirect playback (artist radio / similar / another playlist / quiet).
**Components:** `tools/music/Sources/TUI/Shell/PlaybackPoller.swift` (detection), `NowPlayingStore.swift` (snapshot fields), `NowPlayingScene.swift` (card menu + actions); reuses `startRadioStation`, the `Similar` discovery path, `extractArtwork`/`artworkToAscii`, `play playlist`, `pause`.

## Goal

Turn the current dead-end — a playlist ends and Apple Music silently dumps you into a wall of library autoplay ("from Music", indices like 5758–5800) — into an intentional "what next?" moment: a card menu offering **Artist Radio**, **Similar**, **Playlist**, or **Quiet**, each acting by *forcing* the chosen playback.

## Key decision — react, don't suppress

We do **not** try to stop Apple Music's Autoplay (whether AppleScript can disable it is unverified and irrelevant here). Instead:

- Autoplay keeps the room from going silent (Music's default behavior is left alone).
- The poller **detects** the queue-end transition.
- The Now Playing scene shows the card menu.
- A card selection issues a `play`/`pause` command that **overrides** whatever autoplay started.

Forcing playback always works; this sidesteps the autoplay-suppression unknown entirely.

## Detection (the hard part)

The trigger must fire on *natural queue-end*, not when the user deliberately plays from the library. The guard:

1. The poller tracks the current **context** (playlist name + the current track's index + total, from `pollContextQueue`).
2. "Queue ended" is detected only when **all** hold:
   - the previous context was a real playlist (its name was **not** the library — not `"Music"`/`"Library"`),
   - the previously-playing track was at/near the **last index** of that context (`index >= total - 0` at a natural end), and
   - the next poll shows the current playlist switched to the **library** (autoplay) — a different, library-kind context.
3. On detection, the poller captures an **ended-context snapshot**: the just-ended playlist name, and the **last context track's** title + artist + album art (captured *now*, because "current track" is already an autoplay track and will not reference the track we care about).

A manual jump to a library track fails condition (the previous track wasn't the natural last-of-context), so it won't false-trigger. Tightening this guard against real playback is the primary implementation risk and gets dedicated attention + the manual verification in the plan.

The detected state clears when the user picks a card (we force new playback) or when playback re-enters a real (non-library) context.

## Snapshot additions

`NowPlayingSnapshot` gains:

```
queueEnded: Bool                       // show the card menu
endedPlaylist: String                  // name of the playlist that just ended
endedTrack: String                     // last context track title (for Radio/Similar)
endedArtist: String                    // last context track artist
endedArtLines: [String]                // last context track album art, captured at detection
```

These are populated by the poller on detection and read by the Now Playing scene. (Art is captured at detection because the live `artLines` will have moved on to the autoplay track.)

## The card menu

When `queueEnded`, the Now Playing scene replaces the Up Next list with a card row:

| Key | Card | Art | Action (forces playback, overriding autoplay) |
|---|---|---|---|
| **R** | Artist Radio from *<endedTrack>* | `endedArtLines` | radio from the **remembered** ended artist/track (not the current autoplay track) |
| **S** | Similar to *"<endedTrack>"* | `endedArtLines` | play tracks similar to the remembered ended track |
| **P** | Playlist | playlist icon / generic | `push(.playlists)` — pick another playlist in the existing browser |
| **Q** | Quiet | ⏹ icon | `pause` (best-effort stop of whatever autoplay started) |

Header: `Queue ended — what next?`. Left/right (or the letter keys) select; the existing globals still work (you can also just `1`/`2`/`3` to leave, or `Space` to keep autoplay). Selecting a card clears `queueEnded`.

**Important correctness point:** Radio and Similar must act on the **remembered** ended track (`endedTrack`/`endedArtist`), not `current track`. The existing `startRadioStation()` reads the *current* track, which at this moment is an autoplay track — so this milestone needs a variant that takes an explicit artist/track (e.g. `startRadioStation(track:artist:)`), with the no-arg version delegating to it for the current track.

## Reused primitives

- **Artist radio:** `startRadioStation()` (`NowPlayingTUI.swift:346`) — already builds an artist station (catalog search → temp playlist, or library-by-artist fallback when unauthed). Parameterize it to take an explicit track/artist.
- **Similar:** the `Similar` discovery path (`Commands/DiscoveryCommands.swift:4`).
- **Art:** `extractArtwork()` + `artworkToAscii(path:width:height:)` — used for the card thumbnails (small, e.g. ~14×7).
- **Playlist / Quiet:** `play playlist`, `pause` via `syncRun`.

## Testing

- **Detection guard** is the testable core: a pure function `detectQueueEnd(prevContextName:prevWasLibrary:prevIndex:prevTotal:prevAtNaturalEnd:newContextIsLibrary:) -> Bool` (or similar) unit-tested across the cases: natural last-track end → library (true); manual library jump (false); mid-playlist track change (false); last track but not natural end (false).
- **Card menu key→action mapping** is a pure table test.
- Rendering (cards + art) is thin and verified live, per the project's TUI convention.

## Scope

**In (v1):** detection guard; snapshot fields; card menu with R/S/P/Q; Radio (remembered artist) + Similar + Playlist-browse + Quiet-pause; card art from the ended track.

**Out (deferred):**
- A *smart* "suggested next playlist" (auto-picked) — v1's `[P]` just opens the playlist browser.
- Suppressing Apple Music autoplay (the stop-and-choose variant) — not pursued.
- Artist *images* (vs the ended track's album art) for the Radio card — album art is the proxy.
- A countdown/auto-pick default — v1 leaves autoplay running until the user chooses.

## Risks

1. **Detection false-positives/negatives** — the central risk; the guard above plus live verification address it. If it proves unreliable, fall back to a manual trigger (a key in Now Playing that opens the same menu on demand).
2. **`startRadioStation` currently reads the current track** — must be parameterized or the radio will be built from the wrong (autoplay) track. Called out so it isn't missed.
3. **Art capture timing** — the ended track's art must be captured at detection, before the poller re-extracts for the autoplay track.
