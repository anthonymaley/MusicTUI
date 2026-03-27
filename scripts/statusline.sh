#!/bin/bash
# Apple Music status line for Claude Code
# Shows: state, track, artist, active speakers, volume
#
# Setup: Add to ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "~/.claude/plugins/music/scripts/statusline.sh"
#   }

cat > /dev/null  # consume stdin (Claude Code session JSON)

osascript -e '
tell application "Music"
    set state to player state
    if state is stopped then return ""

    if state is playing then
        set icon to "▶ "
    else
        set icon to "⏸ "
    end if

    set t to name of current track & " — " & artist of current track

    set spk to ""
    set vol to ""
    set deviceList to every AirPlay device
    repeat with d in deviceList
        if selected of d then
            if spk is not "" then set spk to spk & ", "
            set spk to spk & name of d
            if vol is not "" then set vol to vol & ", "
            set vol to vol & (sound volume of d as text)
        end if
    end repeat

    if spk is "" then
        return icon & t
    else
        return icon & t & "  ·  " & spk & " [" & vol & "]"
    end if
end tell' 2>/dev/null
