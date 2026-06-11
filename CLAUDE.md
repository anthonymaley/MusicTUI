# Apple Music

Claude Code plugin for controlling Apple Music, AirPlay speakers, and AirPods on macOS.

## Commit Rules

- Always push after committing.

## Version Strategy

Use semver in all four locations (keep in sync):
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`
- `tools/music/Sources/Music.swift` → `CommandConfiguration(version:)` (the CLI's own `--version`; rebuild via `scripts/install.sh` after changing)

## Project Structure

```
skills/music/SKILL.md          # the /music skill — single plugin entry point
scripts/statusline.sh          # status line script (now playing)
.claude-plugin/                # plugin.json and marketplace.json
tools/music/                   # Swift CLI source
```

There are no slash commands (removed in 3.0.0) — transport is the Mac's media keys; everything else goes through the skill, TUI, or CLI.
