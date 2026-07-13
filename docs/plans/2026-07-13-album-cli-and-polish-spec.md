# Spec: `play --album` match fix, shuffle-footer declutter, docs archive, 3.4.2

**Date:** 2026-07-13 · **Driver:** conductor session (Fable) · **Status:** approved, shipped as v3.4.2

## Context

`music play --album` (the path the `/music` skill drives) has the remix/compilation
match bug fixed in the TUI on 2026-07-12: remix albums credit each track to the
remixer, so `--album X --artist <album artist>` matches 0 tracks and reports
"No albums found". The TUI fix (`LibraryScene.swift:548`) added an
`album artist` alternative to the predicate.

**Scope finding (this session):** the TODO's "route the CLI through AppQueue too"
is NOT portable as written. AppQueue is advanced by the TUI's resident poller —
with Autoplay off each track stops at its end and the live process plays the next
(`AppQueue.swift:4-11`). A one-shot CLI exits immediately; an AppQueue it built
would play one track and stop dead. Up Next is not scriptable (probed 2026-07-12)
and temp playlists are the `__queue__` scar. Queue scoping for the CLI therefore
needs a resident driver — a separate design session, backlogged. This session
ships only the match fix.

## Steps

### 1. `[delegate, model: sonnet, effort: medium]` — album-artist match fix in the CLI album path

- **File:** `tools/music/Sources/Commands/PlaybackCommands.swift`, album branch
  (`if let album = album`, ~lines 33–64).
- **Current:** `let artistFilter = artist.map { " and artist contains \"...\"" } ?? ""`
- **Change:** the artist filter becomes an alternation:
  ` and (artist contains "Y" or album artist contains "Y")`.
  Keep `contains` (CLI input is user-typed, unlike the TUI's REST-canonical
  names which use `is`). Escaping stays `escapeAppleScriptString`.
- **Shape:** extract a pure helper so it's unit-testable — add
  `func albumArtistFilter(artist: String?) -> String` alongside the existing pure
  helpers in `tools/music/Sources/Commands/PlayParser.swift` (returns `""` for
  nil; returns the full ` and (artist contains ... or album artist contains ...)`
  clause, escaped, for a value). Wire the album branch to call it.
- **Why the alternation:** remix/compilation albums credit tracks to remixers;
  track `artist` never equals the album artist, so the old filter finds 0.
- **TDD:** red test first in the existing PlayParser test file (locate via
  `grep -rl PlayParser tools/music/Tests`): nil → empty string; a value → exact
  clause; a value containing `"` → escaped output.
- **Verify:** `cd tools/music && swift test` → 0 failures, count ≥ 248
  (suite is 246 before this step; ≥2 new tests). Match surrounding code style;
  comment density stays as-is (one line on the *why* at the call site is enough).
- **Return:** diff summary + last 5 lines of test output.

### 2. `[keep]` — rebuild, live verify

- `scripts/install.sh`; confirm `music --version` still reports 3.4.1 (bump comes in step 6).
- Find a remix/compilation album live (album artist ≠ track artists) via a small
  osascript probe; run `music play --album "<X>" --artist "<album artist>"` —
  expect playback (was NOT_FOUND). Regression check: `music play --album` without
  `--artist` on a normal album still plays.
- User confirms audio. Evidence gate: command output read back, not assumed.

### 3. `[delegate, model: haiku, effort: low]` — shuffle-footer declutter

- **File:** `tools/music/Sources/TUI/Shell/Shell.swift:143` — global footer row
  `"Space \u{23EF}  < > Skip  z Shuffle  +/\u{2212} Vol"` → `z Shuffle` becomes
  `z Reshuffle`. One site; disambiguates from every scene-local `s Shuffle`
  (Library, Playlists, Now Playing `[S]`).
- **Why `z` and not `s`:** every scene-local key acts on the selection (Enter,
  `p`, `s`) — the odd one out is global `z`, which re-shuffle-plays *current
  playback*. "Reshuffle" says that.
- **Doc touch:** `docs/guide.md:73` — "the global `z`, which shuffle-*plays* the
  current context" → "the global `z` (footer: *Reshuffle*), which shuffle-plays
  the current context". Then `grep -rn "z Shuffle" README.md docs skills` must
  return nothing (no doc quotes the old literal).
- **Verify:** `cd tools/music && swift build` succeeds; grep clean.
- **Return:** diff + grep output.

### 4. `[keep]` — /kerd:trim archival pass

- Invoke the trim skill for its remaining scope: archive the released spec/plan
  pairs out of `docs/superpowers/` → `docs/archive/superpowers/{specs,plans}/`
  (4 files, `git mv`), create `docs/archive/INDEX.md` (airplay pair shipped
  v3.3.0–3.4.0; library pair 3.4.0). **Note:** `docs/archive/` has never existed
  (checked git history) — CONTEXT's convention line references it aspirationally;
  this step makes it real.
- Fix the two `docs/superpowers/specs/...` references in CONTEXT.md to the new
  archive paths (edit at the vault path — Write refuses symlinks).
- **Verify:** `git status` shows renames not delete+add; `grep -rn "docs/superpowers" .`
  (excluding archive itself) returns nothing stale.

### 5. `[keep]` — state updates

- CONTEXT.md Key Decisions: record the AppQueue-is-resident finding (why the CLI
  can't adopt it). TODO Backlog: rewrite item 4c — match fix DONE, queue scoping
  becomes its own design item ("CLI album queue scoping needs a resident driver").
- Vault paths for both files.

### 6. `[keep]` — ship 3.4.2

- Bump all four version locations (plugin.json, marketplace.json ×2,
  Music.swift `CommandConfiguration(version:)`), `scripts/install.sh`,
  `swift test`, commit ("3.4.2: play --album album-artist match + footer
  declutter + docs archive"), push, `git tag v3.4.2 && git push origin v3.4.2`,
  `gh release create` (quoted heredoc), read the release body back.
- The tag+release is part of the bump, not a follow-up (drift recurred twice).

## Acceptance

- Remix album plays via `music play --album X --artist <album artist>` (live).
- Suite green ≥ 248; no doc references the old footer label or unarchived paths.
- v3.4.2 tagged + GitHub-released, body read back.
