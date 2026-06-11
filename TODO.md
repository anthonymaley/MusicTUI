# TODO

Current high-priority follow-ups before a broad public push.

## Current Session (2026-06-11 — segment 2: 3.0.0 skill-only surface) — DONE

**Done.** Shipped **3.0.0** (breaking): ALL slash commands removed — `/music` (the skill) is the single entry point; transport belongs to the Mac's media keys. CLI gained one-command multi-room play.

- [x] **Decision archaeology:** user saw the 10-command menu and expected "most gone". Transcript (raw jsonl — episodic-memory plugin is broken on this machine, Node module mismatch) showed his original 2.0.0 ask was skill-only; my "keep transport" recommendation shipped via an ambiguous "lets do it" against a fork question. His media-keys argument (⏯ ⏭ ⏮ beat any typed command) then killed the transport lane entirely.
- [x] **PlayParser** (TDD, 13 tests): multi-speaker token-span matching (kills the "kitchenette"→Kitchen substring bug), filler-word cascade ("in the kitchen and living room at 60"), %-volume, trailing shuffle. **PlayResolution** (5 tests): whole-query playlist/album/song lookup BEFORE the two-arg song+artist split — live verification caught `kid a` playing "Sinister Kid" (Black Keys) via `artist contains "a"`.
- [x] **Exclusive routing:** naming speakers in `music play` = play exactly there (select-first, per-device try — same shape as `speaker X only`). Semantics change from additive; release-noted.
- [x] **Live-verified** multi-room on Kitchen + Living Room (Kid A, exclusive group, per-device vol). User's playback state captured first and fully restored after (track, position, outputs, volumes).
- [x] 10 command files deleted; SKILL.md = sole entry (play fast-path forwards words verbatim to `music play`; CLI-missing branch → install.sh); README/guide rewritten around media keys → /music → TUI → CLI; "zero setup" claim removed (false since the osascript fallback tier went with the commands).
- [x] Versions 3.0.0 ×4, suite 112 → 130 green, CLI rebuilt + installed. Commit `694e2af`, tag v3.0.0, release published + verified Latest (`gh release list`).
- [x] Switch-out hygiene: playbook Current Status + gotchas + tree updated; playbook's stale install identifiers fixed (same wrong names the vault MOC carried — second copy found); CLAUDE.md structure block updated.

**For the user:** `claude plugin update music@apple-music-marketplace` + session restart to see the one-entry menu. Local CLI already at 3.0.0; statusline unaffected (repo path).

**Open question (blocks the tend fixes, carried):** the `.gitignore` "Dev-only files" block lists CLAUDE.md, TODO.md, .slainte, kivna/, docs/playbook.md — all TRACKED, so the entries are no-ops; the `kivna/` entry actively blocks `git add` of new session logs (needs `-f`). Recommendation: delete the dead entries. Also pending: delete 15 on-disk `.DS_Store` files.

**Watch-items (not blocking):**
0. **Playing an APPLE-badged playlist is NOT live-verified** (1.17.0) — user to confirm `p`/`s`/Enter on one; reads verified, playback path expected to work (generic name resolution) but unheard. Also: user can then delete the manual duplicates ("Loops (June)", "Nu Cumbia (Apple)").
0b. Statusline wrapper's Music-stopped branch (ctx-free only) not exercised — trivial empty-check, but unobserved.

**Watch-items (carried from 2026-06-09):**
1. **osascript watchdog firing on a real hang is NOT live-verified** — needs a naturally sleeping HomePod; logic is simple, flagged in playbook.
2. `music rotation` works but this account's heavy-rotation is empty — re-check after more listening.
3. Empty-Now-tab CTA render not visually confirmed (the 4-poll stop tolerance outlasted the capture window); change is a one-line render branch.

---

## Backlog

- **Statusline shim idea (from 2.0.0 session):** the README's plugin-cache statusline path embeds the version and breaks on every `plugin update` — consider shipping a tiny stable shim that resolves the newest `~/.claude/plugins/cache/apple-music-marketplace/music/*/` at runtime so consumers configure once.
- **Vault has no audit:** tend/slainte check the repo, nothing checks the vault — the MOC carried wrong install identifiers for weeks. Candidate: extend slainte to the vault folder.
- **F5 (review, deferred):** real search type filters (`types=albums,artists,playlists`) + `/v1/me/library/search`; currently `--artist`/`--album` just concatenate into the query.
- Playbook "Current Status" now stacks 7 version entries — `/kerd:trim` candidate along with the completed shell spec/plans under `docs/superpowers/`.
- Confirm synced `__queue__` playlists are gone from the phone (carried from 2026-06-08; needs a look at the device).
- Sleep timer: evaluated and rejected (needs a detached process; the skill can schedule a pause instead).

### Context
- **Decisions locked 2026-06-11 (segment 2, SUPERSEDES the morning's lane split):** the plugin ships NO slash commands — `/music` (skill) is the single entry point; transport = media keys; determinism lives in the CLI's PlayParser, not the menu. Named speakers in `music play` = exclusive routing. Resolution order: whole-query before song+artist split. Removing public commands = major bump (now twice).
- **Earlier 06-11 decision (still holds):** statusline for the plugin author points at the repo copy, not the versioned cache path.
- **Earlier decisions (still hold):** quick pickers (bare `music speaker`/`volume`/`similar`/`suggest`) are blessed one-shots; playlist adds are playlist-only (no library side effect); fast-publish consumers must tolerate stale secondary fields.
- Worked directly on `main` (project convention). `docs/playlist-browser-ui.md` intentionally untracked.

## Playback Semantics

- Confirm playlist-origin playback continues naturally at track end after queue adoption from native context (1.14.1 path) over longer listening.
- Keep `z` as shuffle-only in the TUI unless repeat gets its own explicit key.
- Do not auto-reset AirPlay outputs during normal playback. Use `music speaker wake` for explicit ghost-speaker recovery.

## Docs

- Keep README, `skills/music/SKILL.md`, and `docs/guide.md` aligned whenever TUI keys or AirPlay behavior changes.
- Treat `docs/superpowers/*` as historical design/planning notes unless a new implementation round explicitly updates them.
