# Apple Music

Claude Code plugin for controlling Apple Music, AirPlay speakers, and AirPods on macOS.

## Commit Rules

- Always push after committing.

## Version Strategy

Use semver in all three locations (keep in sync):
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`

## Project Structure

```
skills/apple-music/SKILL.md   # the skill definition
.claude-plugin/                # plugin.json and marketplace.json
```
