# Vim keys + kitty-protocol cover art

**Date:** 2026-07-14 · **Status:** approved (user: "lets do both") · **Ships as:** 3.6.0

## Feature 1: Vim navigation aliases

Grep-verified key inventory: `j`/`k`/`h`/`ctrl-d`/`ctrl-u` unbound everywhere;
`l` and `g`/`G` bound ONLY on the Now tab (love, Genius).

- **Tier 1 (all scenes):** `j`→down, `k`→up, `h`→left/back, `ctrl-d`/`ctrl-u`→
  half-page down/up in list scenes (jump by visibleRows/2, clamped).
- **Tier 2 (Playlists/Library/Speakers only, NOT Now):** `l`→right/open,
  `G`→bottom of list, `g`→top of list. Now keeps love + Genius untouched.
- Implemented as a **pure alias function** applied at the top of each scene's
  `handle`: `vimAlias(_ key: KeyPress, listScene: Bool) -> KeyPress` mapping
  chars to the arrow/paging KeyPress cases the scenes already handle;
  `listScene: false` (Now) passes `l`/`g`/`G` through untouched. Unit-tested.
- Half-page: scenes that scroll (`railScroll` etc.) handle a new synthesized
  `.pageDown`/`.pageUp` KeyPress case if one exists, else map to N×down/up at
  the scene level (implementer: check KeyPress enum; smallest diff wins).
- Footer hints unchanged — aliases are silent.

## Feature 2: Kitty graphics protocol for cover art

Verified: the kitty graphics protocol is an open spec
(https://sw.kovidgoyal.net/kitty/graphics-protocol/) implemented by kitty,
iTerm2 (3.5+), WezTerm, Ghostty, Konsole, Warp. We implement the spec in
Swift; no third-party code. Fallback ladder grows one rung:
**kitty pixels → chafa half-blocks → mono blocks → gradient**.

### Sharp edges (named up front, all must be honored)

1. **Quiet mode everywhere.** Every graphics command carries `q=2` — without
   it the terminal writes replies to stdin, which our raw-mode key loop would
   read as garbage keypresses.
2. **PNG only.** Transmit format is `f=100` (PNG). Our cached bytes are JPEG
   (mzstatic CDN) — convert via CoreGraphics (CGImageSource → CGImageDestination
   PNG) before transmit. Pure function, unit-tested with a fixture.
3. **Transmit once, place per frame-change.** `a=t` (transmit only) with a
   stable `i=<id>` per artwork cache key (FNV-1a hash of the key → UInt32,
   avoiding 0); placement is a separate tiny `a=p,i=<id>,c=<cols>,r=<rows>,q=2`
   at the cursor. Chunk base64 payloads at 4096 bytes (`m=1` continuation,
   final chunk `m=0`).
4. **Images outlive text.** A cleared frame does NOT clear placed images.
   Scenes must delete the previous placement when the displayed cover changes
   (`a=d,d=i,i=<id>`), and the shell emits delete-all on quit alongside its
   existing terminal restore. Implementer MUST verify exact `d` semantics
   against the spec page before coding.
5. **Detection is env-based for v1** (no stdin response parsing):
   `$KITTY_WINDOW_ID` set, or `$TERM` contains "kitty", or `$TERM_PROGRAM` ∈
   {WezTerm, ghostty}, or (`$TERM_PROGRAM` == iTerm.app AND
   `$TERM_PROGRAM_VERSION` ≥ 3.5). Apple Terminal fails all → chafa, today's
   behavior. Pure function over an env dict, unit-tested.
6. **Sizing:** placement uses `c`/`r` (cells) so the terminal scales the image
   to the same cell rect the half-block art occupies — zero layout change in
   scenes; hero/Now geometry is untouched.

### Integration shape

- New file `TUI/KittyGraphics.swift`: capability detection, JPEG→PNG,
  escape building (transmit/place/delete), id hashing — all pure or
  seam-injected, no terminal I/O in the functions themselves.
- ArtworkStore: when the terminal supports kitty, `lines()` callers instead
  receive a placement descriptor (id + transmit-escape-if-first-time). The
  scenes' art branch emits it instead of looping half-block lines; gradient
  and chafa paths unchanged. Now tab (PlaybackPoller cached art) gets the same
  treatment via the same helper.
- Live verify: run `music` inside iTerm2 (pixels), then Apple Terminal
  (chafa, unchanged), quit both and confirm no image ghosts in scrollback.

## Out of scope

Runtime capability query (v2 if env detection misses terminals), sixel,
iTerm2's OSC 1337 protocol (kitty covers iTerm2 3.5+), animated placeholders.
