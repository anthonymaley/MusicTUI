---
name: play
description: "Resume or play a playlist/artist/album/song. /music:play [query]"
arguments:
  - name: query
    description: "Playlist name, artist, album, or song. Empty to resume."
    required: false
disable-model-invocation: true
---

!`Q="$ARGUMENTS"
if [ -z "$Q" ]; then
    osascript -e 'tell application "Music"
        play
        return "▶ " & name of current track & " — " & artist of current track
    end tell' 2>/dev/null
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
    end tell" 2>/dev/null
fi`
