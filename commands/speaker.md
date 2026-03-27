---
name: speaker
description: "Switch or manage AirPlay speakers. /music:speaker kitchen, /music:speaker airpods, /music:speaker add bedroom, /music:speaker remove kitchen, /music:speaker list"
arguments:
  - name: action
    description: "Speaker name, 'add <name>', 'remove <name>', 'airpods', or 'list'"
    required: false
disable-model-invocation: true
---

!`INPUT="$ARGUMENTS"
if [ -z "$INPUT" ]; then INPUT="list"; fi
FIRST="${INPUT%% *}"
LOWER=$(echo "$FIRST" | tr "[:upper:]" "[:lower:]")
REST="${INPUT#* }"
if [ "$FIRST" = "$INPUT" ]; then REST=""; fi
if [ "$LOWER" = "list" ]; then
    osascript -e 'tell application "Music"
        set deviceList to every AirPlay device
        set output to ""
        repeat with d in deviceList
            set marker to "  "
            if selected of d then set marker to "▶ "
            set output to output & marker & name of d & " [" & sound volume of d & "]" & linefeed
        end repeat
        return output
    end tell' 2>/dev/null
    exit 0
fi
DEVICES=$(osascript -e 'tell application "Music" to get name of every AirPlay device' 2>/dev/null)
find_match() { echo "$DEVICES" | tr "," "\n" | sed "s/^ *//" | grep -i "$1" | head -1; }
show_active() {
    osascript -e 'tell application "Music"
        set deviceList to every AirPlay device
        set output to ""
        repeat with d in deviceList
            if selected of d then
                if output is not "" then set output to output & ", "
                set output to output & name of d & " [" & sound volume of d & "]"
            end if
        end repeat
        return "🔊 " & output
    end tell' 2>/dev/null
}
case "$LOWER" in
add)
    MATCH=$(find_match "$REST")
    if [ -n "$MATCH" ]; then
        osascript -e "tell application \"Music\" to set selected of AirPlay device \"$MATCH\" to true" 2>/dev/null
        show_active
    else
        echo "No device matching: $REST"
    fi
    ;;
remove)
    MATCH=$(find_match "$REST")
    if [ -n "$MATCH" ]; then
        osascript -e "tell application \"Music\" to set selected of AirPlay device \"$MATCH\" to false" 2>/dev/null
        show_active
    else
        echo "No device matching: $REST"
    fi
    ;;
airpods)
    MATCH=$(find_match "airpods")
    if [ -n "$MATCH" ]; then
        osascript -e "tell application \"Music\"
            set allDevices to every AirPlay device
            repeat with d in allDevices
                set selected of d to false
            end repeat
            set selected of AirPlay device \"$MATCH\" to true
        end tell" 2>/dev/null
        echo "🎧 $MATCH"
    else
        echo "No AirPods found — check Bluetooth"
    fi
    ;;
*)
    MATCH=$(find_match "$INPUT")
    if [ -n "$MATCH" ]; then
        osascript -e "tell application \"Music\"
            set allDevices to every AirPlay device
            repeat with d in allDevices
                set selected of d to false
            end repeat
            set selected of AirPlay device \"$MATCH\" to true
        end tell" 2>/dev/null
        VOL=$(osascript -e "tell application \"Music\" to get sound volume of AirPlay device \"$MATCH\"" 2>/dev/null)
        echo "🔊 $MATCH [$VOL]"
    else
        echo "No device matching: $INPUT"
    fi
    ;;
esac`
