# TODO

Current high-priority follow-ups before a broad public push.

## Current Session (2026-06-11 — 2.0.0 transport-only trim + release + vault tidy) — DONE

**Done.** Shipped **2.0.0** (breaking): slash-command surface trimmed to transport-only, GitHub release published, vault tidied, skill description routes composition, user's statusline fixed properly.

- [x] **2.0.0 trim:** removed `/music:search`, `/music:add`, `/music:similar`, `/music:playlist` (14 → 10 commands). Rationale: slash = instant transport with osascript fallback (the zero-setup tier — lane boundary turned out to equal the auth boundary); composition = skill/TUI/CLI. CLI untouched (24 subcommands, ResultCache chaining intact). Major bump for public-surface removal. Suite 112 green, CLI rebuilt. Commit `d6f9fca`.
- [x] **Docs/skill:** SKILL.md description now states it's the composition layer + adds the trigger phrases the removed commands caught ("search for…", "add that track to my library", "make a playlist from those results"); README lane note + Kid A multi-room example. Commit `1c0005b` (folded into 2.0.0 before tagging — no extra bump).
- [x] **GitHub release v2.0.0** published, verified Latest, clean body (`--notes-file`, no heredoc gotcha). Notes lead with the breaking change + migration table, roll up untagged 1.17.0.
- [x] **Vault tidy (kivna save):** Status.md rewritten into Where-We-Are/What's-Open/What's-Next shape (release stack compressed to playbook pointer); MOC Quick Commands → transport + CLI composition table, **fixed stale install identifiers** (`music@anthonymaley-music` → `music@apple-music-marketplace`, repo `anthonymaley/music` → `anthonymaley/apple-music`); Weekly.md created (week of 2026-06-08).
- [x] **User statusline (user machine, not repo):** my prior advice was wrong — settings.json pointed at a personal ctx-free wrapper, not the plugin cache. Wrapper now composes now-playing (via repo path `~/apple-music/scripts/statusline.sh`, immune to version churn) + ctx-free. Verified live. Shame point persisted: `read-the-state-before-prescribing`.

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
- **Decisions locked this session (2026-06-11):** slash commands are transport-only — the lane split (slash = instant transport, skill = composition, TUI = interactive) is now the documented product shape; removing public commands = major bump. Statusline for the plugin author points at the repo copy, not the versioned cache path.
- **Earlier decisions (still hold):** quick pickers (bare `music speaker`/`volume`/`similar`/`suggest`) are blessed one-shots; playlist adds are playlist-only (no library side effect); fast-publish consumers must tolerate stale secondary fields.
- Worked directly on `main` (project convention). `docs/playlist-browser-ui.md` intentionally untracked.

## Playback Semantics

- Confirm playlist-origin playback continues naturally at track end after queue adoption from native context (1.14.1 path) over longer listening.
- Keep `z` as shuffle-only in the TUI unless repeat gets its own explicit key.
- Do not auto-reset AirPlay outputs during normal playback. Use `music speaker wake` for explicit ghost-speaker recovery.

## Docs

- Keep README, `skills/music/SKILL.md`, and `docs/guide.md` aligned whenever TUI keys or AirPlay behavior changes.
- Treat `docs/superpowers/*` as historical design/planning notes unless a new implementation round explicitly updates them.
