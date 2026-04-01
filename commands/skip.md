---
name: skip
description: Skip to next track in Apple Music
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI skip
else
    osascript -e 'tell application "Music"
        next track
        delay 0.5
        return "⏭ " & name of current track & " — " & artist of current track
    end tell' 2>/dev/null || echo "Could not skip"
fi`
