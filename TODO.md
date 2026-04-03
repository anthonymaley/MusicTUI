# TODO

## Current Session

- [x] Updated plugin.json and marketplace.json descriptions for CLI + Claude Code positioning
- [x] Synced guide.md with README restructure (skill workflow, speaker command examples)
- [x] Published v1.2.0 to marketplace (git-based, push = publish)
- [x] Added auth requirement banners (open + close) in README
- [x] Added Setup column to summary table
- [x] Fixed TUI section — "real terminal" not "!music from Claude Code"
- [x] Fixed `music similar` — was showing playlists instead of songs (swapped to artist search)
- [x] Fixed URL encoding — `&` `+` `=` in search queries now properly escaped
- [x] Built interactive now-playing TUI with chafa album art, 3-zone layout, progress bar with seek indicator
- [x] Built `music radio` command — creates artist playlist from catalog search
- [x] Fixed key reader — byte-at-a-time parsing, proper VMIN/VTIME via UnsafeMutableRawPointer
- [x] Redesigned all 4 TUI screens with shared design system (TUILayout.swift: ScreenFrame, renderShell, truncText, meterBar)
- [x] Built 2-screen playlist browser → now-playing flow with PlaybackContext handoff
- [x] Added speaker picker modal (s key) and volume mixer modal (v key) from now-playing
- [ ] **Update README, docs, descriptions, vault for all new features**

## What's Next

- Update README with new TUI screens, radio command, playlist browser flow, keyboard shortcuts
- Update SKILL.md with radio command, now-playing TUI reference
- Update guide.md with new architecture (2-screen flow, modal subflows)
- Update docs/guide.md file structure section
- Bump version to 1.3.0 across all three locations
- Update TODO.md backlog

## Key Context

- CLI binary is `music`, installed at `~/.local/bin/music`
- Config lives at `~/.config/music/` (config.json, AuthKey.p8, user-token)
- Version is 1.2.0 everywhere — needs bump to 1.3.0 for this session's features
- Naming: one public name `music`, display name `Apple Music for Claude Code & CLI`
- **New TUI design system**: TUILayout.swift provides ScreenFrame, renderShell, truncText, meterBar — all screens use shared coordinates
- **2-screen flow**: PlaylistBrowser ↔ NowPlaying with PlaybackContext. b/Esc returns to browser with state preserved
- **Modal subflows**: s = speaker picker, v = volume mixer — both exit/re-enter raw mode and return to NowPlaying
- **Chafa**: album art in now-playing TUI uses chafa with `--format symbols` (avoids iTerm2 inline image protocol). Gracefully falls back to CoreGraphics block art if chafa not installed
- **Key reader fix**: reads one byte at a time, parses escape sequences explicitly. VMIN/VTIME set via UnsafeMutableRawPointer (Swift tuple subscript workaround)
- **Radio**: builds a `__radio__TrackName` temp playlist from catalog search (25 tracks by same artist), shuffle plays it. System Events "Create Station" menu approach doesn't work on macOS 26
- **Playlist browser**: tracks capped at 50 per playlist to avoid AppleScript hanging on large libraries. Preview loads lazily (100ms idle timeout)
- **chafa in playlist browser disabled** — conflicts with raw mode. Album art only in NowPlaying

## Backlog

- Consider per-speaker stop via slash command (`/music:stop kitchen`)
- Consider `/music:list` command for listing playlists
- Playlist browser: load more than 50 tracks incrementally
- Playlist browser: add artwork back (needs chafa raw-mode fix)
- Playlist browser: add `/` search
- Now playing: add `n`/`p` as alternative skip keys (non-repeating)
- Volume mixer: highlight selected channel more strongly
