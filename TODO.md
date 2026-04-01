# TODO

## Current Session

- [x] Built music CLI — unified Swift binary (18 subcommands, 1,818 lines)
- [x] All 13 tasks from the implementation plan complete (Phases 1-5)
- [x] Fixed MusicKit JS auth — file:// origin rejected, switched to localhost HTTP server
- [x] User token obtained and verified — full auth working
- [x] Version bumped to 1.0.0 across plugin.json and marketplace.json
- [x] Added .gitignore for build artifacts
- [x] Added new slash commands: /music:search, /music:add, /music:similar, /music:playlist
- [x] README rewritten with music CLI docs, architecture diagram, catalog features
- [x] Playbook updated with full architecture, auth tiers, config locations
- [x] Removed old `tools/music-catalog/` prototype

## What's Next

- Consider updating `scripts/statusline.sh` to use `music now --json` instead of raw osascript
- Consider per-speaker stop support (`music speaker stop kitchen`)
- Publish v1.0.0 to Claude Code marketplace
- Test all new slash commands end-to-end (/music:search, /music:add, /music:similar, /music:playlist)

## Key Context

- CLI binary name is `music` (Irish for music), installed at `~/.local/bin/music`
- Config lives at `~/.config/music/` (config.json, AuthKey.p8, user-token)
- Auth page served via Python HTTP server on localhost:8537 (MusicKit JS rejects file:// origins)
- User has Apple Developer account: Team ID `8NS66RKB45`, Key ID `W5H3NYJ999`
- All slash commands have osascript fallback if music binary not installed
- Skill frontmatter name is `music`
- Version is 1.0.0 everywhere (plugin.json, marketplace.json x2, music CLI)

## Backlog

- Consider enhancing `/music:stop` to support per-speaker stop
- Consider adding per-speaker stop to the CLI (`music speaker stop kitchen`)
