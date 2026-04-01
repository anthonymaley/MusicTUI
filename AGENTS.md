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
skills/music/SKILL.md          # conversational skill (complex requests)
commands/                      # slash commands (quick controls)
scripts/statusline.sh          # status line script (now playing)
scripts/install.sh             # build + install music CLI
tools/music/                    # Swift CLI binary (Apple Music REST API + AppleScript)
.claude-plugin/                # plugin.json and marketplace.json
```
