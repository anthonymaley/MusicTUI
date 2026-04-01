---
name: search
description: "Search the Apple Music catalog (requires music CLI + auth). /music:search Bohemian Rhapsody"
arguments:
  - name: query
    description: "Song, artist, or album to search for"
    required: true
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if ! command -v "$MUSIC_CLI" &>/dev/null; then
    echo "⚠ Catalog search is an advanced feature that requires setup:"
    echo ""
    echo "  1. Build the music CLI:  scripts/install.sh"
    echo "  2. Configure auth:       music auth setup"
    echo ""
    echo "See: https://github.com/anthonymaley/music#music-cli-optional--unlocks-catalog-features"
    exit 1
fi
$MUSIC_CLI search $ARGUMENTS`
