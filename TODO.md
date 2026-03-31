# TODO

## Current Session

- [x] Built ceol CLI — unified Swift binary (18 subcommands, 1,818 lines)
- [x] Phase 1: Swift package scaffold, AppleScript backend, playback/speaker/volume commands
- [x] Phase 2: JWT generator, auth manager, browser-based user token flow (localhost HTTP server)
- [x] Phase 3: REST API backend, catalog search, add-to-library, playlist CRUD
- [x] Phase 4: Discovery commands (similar, suggest, new-releases, mix)
- [x] Phase 5: Install script, slash commands updated to use ceol, skill rewritten
- [x] Fixed MusicKit JS auth — file:// origin rejected, switched to localhost HTTP server
- [x] User token obtained and verified — full auth working
- [x] Removed old `tools/music-catalog/` prototype
- [x] All 13 tasks from the implementation plan complete

## What's Next

- **Version bump** to v1.0.0 in plugin.json and marketplace.json (ceol is 1.0.0, plugin still at 0.2.1)
- **Add `ceol` to .gitignore** — `tools/ceol/.build/` and `Package.resolved` are untracked
- Consider adding new slash commands for ceol-only features: `/music:search`, `/music:add`, `/music:similar`
- Consider updating `scripts/statusline.sh` to use `ceol now --json` instead of raw osascript
- Migrate existing config from `~/.music-catalog-key.p8` to `~/.config/ceol/` (already done manually this session)
- Consider per-speaker stop support (backlog item from earlier sessions)

## Key Context

- CLI binary name is `ceol` (Irish for music), installed at `~/.local/bin/ceol`
- Config lives at `~/.config/ceol/` (config.json, AuthKey.p8, user-token)
- Auth page served via Python HTTP server on localhost:8537 (MusicKit JS rejects file:// origins)
- User has Apple Developer account: Team ID `8NS66RKB45`, Key ID `W5H3NYJ999`
- All slash commands have osascript fallback if ceol binary not installed
- Skill renamed from "music" to "ceol" in frontmatter

## Backlog

- Consider enhancing `/music:stop` to support per-speaker stop
- Consider adding per-speaker stop to the CLI (`ceol speaker stop kitchen`)
