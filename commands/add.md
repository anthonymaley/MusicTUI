---
name: add
description: "Add a track to your Apple Music library. /music:add Get It Done Fouk"
arguments:
  - name: query
    description: "Song title and/or artist to search and add"
    required: true
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI add $ARGUMENTS
else
    echo "Adding to library requires the music CLI. Run: scripts/install.sh"
fi`
