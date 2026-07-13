# Library Tab — Design Spec

**Date:** 2026-07-11
**Status:** Approved for planning
**Topic:** A 4th TUI tab ("Library") for browsing and playing your Apple Music library — Albums, Artists, Songs.

## Context & Purpose

The shell TUI (`music` with no subcommand → interactive) has three tabs today: Now, Playlists, Speakers. The user wants a 4th "Library" tab that browses library items "like the playlist tab, but for Albums, Artists, Songs" (originally "…and Pins" — see Scope). The interaction model is **browse-and-play**, mirroring the shipped playlist browser.

## Scope

**In:**
- A `Library` tab with three parallel sub-views — **Albums, Artists, Songs** — that the user toggles between within the one tab.
- Each sub-view is browse-and-play, reusing the playlist browser's 3-zone layout and colour language.
- Artists drills one level: artist → their albums → album tracks → play. A shuffle-artist action plays everything by the selected artist without drilling.

**Out:**
- **Pins.** Verified not reachable: `sdef /System/Applications/Music.app` exposes no "pin" entity (only an unrelated `grouping` property), and the Apple Music REST API has no pins endpoint. Pins are a client-side personalization feature Apple does not expose to automation. Dropped unless Apple adds scripting support. The tab is three sub-views, not four.
- Editing the library (add/remove/rename) — browse-and-play only.
- Image artwork — it's a terminal; we use the same colour/gradient language as the playlist browser.

## Navigation Model

Three sub-views, each a browse-and-play list. Switch between them with `[` / `]` (digits and Tab are reserved for top-level tab switching, so sub-views get their own keys — exact keys tunable during build).

- **Songs** — a single flat, filterable list of library songs. Enter plays the selected track.
- **Albums** — rail of albums → Enter opens the tracklist (hero + track pane) → `p` plays the album, Enter/`p` on the album plays it; Left/Esc backs to the rail. Identical interaction to the playlist tab.
- **Artists** — rail of artists → **Enter drills into that artist's albums** (breadcrumb `Artists ▸ <name>`), pick an album → tracks → play. **`s` shuffles the artist's whole catalogue immediately** without drilling. Left/Esc steps back one level.

Common keys across sub-views: `↑↓` move, `[`/`]` switch sub-view, `Enter` open/drill, `Left`/`Esc` back, `/` filter the current list, `p` play. `s` shuffles **in context** — the artist (from the artist list), the album (from an album view), or the visible songs (Songs view). The footer hint states the active set.

### Navigation as a pure reducer

The sub-view mode and the drill levels live in a **pure `(state, key, itemCount) → (state, action)` reducer**, factored out of the scene so it is unit-testable without live rendering — the same separation `PlaylistBrowserModel` gives `PlaylistsScene` and the `MusicScripting` seam gives `RouteHealer`.

- **State:** `mode ∈ {albums, artists, songs}` + a per-mode level path:
  - Albums: `[albumList]` → `[albumList, tracks(album)]`
  - Artists: `[artistList]` → `[artistList, artistAlbums(artist)]` → `[artistList, artistAlbums(artist), tracks(album)]`
  - Songs: `[songList]`
  - Plus a cursor index and an optional filter string per level.
- **Actions the reducer emits** (the scene executes them; the reducer stays pure): `fetchArtistAlbums(artistID)`, `fetchAlbumTracks(album)`, `play(target)`, `shuffle(target)`, `none`. `[`/`]` resets to the new mode's root level; `Enter` drills or plays depending on the level; `Left`/`Esc` pops a level (no-op at root).

## Data Source Decision

**Browse via the REST library API; play via the existing AppleScript path.**

Music's AppleScript dictionary has **no album or artist class** — they are only track *properties*. Listing "your albums" via AppleScript means pulling every track in the Library playlist and deduping client-side: a multi-second call and heavy parse on a large library. The REST library API exposes them as first-class **paginated collections** (`/v1/me/library/{albums,artists,songs}`), using the same account/user-token the plugin already uses (confirmed working live in the 3.4.0 search work). Playback reuses the existing AppleScript library-play (the `music play --album/--artist/--song` path), so a selected item plays exactly as it does today.

**Dependency:** the Library tab requires the Apple Music **user token**. Without it the tab refuses with a toast, the same courtesy the Playlists tab gives when there are no playlists.

## Architecture

### REST library methods (`Backends/RESTAPIBackend.swift`)

Paginated, with pure parsers mirroring the Task-D search helpers:

- `libraryAlbums(limit:offset:)`, `libraryArtists(limit:offset:)`, `librarySongs(limit:offset:)` → `GET /v1/me/library/{albums,artists,songs}?limit=&offset=`
- `artistAlbums(artistID:)` → `GET /v1/me/library/artists/{id}/albums` (the drill)
- Models: `LibraryAlbum {id, name, artist}`, `LibraryArtist {id, name}`, `LibrarySong {id, title, artist, album}`
- Free `parseLibraryAlbums/Artists/Songs(from:Data)` functions

