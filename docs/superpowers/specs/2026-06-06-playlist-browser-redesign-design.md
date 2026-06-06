# Playlist Browser Redesign — Design

**Date:** 2026-06-06
**Status:** Approved (design); pending implementation plan
**Scope:** `music playlist` 2-pane browser → 3-zone product surface
**Component:** `tools/music/Sources/TUI/ListPicker.swift` (`runPlaylistBrowser`) + the caller in `Commands/PlaylistCommands.swift` (`PlaylistBrowse`)

## Goal

Make the playlist browser feel like a designed product surface rather than terminal output in columns: intentional, colorful, fast, legible, useful before the user presses Enter.

The v1 rule, agreed with the user:

> **truthful data · instant shell · progressive enrichment · stable layout**

No fabricated data. The shell paints immediately. Metadata fills in without shifting layout.

## Data grounding (verified empirically)

Probed against the live Music app (55 user playlists) — these are facts, not assumptions:

| Field | Source | Cost |
|---|---|---|
| Track count | `count of tracks of playlist` | cheap (slow only for the 13k-track library playlist) |
| Total duration | `duration of playlist` (seconds) → format `Hh Mm` | cheap |
| Smart flag | `smart of playlist` (bool) | cheap |
| Special kind | `special kind of playlist` | cheap |
| Name | `name of every user playlist` | one call, instant |
| Tracks (preview/full) | `every track of playlist X` | per-playlist, lazy |

A batched query for all 55 (`name|count|duration|smart` each) takes ≈2.0s — **too slow to block on at launch**, hence progressive enrichment.

**Not available (must not be faked):**
- No playlist-level "last played" / "modified" timestamp → **drop "updated 2d ago".**
- No mood/tag data → **drop "Deep house · Warm" tags.**
- Real playlist artwork is fetchable but complex to render → **use a generated gradient block in v1.**

## Architecture

The TUI is **single-threaded and synchronous**: the browser loop is `KeyPress.read(timeout:)` → `render()`, and every AppleScript call goes through `syncRun`, which blocks on a semaphore. There is no background worker and no shared mutable state across threads. The design must not introduce one (it would add data races to a currently race-free codebase).

Enrichment therefore rides the existing event loop (tick-driven), not a thread.

### Data model

```
struct PlaylistMeta {
    let name: String          // known at launch
    var trackCount: Int?      // nil = not yet loaded
    var durationSec: Int?
    var isSmart: Bool?
    var specialKind: String?
    var loaded: Bool          // all fields resolved
}

enum PlaylistBadge { case radio, smart, recent, none }
```

`badge(for:)` derivation (pure, unit-testable):
- name has `__radio__` prefix → `.radio`
- `specialKind` indicates a special playlist, or name ∈ {"Recently Played", "Top 25 Most Played"} → `.recent`
- `isSmart == true` (and not radio/recent) → `.smart`
- else → `.none` (row shows the track count)

### Enrichment mechanism (tick-driven incremental fetch)

State in `runPlaylistBrowser`:
- `meta: [PlaylistMeta]` — initialized from names, all optional fields nil.
- `loaded: Set<Int>` — indices fully enriched.

Loop:
- Timeout = `loaded.count < meta.count ? 0.15s : 60.0s`.
- On **key**: handle it; if it scrolled, the visible window changed → next tick re-prioritizes. Re-render.
- On **idle tick** with work pending: select up to **5 unloaded indices, visible rows first** (then nearest-to-visible, then the rest in order); run **one batched AppleScript** returning `name|count|duration|smart|specialKind` for those indices; fill `meta`; mark `loaded`; re-render. Status line shows `Loading metadata… <loaded>/<total>`.
- When `loaded` is full: revert to the 60s idle timeout; drop the status line.

Batch size 5 keeps each blocking call ≈0.2s so input stays responsive. **Known one-time blip:** if a batch includes the ~13k-track library playlist, that batch runs ~1.5s. Acceptable as a non-recurring event; documented, not hidden.

### Preview fetch (right panel)

Separate from enrichment. A **light 8-track query** for the selected playlist, fetched on **cursor-settle** (debounced: fire when the cursor has been stable for one tick), cached per index. Distinct from the existing 200-track fetch (`onTracks`) that still runs on Enter/browse and feeds the now-playing context. While a preview is loading: a subtle `Loading preview…` — never the old `Enter to browse tracks` placeholder.

## Layout

Width-adaptive zones from `ScreenFrame.width`:

```
┌─ rail (~34) ─┬─gut─┬─ hero (~52) ─┬─gut─┬─ right panel (rest, cap ~52) ─┐
```

- **≥138 cols:** 3 zones (rail · hero · right).
- **96–137 cols:** 2 zones (rail · hero); preview panel drops.
- **<96 cols:** rail · compact hero.

