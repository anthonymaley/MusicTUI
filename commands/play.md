---
name: play
description: "Resume or play a playlist/artist/album/song, optionally on a speaker at a volume. /music:play [query] [speaker] [volume%]"
arguments:
  - name: query
    description: "Playlist name, artist, album, or song. Optionally add a speaker name and volume%. Empty to resume."
    required: false
disable-model-invocation: true
---

!`ARGS="$ARGUMENTS"

if [ -z "$ARGS" ]; then
    osascript -e 'tell application "Music"
        play
        return "▶ " & name of current track & " — " & artist of current track
    end tell' 2>/dev/null || echo "Could not start playback"
else
    # --- Extract volume (e.g. "60%") ---
    VOL=""
    if echo "$ARGS" | grep -qoE '[0-9]+%'; then
        VOL=$(echo "$ARGS" | grep -oE '[0-9]+%' | tail -1 | tr -d '%')
        ARGS=$(echo "$ARGS" | sed -E "s/ *[0-9]+%//")
    fi

    # --- Match a speaker name from live AirPlay device list ---
    SPEAKER=""
    DEVICES=$(osascript -e 'tell application "Music" to get name of every AirPlay device' 2>/dev/null)
    IFS=',' read -ra DEV_ARRAY <<< "$DEVICES"
    ARGS_LOWER=$(echo "$ARGS" | tr '[:upper:]' '[:lower:]')
    for dev in "${DEV_ARRAY[@]}"; do
        dev_trimmed=$(echo "$dev" | sed 's/^ *//;s/ *$//')
        dev_lower=$(echo "$dev_trimmed" | tr '[:upper:]' '[:lower:]')
        if echo " $ARGS_LOWER " | grep -qi " $dev_lower "; then
            SPEAKER="$dev_trimmed"
            break
        fi
    done
    # Remove speaker name from args to get the query
    if [ -n "$SPEAKER" ]; then
        SP_LOWER=$(echo "$SPEAKER" | tr '[:upper:]' '[:lower:]')
        CLEANED=""
        for word in $ARGS; do
            word_lower=$(echo "$word" | tr '[:upper:]' '[:lower:]')
            if [ "$word_lower" != "$SP_LOWER" ]; then
                CLEANED="$CLEANED $word"
            fi
        done
        ARGS=$(echo "$CLEANED" | sed 's/^ *//;s/ *$//')
    fi

    Q="$ARGS"

    # --- Step 1: Route to speaker (separate call to avoid Parameter error -50) ---
    if [ -n "$SPEAKER" ]; then
        osascript -e "tell application \"Music\"
            set allDevices to every AirPlay device
            repeat with d in allDevices
                set selected of d to false
            end repeat
            set selected of AirPlay device \"$SPEAKER\" to true
        end tell" 2>/dev/null
    fi

    # --- Step 2: Set volume (separate call) ---
    if [ -n "$VOL" ] && [ -n "$SPEAKER" ]; then
        osascript -e "tell application \"Music\" to set sound volume of AirPlay device \"$SPEAKER\" to $VOL" 2>/dev/null
    elif [ -n "$VOL" ]; then
        osascript -e "tell application \"Music\" to set sound volume to $VOL" 2>/dev/null
    fi

    # --- Step 3: Play content (separate call) ---
    if [ -z "$Q" ]; then
        osascript -e 'tell application "Music"
            play
            return "▶ " & name of current track & " — " & artist of current track
        end tell' 2>/dev/null || echo "Could not start playback"
    else
        osascript -e "tell application \"Music\"
            set q to \"$Q\"
            set pNames to name of every playlist
            set matched to \"\"
            repeat with p in pNames
                if p contains q then
                    set matched to p as text
                    exit repeat
                end if
            end repeat
            if matched is not \"\" then
                set shuffle enabled to true
                play playlist matched
                return \"▶ \" & name of current track & \" — \" & artist of current track & \" (\" & matched & \")\"
            else
                set results to (every track of playlist \"Library\" whose name contains q or artist contains q or album contains q)
                if (count of results) > 0 then
                    play item 1 of results
                    return \"▶ \" & name of current track & \" — \" & artist of current track
                else
                    return \"Nothing found for: \" & q
                end if
            end if
        end tell" 2>/dev/null || echo "Could not start playback"
    fi
fi`
