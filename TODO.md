# TODO

## Current Session

- [x] Renamed `ceol` → `music` everywhere (CLI binary, tool dir, skill, commands, scripts, config paths, docs, vault)
- [x] Updated statusline.sh to use `music now --json` with AppleScript fallback
- [x] Added per-speaker stop: `/music:stop kitchen`, `/music:speaker stop kitchen`, `music speaker stop <name>`
- [x] Rewrote README with clear `/music:` prefix, full command tables, accurate architecture
- [x] Created `docs/guide.md` — complete plugin guide (naming, architecture, all commands, auth, gotchas)
- [x] Created `docs/naming.md` — naming decision record (one name: `music` for everything public)
- [x] Updated vault files (`~/eolas/vault/apple-music/`) to v1.0.0 with music naming
- [x] Cleaned up repo: removed `docs/superpowers/`, fixed AGENTS.md, gitignored .DS_Store
- [x] Updated memory: `ceol` naming feedback → `music` naming feedback
- [x] Old `ceol` symlink removed, `music` binary installed at `~/.local/bin/music`

## What's Next

- Publish v1.0.0 to Claude Code marketplace
- End-to-end testing of all slash commands (especially /music:search, /music:add, /music:similar, /music:playlist)

## Key Context

- CLI binary is `music`, installed at `~/.local/bin/music`
- Config lives at `~/.config/music/` (config.json, AuthKey.p8, user-token)
- Auth page served via Python HTTP server on localhost:8537 (MusicKit JS rejects file:// origins)
- User has Apple Developer account: Team ID `8NS66RKB45`, Key ID `W5H3NYJ999`
- All slash commands have osascript fallback if music binary not installed
- Skill frontmatter name is `music`
- Version is 1.1.0 everywhere (plugin.json, marketplace.json x2, music CLI)
- Naming decision: one public name `music` — display name `Apple Music for Claude Code`
- `ceol` is retired as a public name; only appears in historical session logs and naming doc

## Backlog

- (none)
