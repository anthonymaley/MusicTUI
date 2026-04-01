---
name: vol
description: "Set volume. /music:vol 60, /music:vol up, /music:vol down, /music:vol kitchen 80"
arguments:
  - name: level
    description: "0-100, 'up' (+10), 'down' (-10), or '<speaker> <0-100>'"
    required: true
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
V="$ARGUMENTS"

if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI vol $V
else
    LOWER=$(echo "$V" | tr "[:upper:]" "[:lower:]")
    LAST_WORD="${V##* }"
    if echo "$LAST_WORD" | grep -qE '^[0-9]+$' && [ "$LAST_WORD" != "$V" ]; then
        SPEAKER="${V% *}"
        VOL="$LAST_WORD"
        osascript -e "tell application \"Music\"
            set targetVol to $VOL
            set deviceList to every AirPlay device
            set matchName to \"\"
            repeat with d in deviceList
                set dName to name of d
                set lowerDName to do shell script \"echo \" & quoted form of dName & \" | tr '[:upper:]' '[:lower:]'\"
                set lowerTarget to do shell script \"echo \" & quoted form of \"$SPEAKER\" & \" | tr '[:upper:]' '[:lower:]'\"
                if lowerDName contains lowerTarget then
                    set sound volume of d to targetVol
                    set matchName to dName
                end if
            end repeat
            if matchName is \"\" then
                return \"No speaker matching '$SPEAKER'\"
            else
                return matchName & \" [\" & targetVol & \"]\"
            end if
        end tell" 2>/dev/null
    else
        case "$LOWER" in
        up)
            osascript -e "tell application \"Music\"
                set deviceList to every AirPlay device
                set output to \"\"
                repeat with d in deviceList
                    if selected of d then
                        set newVol to (sound volume of d) + 10
                        if newVol > 100 then set newVol to 100
                        set sound volume of d to newVol
                        if output is not \"\" then set output to output & \", \"
                        set output to output & name of d & \" [\" & newVol & \"]\"
                    end if
                end repeat
                return output
            end tell" 2>/dev/null
            ;;
        down)
            osascript -e "tell application \"Music\"
                set deviceList to every AirPlay device
                set output to \"\"
                repeat with d in deviceList
                    if selected of d then
                        set newVol to (sound volume of d) - 10
                        if newVol < 0 then set newVol to 0
                        set sound volume of d to newVol
                        if output is not \"\" then set output to output & \", \"
                        set output to output & name of d & \" [\" & newVol & \"]\"
                    end if
                end repeat
                return output
            end tell" 2>/dev/null
            ;;
        *)
            osascript -e "tell application \"Music\"
                set targetVol to ($V as integer)
                set deviceList to every AirPlay device
                set output to \"\"
                repeat with d in deviceList
                    if selected of d then
                        set sound volume of d to targetVol
                        if output is not \"\" then set output to output & \", \"
                        set output to output & name of d
                    end if
                end repeat
                return targetVol & \" — \" & output
            end tell" 2>/dev/null
            ;;
        esac
    fi
fi`
