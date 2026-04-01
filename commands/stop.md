---
name: stop
description: "Stop playback, or remove a speaker from the group. /music:stop, /music:stop kitchen"
arguments:
  - name: speaker
    description: "Optional speaker name to remove from the group. Empty stops all playback."
    required: false
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
ARGS="$ARGUMENTS"

if [ -z "$ARGS" ]; then
    if command -v "$MUSIC_CLI" &>/dev/null; then
        $MUSIC_CLI stop
    else
        osascript -e 'tell application "Music" to stop' 2>/dev/null && echo "■ Stopped" || echo "Could not stop"
    fi
    exit 0
fi

if ! command -v "$MUSIC_CLI" &>/dev/null; then
    echo "Per-speaker stop requires the music CLI. Run: scripts/install.sh"
    exit 1
fi

MATCH=$($MUSIC_CLI speaker list --json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | while IFS= read -r dev; do
    dev_lower=$(echo "$dev" | tr '[:upper:]' '[:lower:]')
    args_lower=$(echo "$ARGS" | tr '[:upper:]' '[:lower:]')
    if echo "$dev_lower" | grep -qi "$args_lower"; then
        echo "$dev"
        break
    fi
done)

if [ -n "$MATCH" ]; then
    $MUSIC_CLI speaker remove "$MATCH"
else
    echo "No speaker matching '$ARGS'. Use /music:speaker list to see devices."
fi`
