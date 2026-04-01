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

if ! command -v "$MUSIC_CLI" &>/dev/null; then
    echo "music CLI not installed. Run: scripts/install.sh"
    exit 1
fi

# Handle list
if [ "$LOWER_INPUT" = "list" ]; then
    $MUSIC_CLI speaker list
    exit 0
fi

# Handle airpods
if [ "$LOWER_INPUT" = "airpods" ]; then
    MATCH=$($MUSIC_CLI speaker list --json 2>/dev/null | grep -oi '"name":"[^"]*airpods[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -n "$MATCH" ]; then
        $MUSIC_CLI speaker set "$MATCH"
    else
        echo "No AirPods found — check Bluetooth"
    fi
    exit 0
fi

# Match a speaker name from the live device list
find_match() {
    local target_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    $MUSIC_CLI speaker list --json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | while IFS= read -r dev; do
        dev_lower=$(echo "$dev" | tr '[:upper:]' '[:lower:]')
        if echo "$dev_lower" | grep -qi "$target_lower"; then
            echo "$dev"
            return
        fi
    done
}

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
            if [ -n "$MATCH" ]; then $MUSIC_CLI speaker add "$MATCH"; else echo "No device matching: $SPEAKER_NAME"; fi
            ;;
        remove|stop)
            MATCH=$(find_match "$SPEAKER_NAME")
            if [ -n "$MATCH" ]; then $MUSIC_CLI speaker remove "$MATCH"; else echo "No device matching: $SPEAKER_NAME"; fi
            ;;
        only)
            MATCH=$(find_match "$SPEAKER_NAME")
            if [ -n "$MATCH" ]; then $MUSIC_CLI speaker set "$MATCH"; else echo "No device matching: $SPEAKER_NAME"; fi
            ;;
        *)
            MATCH=$(find_match "$action_entry")
            if [ -n "$MATCH" ]; then $MUSIC_CLI speaker set "$MATCH"; else echo "No device matching: $action_entry"; fi
            ;;
    esac
done

$MUSIC_CLI speaker list 2>/dev/null | grep "▶"`
