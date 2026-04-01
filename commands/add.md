---
name: add
description: "Add a track to your Apple Music library (requires music CLI + auth). /music:add Get It Done Fouk"
arguments:
  - name: query
    description: "Song title and/or artist to search and add"
    required: true
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if ! command -v "$MUSIC_CLI" &>/dev/null; then
    echo "⚠ Adding to library is an advanced feature that requires setup:"
    echo ""
    echo "  1. Build the music CLI:  scripts/install.sh"
    echo "  2. Configure auth:       music auth setup"
    echo "  3. Get user token:       music auth"
    echo ""
    echo "See: https://github.com/anthonymaley/music#music-cli-optional--unlocks-catalog-features"
    exit 1
fi
$MUSIC_CLI add $ARGUMENTS`
