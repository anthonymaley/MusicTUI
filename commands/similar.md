---
name: similar
description: "Find tracks similar to what's playing (requires music CLI + auth). /music:similar"
arguments:
  - name: query
    description: "Optional: title and artist. Empty uses current track."
    required: false
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if ! command -v "$MUSIC_CLI" &>/dev/null; then
    echo "⚠ Discovery is an advanced feature that requires setup:"
    echo ""
    echo "  1. Build the music CLI:  scripts/install.sh"
    echo "  2. Configure auth:       music auth setup"
    echo "  3. Get user token:       music auth"
    echo ""
    echo "See: https://github.com/anthonymaley/music#music-cli-optional--unlocks-catalog-features"
    exit 1
fi
$MUSIC_CLI similar $ARGUMENTS`