**Verification item (resolve in build Task 1, before writing the parsers):** the library *list* endpoints return resources under a top-level `data` array, **not** the search `results{<key>}{data}` shape confirmed in Task D. This shape and the `/artists/{id}/albums` relationship path are from training data — read them live against the user's library once and pin the parser to the real response.

### `TUI/LibraryDataSources.swift` (new)

A struct of closures like `PlaylistDataSources`: `onAlbums`, `onArtists`, `onSongs`, `onArtistAlbums`, `onAlbumTracks`. Off-thread REST fetch → `NSLock`-guarded inbox → drained in `tick()`; an on-disk cache (`~/.config/music/library-{albums,artists,songs}.json`) for instant first paint and refresh-on-re-entry — the pattern `SpeakersScene`/`PlaylistsScene` already use.

### `TUI/Shell/LibraryScene.swift` (new)

Implements the `Scene` protocol, `id = .library`. Owns the `LibraryNav` state and delegates every key to the pure reducer, then executes the emitted action against the data sources / action queue. Renders via the shipped 3-zone helpers (`playlistZones`, `gradientBlock`, `railName`) and the five-role colour language, so it matches the playlist tab by construction. Songs renders as a single flat list (rail zone only); Albums/Artists use rail · hero · track-pane.

### Playback

The scene assembles the same arguments the CLI play path takes (`--album`/`--artist`/`--song`, plus shuffle) and runs them on the shell **action queue** (`actions.run`), which converts failures into footer toasts — identical to how `PlaylistsScene` plays.

### Shell seams (three edits)

- `Shell.swift:16` — add `(.library, "Library")` to the `tabs` array (digit-switch, Tab-cycle, and tab-strip rendering all generalise over `tabs` automatically).
- `Shell.swift:20-43` — an `ensureScene` case `.library` that builds `LibraryScene`; **refuses with a toast if there is no user token**.
- `Shell.swift:117` — footer literal `"1/2/3 Tabs"` → `"1/2/3/4 Tabs"` (the one hardcoded string that does not auto-generalise).

`SceneID.library` already exists (`Router.swift:5`); no enum change. SwiftPM globs `Sources/`, so the two new files need no manifest edit.

## Layout

```
 Now   Playlists   Speakers   Library
──────────────────────────────────────────────────────────────────────────────────
  ‹ Albums ·  Artists  ·  Songs ›                         [ ] switches sub-view
──────────────────────────────────────────────────────────────────────────────────
  ▸ Kid A              │   KID A                   │  1. Everything In Its Right…
    OK Computer        │   Radiohead · 2000        │  2. Kid A
    In Rainbows        │   10 tracks · 50 min      │  3. The National Anthem
    …                  │   ▓▓▓▓▓▓▓▓                 │  …
──────────────────────────────────────────────────────────────────────────────────
 ↑↓ move · Enter open · [ ] view · / filter · p play · s shuffle · 1-4 tabs
```

Colour roles (inherited from `docs/playlist-browser-ui.md`): cyan headers, bright-white selected title, lime = active/playing only, dim-gray metadata, amber badges. Zones degrade 3→2→1 by terminal width via the existing `playlistZones`.

## Testing

Pure and unit-tested:
- **Parsers** — library album/artist/song JSON fixtures → models (like `SearchTests`).
- **Path builders** — the `/v1/me/library/...` request paths (limit/offset, artist-albums relationship).
- **Navigation reducer** — `(state, key, itemCount) → (state, action)`: mode switching resets to root, Enter drills/plays at the right level, Left/Esc pops, shuffle-artist emits the shuffle action from the artist list, filter narrows the active level.

Scene rendering stays visual/manual, consistent with the other scenes. A live smoke pass at the end drives the real tab (browse each sub-view, drill an artist, play an album, shuffle an artist) against the user's library.

## Build Order

1. **Albums** — proves REST-browse + on-disk cache + rail/hero/tracks reuse + play, end to end (includes the Task-1 live shape verification and the shell seams).
2. **Songs** — a flat-list subset of the same machinery.
3. **Artists** — adds the drill level (`artistAlbums`) and shuffle-artist.

## Acceptance Criteria

- Pressing `4` (or Tab-cycling to it) opens a Library tab; `[`/`]` switches Albums/Artists/Songs.
- Albums: browse the rail, open an album's tracks, play it — matching the playlist tab's feel.
- Artists: Enter drills to the artist's albums → album → play; `s` shuffles the whole artist; Left/Esc backs out with a correct breadcrumb.
- Songs: a filterable flat list that plays on Enter.
- No user token → the tab refuses with a clear toast, never a crash or dead key.
- New parsers, path builders, and the navigation reducer are unit-tested; the full suite stays green.
- The library list-endpoint response shape is confirmed live before the parsers are finalised.
