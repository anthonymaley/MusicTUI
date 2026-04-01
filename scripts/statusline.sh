#!/bin/bash
# Apple Music status line for Claude Code
# Shows: state, track, artist, active speakers, volume
#
# Uses music CLI (--json) when available, falls back to AppleScript.
#
# Setup: Add to ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "~/.claude/plugins/music/scripts/statusline.sh"
#   }

cat > /dev/null  # consume stdin (Claude Code session JSON)

MUSIC_CLI="${MUSIC_CLI:-music}"

if command -v "$MUSIC_CLI" &>/dev/null; then
    JSON=$($MUSIC_CLI now --json 2>/dev/null) || exit 0
    STATE=$(echo "$JSON" | grep -o '"state":"[^"]*"' | cut -d'"' -f4)
    [ "$STATE" = "stopped" ] && exit 0

    TRACK=$(echo "$JSON" | grep -o '"track":"[^"]*"' | cut -d'"' -f4)
    ARTIST=$(echo "$JSON" | grep -o '"artist":"[^"]*"' | cut -d'"' -f4)
    SPEAKERS=$(echo "$JSON" | grep -o '"speakers":\[[^]]*\]' | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | paste -sd', ' -)
    VOLUMES=$(echo "$JSON" | grep -o '"speakers":\[[^]]*\]' | grep -o '"volume":[0-9]*' | cut -d: -f2 | paste -sd', ' -)

    [ "$STATE" = "playing" ] && ICON="▶" || ICON="⏸"

    if [ -n "$SPEAKERS" ]; then
        echo "$ICON $TRACK — $ARTIST  ·  $SPEAKERS [$VOLUMES]"
    else
        echo "$ICON $TRACK — $ARTIST"
    fi
else
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
fi
