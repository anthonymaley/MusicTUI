# TODO

Current high-priority follow-ups before a broad public push.

## Current Session (2026-06-09 — full review → seven releases, 1.11.2 → 1.16.0) — DONE

**Done.** Ran a three-agent review (perf / design-UX / features-architecture) of the whole app, then cleared the entire finding list in bundles, each shipped + live-verified same-day. Suite went 85 → 107 tests. All pushed.

- [x] **1.11.2 quick wins:** `music remove` playlist-name escaping bug; album-context Enter-jump off the regressed verb; dead code deleted (−8 tests of dead coverage); doc drift (playbook header, 14→13 commands, SKILL.md stale keys).
- [x] **1.12.0 TUI responsiveness:** poller fast-publishes metadata before context+artwork; art cache per album|artist (drop chafa `--work 9`); lean 1s poll (no AirPlay enumeration); preview fetches off the input loop; render-on-change (store generation + scene dirty flag). Track change visible ≤1.2s (was 1-3s+).
- [x] **1.13.0 feedback channel:** StatusStore footer toast; ActionRunner serial queue for all user-initiated osascript (input loop never blocks); coalesced volume keys; async speakers/track-list loads; continuation-menu Quiet `q`→`x` (q quits), Esc dismisses.
- [x] **1.14.0 REST playlist writes:** `createPlaylist(name:songIDs:)` + `addTracksToPlaylist` replace the addToLibrary→sleep-4s→AppleScript-duplicate dance at all six sites (create-with-tracks 0.56s, add 1.2s, measured); `libraryTrackLookupScript` single definition; `waitForLocalPlaylist` bounded poll. Behavior change: playlist adds no longer copy songs into the library.
- [x] **1.14.1 regression fix (user-reported):** two stacked bugs — fast-publish broke the cursor snap (wrong-track-on-Enter; `snapCursorIndex` only consumes a track change when the rows contain it), and native-playlist-context Enter collapsed to the alphabetical library (now ADOPTS the app queue from the context playlist).
- [x] **1.15.0 AirPlay deep dive:** osascript watchdog timeout (45s; one hung `set selected` used to freeze the whole action queue); pipe-order deadlock fix; -1728→speakerUnavailable; bulk device reads (6x measured: 0.21s vs 1.23s); cache-first name resolution (named commands 3 spawns→1); `only` selects target first (could empty ALL outputs); wake verifies reselection ("Lost X" honesty); ergonomics (similar variadic, volume validation, shuffle toggle, delete confirm, --json sweep).
- [x] **1.16.0 backlog cleared:** PgUp/PgDn/Home/End + Shift-Tab; arrows-while-filtering; unified inverse-video selection; empty-state CTA; narrow-art guard; `l` favorite key; `music seek/love/unlove/recent/rotation`; ASCII-unit-separator field hardening; AppQueueStore finally tested; `/music:repeat`; play.md collapsed to CLI parsing; statusline prefers jq.

**Watch-items (not blocking):**
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
