---
name: pause
description: Pause Apple Music playback
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI pause
else
    osascript -e 'tell application "Music"
        pause
        return "⏸ Paused — " & name of current track & " — " & artist of current track
    end tell' 2>/dev/null || echo "Could not pause"
fi`
