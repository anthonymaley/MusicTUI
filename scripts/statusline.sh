#!/bin/bash
# Apple Music status line for Claude Code
# Shows: state, track, artist, active speakers, volume
#
# Uses music CLI (--json) when available, falls back to AppleScript.
#
# Setup: run scripts/install.sh (installs this to ~/.local/bin/music-statusline,
# a stable path that survives plugin updates), then add to ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "~/.local/bin/music-statusline"
#   }

cat > /dev/null  # consume stdin (Claude Code session JSON)

MUSIC_CLI="${MUSIC_CLI:-music}"

if command -v "$MUSIC_CLI" &>/dev/null; then
    JSON=$($MUSIC_CLI now --json 2>/dev/null) || exit 0
    if command -v jq &>/dev/null; then
        # jq survives escaped quotes in track titles; the grep fallback truncates there.
        STATE=$(echo "$JSON" | jq -r '.state // empty')
        [ "$STATE" = "stopped" ] && exit 0
        LIVE=$(echo "$JSON" | jq -r 'if .live then "1" else "" end')
        TRACK=$(echo "$JSON" | jq -r '.track // empty')
        ARTIST=$(echo "$JSON" | jq -r '.artist // empty')
        SPEAKERS=$(echo "$JSON" | jq -r '[.speakers[]?.name] | join(", ")')
        VOLUMES=$(echo "$JSON" | jq -r '[.speakers[]?.volume] | map(tostring) | join(", ")')
    else
        STATE=$(echo "$JSON" | grep -o '"state":"[^"]*"' | cut -d'"' -f4)
        [ "$STATE" = "stopped" ] && exit 0
        echo "$JSON" | grep -q '"live":true' && LIVE=1 || LIVE=""
        TRACK=$(echo "$JSON" | grep -o '"track":"[^"]*"' | cut -d'"' -f4)
        ARTIST=$(echo "$JSON" | grep -o '"artist":"[^"]*"' | cut -d'"' -f4)
        SPEAKERS=$(echo "$JSON" | grep -o '"speakers":\[[^]]*\]' | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | paste -sd, - | sed 's/,/, /g')
        VOLUMES=$(echo "$JSON" | grep -o '"speakers":\[[^]]*\]' | grep -o '"volume":[0-9]*' | cut -d: -f2 | paste -sd, - | sed 's/,/, /g')
    fi

    # No track name means nothing worth a status line: Bridge idle/loading (no
    # album, duration, position, or speakers either) reports a state with no
    # track, and an icon with a blank label is worse than nothing.
    [ -z "$TRACK" ] && exit 0

    [ "$STATE" = "playing" ] && ICON="▶" || ICON="⏸"
    [ -n "$LIVE" ] && ICON="$ICON ◉"

    # BBC Radio 1 reports an empty artist; Apple's live stations report the song.
    if [ -n "$ARTIST" ]; then
        LABEL="$TRACK — $ARTIST"
    else
        LABEL="$TRACK"
    fi

    if [ -n "$SPEAKERS" ]; then
        echo "$ICON $LABEL  ·  $SPEAKERS [$VOLUMES]"
    else
        echo "$ICON $LABEL"
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
