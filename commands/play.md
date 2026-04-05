---
name: play
description: "Resume or play a playlist/artist/album/song, optionally on a speaker at a volume. /music:play [query] [speaker] [volume%]"
arguments:
  - name: query
    description: "Playlist name, artist, album, or song. Optionally add a speaker name and volume%. Empty to resume."
    required: false
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
ARGS="$ARGUMENTS"

if ! command -v "$MUSIC_CLI" &>/dev/null; then
    osascript -e 'tell application "Music"
        play
        return "▶ " & name of current track & " — " & artist of current track
    end tell' 2>/dev/null || echo "music CLI not installed. Run: scripts/install.sh"
    exit 0
fi

if [ -z "$ARGS" ]; then
    $MUSIC_CLI play
    exit 0
fi

# --- Extract volume (e.g. "60%") ---
VOL=""
if echo "$ARGS" | grep -qoE '[0-9]+%'; then
    VOL=$(echo "$ARGS" | grep -oE '[0-9]+%' | tail -1 | tr -d '%')
    ARGS=$(echo "$ARGS" | sed -E "s/ *[0-9]+%//")
fi

# --- Match a speaker name from live AirPlay device list (longest match wins) ---
SPEAKER=""
SPEAKER_LEN=0
ARGS_LOWER=$(echo "$ARGS" | tr '[:upper:]' '[:lower:]')
while IFS= read -r dev; do
    dev=$(echo "$dev" | sed 's/^ *//;s/ *$//')
    [ -z "$dev" ] && continue
    dev_lower=$(echo "$dev" | tr '[:upper:]' '[:lower:]')
    if echo " $ARGS_LOWER " | grep -qi " $dev_lower "; then
        dev_len=${#dev_lower}
        if [ "$dev_len" -gt "$SPEAKER_LEN" ]; then
            SPEAKER="$dev"
            SPEAKER_LEN=$dev_len
        fi
    fi
done < <($MUSIC_CLI speaker list --json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4)

if [ -n "$SPEAKER" ]; then
    SP_LOWER=$(echo "$SPEAKER" | tr '[:upper:]' '[:lower:]')
    ARGS=$(echo "$ARGS" | tr '[:upper:]' '[:lower:]' | sed "s/$SP_LOWER//" | sed 's/^ *//;s/ *$//')
fi

Q=$(echo "$ARGS" | sed 's/^ *//;s/ *$//')

# --- Step 1: Route to speaker (with wake cycle for AirPlay reliability) ---
if [ -n "$SPEAKER" ]; then
    $MUSIC_CLI speaker smart wake "$SPEAKER"
fi

# --- Step 2: Set volume ---
if [ -n "$VOL" ] && [ -n "$SPEAKER" ]; then
    $MUSIC_CLI volume "$SPEAKER" "$VOL"
elif [ -n "$VOL" ]; then
    $MUSIC_CLI volume "$VOL"
fi

# --- Step 3: Play content ---
if [ -z "$Q" ]; then
    $MUSIC_CLI play
else
    $MUSIC_CLI play --playlist "$Q" 2>/dev/null || $MUSIC_CLI play --song "$Q"
fi`
