---
name: speaker
description: "Switch or manage AirPlay speakers. /music:speaker kitchen, /music:speaker only kitchen, /music:speaker add bedroom, /music:speaker remove kitchen, /music:speaker stop kitchen, /music:speaker remove kitchen add bedroom, /music:speaker list"
arguments:
  - name: action
    description: "Speaker name, 'add <name>', 'remove <name>', 'stop <name>', 'only <name>', 'airpods', 'list'. Chain actions: 'remove kitchen add bedroom'"
    required: false
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
INPUT="$ARGUMENTS"
if [ -z "$INPUT" ]; then INPUT="list"; fi

LOWER_INPUT=$(echo "$INPUT" | tr "[:upper:]" "[:lower:]")

# --- AppleScript fallback functions (no CLI needed) ---
as_list() {
    osascript -e 'tell application "Music"
        set output to ""
        set deviceList to every AirPlay device
        repeat with d in deviceList
            set sel to selected of d
            set v to sound volume of d
            if sel then
                set output to output & "▶ " & name of d & " [" & v & "]" & linefeed
            else
                set output to output & "  " & name of d & " [" & v & "]" & linefeed
            end if
        end repeat
        return output
    end tell' 2>/dev/null
}

as_find_match() {
    local target_lower="$1"
    osascript -e "tell application \"Music\"
        set deviceList to every AirPlay device
        repeat with d in deviceList
            set dName to name of d
            set lowerDName to do shell script \"echo \" & quoted form of dName & \" | tr '[:upper:]' '[:lower:]'\"
            if lowerDName contains \"$target_lower\" then
                return dName
            end if
        end repeat
        return \"\"
    end tell" 2>/dev/null
}

as_set() {
    local target="$1"
    osascript -e "tell application \"Music\"
        set deviceList to every AirPlay device
        repeat with d in deviceList
            set selected of d to false
        end repeat
    end tell" 2>/dev/null
    osascript -e "tell application \"Music\"
        set deviceList to every AirPlay device
        repeat with d in deviceList
            if name of d is \"$target\" then
                set selected of d to true
            end if
        end repeat
        return \"Switched to $target.\"
    end tell" 2>/dev/null
}

as_add() {
    local target="$1"
    osascript -e "tell application \"Music\"
        set deviceList to every AirPlay device
        repeat with d in deviceList
            if name of d is \"$target\" then
                set selected of d to true
                return \"Added $target.\"
            end if
        end repeat
        return \"No device matching: $target\"
    end tell" 2>/dev/null
}

as_remove() {
    local target="$1"
    osascript -e "tell application \"Music\"
        set deviceList to every AirPlay device
        repeat with d in deviceList
            if name of d is \"$target\" then
                set selected of d to false
                return \"Removed $target.\"
            end if
        end repeat
        return \"No device matching: $target\"
    end tell" 2>/dev/null
}

# --- Use music CLI if available, otherwise AppleScript ---
HAS_CLI=false
if command -v "$MUSIC_CLI" &>/dev/null; then HAS_CLI=true; fi

# Handle list
if [ "$LOWER_INPUT" = "list" ]; then
    if $HAS_CLI; then $MUSIC_CLI speaker list; else as_list; fi
    exit 0
fi

# Handle airpods
if [ "$LOWER_INPUT" = "airpods" ]; then
    if $HAS_CLI; then
        MATCH=$($MUSIC_CLI speaker list --json 2>/dev/null | grep -oi '"name":"[^"]*airpods[^"]*"' | head -1 | cut -d'"' -f4)
    else
        MATCH=$(as_find_match "airpods")
    fi
    if [ -n "$MATCH" ]; then
        if $HAS_CLI; then $MUSIC_CLI speaker set "$MATCH"; else as_set "$MATCH"; fi
    else
        echo "No AirPods found — check Bluetooth"
    fi
    exit 0
fi

# Match a speaker name from the live device list
find_match() {
    local target_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    if $HAS_CLI; then
        $MUSIC_CLI speaker list --json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | while IFS= read -r dev; do
            dev_lower=$(echo "$dev" | tr '[:upper:]' '[:lower:]')
            if echo "$dev_lower" | grep -qi "$target_lower"; then
                echo "$dev"
                return
            fi
        done
    else
        as_find_match "$target_lower"
    fi
}

do_set() { if $HAS_CLI; then $MUSIC_CLI speaker set "$1"; else as_set "$1"; fi; }
do_add() { if $HAS_CLI; then $MUSIC_CLI speaker add "$1"; else as_add "$1"; fi; }
do_remove() { if $HAS_CLI; then $MUSIC_CLI speaker remove "$1"; else as_remove "$1"; fi; }

# Parse chained actions: "remove kitchen add julie office" → separate commands
ACTIONS=""
CURRENT_ACTION=""
for word in $INPUT; do
    w_lower=$(echo "$word" | tr "[:upper:]" "[:lower:]")
    case "$w_lower" in
        add|remove|only|stop)
            if [ -n "$CURRENT_ACTION" ]; then
                ACTIONS="${ACTIONS}${ACTIONS:+|}${CURRENT_ACTION}"
            fi
            CURRENT_ACTION="$w_lower"
            ;;
        *)
            CURRENT_ACTION="${CURRENT_ACTION}${CURRENT_ACTION:+ }${word}"
            ;;
    esac
done
if [ -n "$CURRENT_ACTION" ]; then
    ACTIONS="${ACTIONS}${ACTIONS:+|}${CURRENT_ACTION}"
fi

IFS='|' read -ra ACTION_LIST <<< "$ACTIONS"
for action_entry in "${ACTION_LIST[@]}"; do
    ACTION_WORD=$(echo "$action_entry" | awk '{print $1}' | tr "[:upper:]" "[:lower:]")
    SPEAKER_NAME=$(echo "$action_entry" | sed 's/^[^ ]* *//')
    case "$ACTION_WORD" in
        add)
            MATCH=$(find_match "$SPEAKER_NAME")
            if [ -n "$MATCH" ]; then do_add "$MATCH"; else echo "No device matching: $SPEAKER_NAME"; fi
            ;;
        remove|stop)
            MATCH=$(find_match "$SPEAKER_NAME")
            if [ -n "$MATCH" ]; then do_remove "$MATCH"; else echo "No device matching: $SPEAKER_NAME"; fi
            ;;
        only)
            MATCH=$(find_match "$SPEAKER_NAME")
            if [ -n "$MATCH" ]; then do_set "$MATCH"; else echo "No device matching: $SPEAKER_NAME"; fi
            ;;
        *)
            MATCH=$(find_match "$action_entry")
            if [ -n "$MATCH" ]; then do_set "$MATCH"; else echo "No device matching: $action_entry"; fi
            ;;
    esac
done

# Show active speakers
if $HAS_CLI; then
    $MUSIC_CLI speaker list 2>/dev/null | grep "▶"
else
    as_list | grep "▶"
fi`
