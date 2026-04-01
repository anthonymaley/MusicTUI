---
name: similar
description: "Find tracks similar to what's playing. /music:similar"
arguments:
  - name: query
    description: "Optional: title and artist. Empty uses current track."
    required: false
disable-model-invocation: true
---

!`MUSIC_CLI="${MUSIC_CLI:-music}"
if command -v "$MUSIC_CLI" &>/dev/null; then
    $MUSIC_CLI similar $ARGUMENTS
else
    echo "Discovery requires the music CLI. Run: scripts/install.sh"
fi`
