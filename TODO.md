# TODO

## Current Session

- [x] Fixed `music playlist` / `music speaker` crash (ArgumentParser property wrapper bug)
- [x] Extracted shared logic into standalone functions (no more direct ParsableCommand construction)
- [x] Redesigned all TUI components with bigger visual style (♫ header, box-drawn footer, ▸ pointer, ●/○ markers)
- [x] Added 's' shuffle action to similar/suggest TUI (creates temp playlist + shuffle play)
- [x] Made speaker TUI toggle immediately on space (instant AppleScript activation)
- [x] Added space-to-select in ListPicker (playlist browser)
- [x] Built release, installed to ~/.local/bin/music

## What's Next

- Publish v1.2.0 to marketplace (or bump to 1.2.1 first for the fixes)
- End-to-end testing of all interactive TUI modes in a real terminal
- Test Ctrl-C cleanup in each TUI view
- Update slash commands to use new positional shortcuts where applicable

## Key Context

- CLI binary is `music`, installed at `~/.local/bin/music`
- Config lives at `~/.config/music/` (config.json, AuthKey.p8, user-token)
- Result caches: `~/.config/music/last-songs.json`, `~/.config/music/last-speakers.json`
- Auth page served via Python HTTP server on localhost:8537
- User has Apple Developer account: Team ID `8NS66RKB45`, Key ID `W5H3NYJ999`
- All slash commands have osascript fallback if music binary not installed
- Skill frontmatter name is `music`
- Version is 1.2.0 everywhere (plugin.json, marketplace.json x2, music CLI)
- Naming decision: one public name `music`, display name `Apple Music for Claude Code`
- **Critical learning**: ArgumentParser property wrappers crash when accessed on directly-constructed structs. Always use standalone functions for shared logic.
- PlaylistBrowse now has commandName "browse", SpeakerSmart has commandName "smart" (were empty strings)

## Backlog

- Consider per-speaker stop via slash command (`/music:stop kitchen`)
- Consider `/music:list` command for listing playlists
