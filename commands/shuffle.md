---
name: shuffle
description: "Toggle shuffle on/off"
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    CURRENT=$(osascript -e 'tell application "Music" to get shuffle enabled' 2>/dev/null)
    if [ "$CURRENT" = "true" ]; then
        $MUSIC_CLI shuffle off
    else
        $MUSIC_CLI shuffle on
    fi
else
    osascript -e 'tell application "Music"
        if shuffle enabled then
            set shuffle enabled to false
            return "Shuffle off"
        else
            set shuffle enabled to true
            return "Shuffle on"
        end if
    end tell' 2>/dev/null
fi`
