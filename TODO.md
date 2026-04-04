# TODO

## Current Session

- [x] All v1.3.0 docs, release, and promotion done (previous session)
- [x] Ran slainte health audit across all areas (docs, code, deps, playbook)
- [x] Fixed 4 high severity: CLAUDE.md skill path, guide.md install command + statusline path + command count
- [x] Fixed 3 medium severity: radio.md missing from guide, playbook stale architecture + version
- [x] Registered all audit targets in .slainte config

## What's Next

- Consider adding video demo (cli-final.mp4) to README once GitHub supports inline video or convert to GIF
- Playlist browser: load more than 200 tracks incrementally
- Playlist browser: re-enable artwork (needs chafa raw-mode compatibility fix)
- Playlist browser: add `/` search within playlists and tracks
- Now playing: consider `n`/`p` as alternative skip keys (non-repeating)
- Volume mixer: highlight selected channel more strongly
- End-to-end testing: playlist with comma in name, overlapping speaker names, 200+ track playlist

## Key Context

- Version is 1.3.0 everywhere (plugin.json, marketplace.json x2, CLI, guide.md)
- GitHub release: https://github.com/anthonymaley/music/releases/tag/v1.3.0
- CLI binary is `music`, installed at `~/.local/bin/music`
- Media files in `media/` folder (nowplaying.png, playlist.jog.jpg, speakers.png, cli-final.mp4)
- **2-screen flow**: PlaylistBrowser ↔ NowPlaying with PlaybackContext. b/Esc returns to browser with state preserved
- **Modal subflows**: s = speaker picker, v = volume mixer — both exit/re-enter raw mode
- **chafa**: `--format symbols` required to avoid iTerm2 inline image protocol. Disabled in playlist browser (raw mode conflict)
- **Key reader**: one-byte-at-a-time parsing. VMIN/VTIME via UnsafeMutableRawPointer
- **Radio**: builds `__radio__TrackName` temp playlist from catalog search. System Events menu approach broken on macOS 26
- **Track limit**: 200 per playlist in browser. Large library playlists ("Music") can still be slow
- **Playlist names**: use linefeed delimiter, not comma split (comma in names was a bug)
- **Speaker matching**: longest match wins (avoids "Office" matching before "Julie office")

## Backlog

- Playlist browser: incremental track loading beyond 200
- Playlist browser: artwork support (chafa + raw mode)
- Playlist browser: `/` search
- Video demo in README
- `/music:list` command for listing playlists
