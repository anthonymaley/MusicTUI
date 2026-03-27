---
name: play
description: "Resume playback or play a playlist/artist/album. Usage: /music:play [query]"
arguments:
  - name: query
    description: "Playlist name, artist, album, or song to play. Leave empty to resume."
    required: false
---

Play music for the user. If no query is provided, resume playback. If a query is provided, search for it and play it.

$ARGUMENTS
