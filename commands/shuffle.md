---
name: shuffle
description: "Toggle shuffle on/off"
disable-model-invocation: true
---

!`osascript -e 'tell application "Music"
    if shuffle enabled then
        set shuffle enabled to false
        return "🔀 Shuffle off"
    else
        set shuffle enabled to true
        return "🔀 Shuffle on"
    end if
end tell' 2>/dev/null`
