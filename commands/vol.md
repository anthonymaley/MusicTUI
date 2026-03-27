---
name: vol
description: "Set volume on active speakers. /music:vol 60, /music:vol up, /music:vol down"
arguments:
  - name: level
    description: "0-100, 'up' (+10), or 'down' (-10)"
    required: true
disable-model-invocation: true
---

!`V="$ARGUMENTS"
LOWER=$(echo "$V" | tr "[:upper:]" "[:lower:]")
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
        return \"🔊 \" & output
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
        return \"🔊 \" & output
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
        return \"🔊 \" & targetVol & \" — \" & output
    end tell" 2>/dev/null
    ;;
esac`
