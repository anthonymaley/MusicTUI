---
name: search
description: "Search the Apple Music catalog. /music:search Bohemian Rhapsody"
arguments:
  - name: query
    description: "Song, artist, or album to search for"
    required: true
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI search $ARGUMENTS
else
    echo "Catalog search requires the music CLI. Run: scripts/install.sh"
fi`
