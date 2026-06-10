# TODO

Current high-priority follow-ups before a broad public push.

## Current Session (2026-06-10 — doc sync + v1.16.1 release + tend + Apple-curated playlists 1.17.0) — DONE

**Done.** Two segments: (1) synced all docs with 1.16.0 reality, shipped v1.16.1 (docs-only patch), published the first GitHub release since v1.6.1, ran `/kerd:tend` (7 passing, 2 warnings). (2) Shipped **1.17.0**: Apple-curated playlists (Loops, Replay, Essentials…) now appear in the TUI rail with an `APPLE` badge.

- [x] **1.17.0 (user-reported):** curated playlists invisible in the TUI — root cause: they're AppleScript class `subscription playlist`, not `user playlist`; the rail's `every user playlist` omitted all 9 (verified live: 49 user + 9 subscription + 1 library). Rail now enumerates both classes in one call (`U`/`S` + unit-separator format, pure parser tested); APPLE badge; downstream untouched (resolves `playlist "name"` generically). Suite 107→112. Live-verified in tmux: all 9 render with badges, Replay 2022 track browse loads. **NOT live-verified: playing one** (music was actively playing; user asked to test `p`/Enter on an APPLE playlist).

- [x] **README:** TUI key tables rewritten from source (`GlobalKeymap.swift` + scene handlers — old table predated the tabbed shell); added `/music:repeat`, `seek/love/unlove`, `recent/rotation`; auth matrix rows; statusline path 1.7.0→1.16.1.
- [x] **docs/guide.md:** 14 commands / 24 subcommands; current TUI contract + full keymap; real source tree (Shell/, LoveCommands, HistoryCommands); 4-location version rule.
- [x] **SKILL.md description:** added favorites / seek / listening-history triggers.
- [x] **v1.16.1** in all four locations; CLI rebuilt (`music --version` confirms); 107 tests green; commit `98a0dd2` pushed.
- [x] **GitHub release v1.16.1** published + tagged — notes digest everything since v1.6.1 (April). Gotcha hit and fixed: quoted heredoc kept `\`` escapes literal in the release body; re-uploaded clean notes.
- [x] **`/kerd:tend`:** structure healthy (vault, hooks, naming, skills all pass). Two warnings, both UNRESOLVED — see open question below.

**Open question (blocks the tend fixes):** the `.gitignore` "Dev-only files" block lists CLAUDE.md, TODO.md, .slainte, kivna/, docs/playbook.md — but `git ls-files` shows they're all TRACKED, so those entries are no-ops and the "not shipped to consumers" comment is false (tracked files ship with every clone). Only AGENTS.md and docs/naming.md are genuinely ignored. Asked what the block's original intent was; not yet answered. **New evidence at switch-out: the `kivna/` entry blocked `git add` of the new session log (needed `-f`) — the block actively breaks the handoff convention for any NEW kivna file.** Recommendation: delete the dead entries. Also pending: delete 15 on-disk `.DS_Store` files (untracked, zero repo risk).

**Watch-items (not blocking):**
0. **Playing an APPLE-badged playlist is NOT live-verified** (1.17.0) — user to confirm `p`/`s`/Enter on one; reads verified, playback path expected to work (generic name resolution) but unheard. Also: user can now delete the manual duplicates ("Loops (June)", "Nu Cumbia (Apple)") once confirmed.

**Watch-items (carried from 2026-06-09):**
1. **osascript watchdog firing on a real hang is NOT live-verified** — needs a naturally sleeping HomePod; logic is simple, flagged in playbook.
2. `music rotation` works but this account's heavy-rotation is empty — re-check after more listening.
3. Empty-Now-tab CTA render not visually confirmed (the 4-poll stop tolerance outlasted the capture window); change is a one-line render branch.

---

## Backlog

- **F5 (review, deferred):** real search type filters (`types=albums,artists,playlists`) + `/v1/me/library/search`; currently `--artist`/`--album` just concatenate into the query.
- Playbook "Current Status" now stacks 7 version entries — `/kerd:trim` candidate along with the completed shell spec/plans under `docs/superpowers/`.
- Confirm synced `__queue__` playlists are gone from the phone (carried from 2026-06-08; needs a look at the device).
- Sleep timer: evaluated and rejected (needs a detached process; the skill can schedule a pause instead).

### Context
- **Decisions locked this session:** quick pickers (bare `music speaker`/`volume`/`similar`/`suggest`) are blessed one-shots backing the interactive slash commands — "bare `music` is the only TUI" was false and is now documented as "main TUI". Playlist adds are playlist-only (no library side effect). The fast-publish contract: any consumer keying off "snapshot changed" must tolerate stale secondary fields.
- Worked directly on `main` (project convention). `docs/playlist-browser-ui.md` intentionally untracked.

## Playback Semantics

- Confirm playlist-origin playback continues naturally at track end after queue adoption from native context (1.14.1 path) over longer listening.
- Keep `z` as shuffle-only in the TUI unless repeat gets its own explicit key.
- Do not auto-reset AirPlay outputs during normal playback. Use `music speaker wake` for explicit ghost-speaker recovery.

## Docs

- Keep README, `skills/music/SKILL.md`, and `docs/guide.md` aligned whenever TUI keys or AirPlay behavior changes.
- Treat `docs/superpowers/*` as historical design/planning notes unless a new implementation round explicitly updates them.
