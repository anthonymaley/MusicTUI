---
name: playlist
description: "Manage playlists. /music:playlist list, /music:playlist tracks Working Vibes"
arguments:
  - name: action
    description: "list, tracks <name>, create <name>, delete <name>, add <playlist> <title> <artist>"
    required: true
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI playlist $ARGUMENTS
else
    echo "Playlist management requires the music CLI. Run: scripts/install.sh"
fi`
