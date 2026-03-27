# TODO

## Current Session

- [x] Enhanced status line: now shows track, speakers, and per-speaker volume
- [x] Converted all commands to `disable-model-invocation: true` — no AI, no Bash tool calls in chat
- [x] New commands: `/music:play [query]`, `/music:vol`, `/music:shuffle`
- [x] Rewrote `/music:speaker` as inline bash with fuzzy device matching
- [x] Updated README with new commands and status line docs
- [ ] **Not yet tested**: the new `disable-model-invocation` commands need testing after `/reload-plugins` — especially `$ARGUMENTS` template variable behavior in inline bash

## What's Next

- Test all new commands after reload: `/music:play Working Vibes`, `/music:vol 60`, `/music:shuffle`, `/music:speaker kitchen`
- If `$ARGUMENTS` doesn't work in `disable-model-invocation` commands, fall back to AI-driven with `allowed-tools: Bash` and a single-call prompt
- Bump version to v0.3.0 once commands are verified
- Consider adding `/music:list` command to list playlists without AI

## Backlog