Gutters are 3 cols. Rail is fixed ~34; hero and right split the remainder with caps so an ultra-wide terminal doesn't sprawl (leftover becomes right margin). Zone math is a pure function (unit-testable).

### Rail rows (stable columns)

`▌ <name>  <meta>` where:
- marker (2 cols): `▌ ` (selected) / `  ` (not).
- meta column: **fixed ~6 cols, reserved from first paint.** Renders a dim `·` while `nil`; once loaded, a right-aligned count (dim) or a badge (amber: `RADIO`/`SMART`/`RECENT`).
- name: truncated to fill the space *between* marker and the reserved meta column. Because the meta column width is constant regardless of load state, values land without shifting the name → no structural jump.
- selected row: full highlighted bar, cyan when the rail is focused, dim when focus is on the track list.
- currently-playing playlist: small lime marker.

### Hero card (center)

- **Title:** playlist name, bright white, bold, wrapped/truncated to hero width — visually dominant.
- **Subtitle:** dim `64 tracks · 4h 12m` from `meta`. Blank until loaded; never fake.
- **Gradient block:** truecolor block (~16 cols × ~7 rows) seeded by `hash(name)` (pure, deterministic, no fetch). Anchors the eye. Not real artwork.
- **Badges:** amber chips (`RADIO`/`SMART`/`RECENT`) when applicable.
- **Actions:** lime-emphasized `[Enter] Browse · [P] Play · [S] Shuffle · [/] Filter`.

### Right panel — Preview (v1)

`Preview` header (cyan) + thin rule + first 8 tracks (dim index + title). Demand-loaded as above. `Now Playing` and `Recent` modes, `Tab` cycling, and live polling are **deferred to phase 2.**

## Interaction

- `↑↓` — move playlist selection; updates hero + preview live (not a no-op until Enter).
- `Enter` — expand the right panel into a full scrollable track list and move focus there (reuses existing `BrowserFocus.tracks`); `Enter` again plays the selected track with context.
- `P` play · `S` shuffle selected playlist.
- `/` — filter playlists (client-side on names, instant; query shown under the header; counts update live).
- `b` / `N` — jump to full Now Playing.
- `q` / `Esc` — quit (Esc from track focus returns to rail).
- Grouped one-line footer: `Browse ↑↓  Open Enter  Play P  Shuffle S  Filter /  Now b  Quit q`.

## Color roles (exactly five)

cyan = section headers · bright white = selected title / key values · lime = active/playing + primary action · dim gray = metadata / low-priority · amber = badges. **Never all-green.** Green (lime) means active/live/current only.

## Render & flicker rules

- Keep the `clearBody(frame)` per-row clear already added (commit `7591d27`).
- One buffered `print` per frame.
- Fixed zone geometry + reserved meta column → enrichment repaints overwrite same-width cells, no shimmer.
- Filter and scroll re-render the full body (cheap, keypress-driven).
- `clearLine` (ESC[2K), not space-fill, to stay transparent-terminal friendly.

## Scope

**v1 (this spec):** 3-zone layout + responsive fallback · tick-driven enrichment + status line · stable rail rows with counts/badges · hero card with gradient block + actions · Preview panel (8 tracks) · five-role color system · client-side filter · grouped footer · keep `clearBody`.

**Deferred (phase 2):** real playlist artwork · Now-Playing / Recent panel modes + `Tab` cycling + live now-playing polling · dominant-genre line in the hero · `R` radio-from-selected · `Space` pause/play of the active playlist.

## Build order

1. Rail with tick-driven enrichment + status line (the load model is the spine).
2. Hero card (gradient + title + subtitle + actions).
3. Preview panel (light 8-track fetch).
4. Color cleanup + badge system.
5. Filter / search affordance.
6. (Phase 2) panel modes + live now-playing.

## Testing

**Unit-testable (pure functions — will be covered):** zone-width math across terminal widths, `badge(for:)` derivation, duration→`Hh Mm` formatting, name truncation against the reserved meta column, gradient seeding determinism, the enrichment queue's visible-first prioritization.

**Not runtime-testable in CI:** the live TUI (rendering, input, the enrichment feel). The implementer builds + runs the unit tests and the **user verifies the live behavior** — first paint speed, fill-in without layout shift, no flicker, filter responsiveness.

## Risks / honest limits

- The single slow batch (13k-track library playlist) is a one-time ~1.5s blip; acceptable, documented.
- Cursor-settle preview debounce could feel laggy on very fast scrolling; tune the debounce tick if so.
- `special kind` string values for "recent"-type playlists are not fully enumerated here; the `badge` derivation will fall back to name-matching for the known special playlists and to `.smart`/count otherwise.
- Gradient block is a stand-in for identity, not real artwork; if it reads as gimmicky in practice, it's cheap to drop.
