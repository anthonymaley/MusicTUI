---
name: playlist
description: "Manage playlists. /music:playlist list, /music:playlist tracks Working Vibes, /music:playlist create Friday Mix"
arguments:
  - name: action
    description: "list, tracks <name>, create <name>, delete <name>, add <playlist> <title> <artist>"
    required: true
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
ACTION=$(echo "$ARGUMENTS" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')

if ! command -v "$MUSIC_CLI" &>/dev/null; then
    # list and tracks can fall back to AppleScript
    case "$ACTION" in
        list)
            osascript -e 'tell application "Music"
                set output to ""
                repeat with p in (every user playlist)
                    set output to output & name of p & linefeed
                end repeat
                return output
            end tell' 2>/dev/null || echo "Could not list playlists"
            exit 0
            ;;
        tracks)
            PNAME=$(echo "$ARGUMENTS" | sed 's/^tracks *//')
            osascript -e "tell application \"Music\"
                set output to \"\"
                set i to 1
                repeat with t in (every track of playlist \"$PNAME\")
                    set output to output & i & \". \" & name of t & \" — \" & artist of t & linefeed
                    set i to i + 1
                end repeat
                return output
            end tell" 2>/dev/null || echo "Playlist '$PNAME' not found"
            exit 0
            ;;
        *)
            echo "⚠ Playlist $ACTION is an advanced feature that requires setup:"
            echo ""
            echo "  1. Build the music CLI:  scripts/install.sh"
            echo "  2. Configure auth:       music auth setup"
            echo "  3. Get user token:       music auth"
            echo ""
            echo "  Note: /music:playlist list and /music:playlist tracks work without setup."
            echo ""
            echo "See: https://github.com/anthonymaley/music#music-cli-optional--unlocks-catalog-features"
            exit 1
            ;;
    esac
fi
$MUSIC_CLI playlist $ARGUMENTS`
