# media/demo.tape — TUI walkthrough demo for the README.
# Regenerate: vhs media/demo.tape   (then optimize per docs)
# Requires live Apple Music auth, the "Sleep" playlist, and a reachable AirPlay speaker.
# Running this STARTS real playback (Nude — Radiohead) and toggles a real speaker + EQ.

Output media/demo.gif

Require music

Set Shell "zsh"
Set Theme "Apple Classic"
Set FontFamily "JetBrains Mono"
Set FontSize 22
Set Width 1280
Set Height 800
Set Padding 24
Set WindowBar Colorful
Set Framerate 24
Set TypingSpeed 90ms

# --- Launch (hidden to skip cold-start latency) ---
Hide
Type "music"
Enter
Sleep 4s
Show

# --- Beat 1: Playlists — find "Sleep", open it, play track 2 (Nude) ---
Type "2"
Sleep 1500ms
Type "/"
Sleep 500ms
Type "sleep"
Sleep 1200ms
Enter
Sleep 800ms
Enter
Sleep 2500ms
Down
Sleep 1200ms
Enter

# --- Beat 2: Now Playing (Nude playing) ---
Sleep 3500ms

# --- Beat 3: Controls in use ---
Left
Sleep 1500ms
Enter
Sleep 1500ms
Down
Sleep 800ms
Enter
Sleep 1500ms
Down
Sleep 800ms
Enter
Sleep 1500ms
Right
Sleep 1500ms

# --- Beat 4: Speakers + EQ ---
Type "3"
Sleep 1500ms
Down 5
Sleep 800ms
Enter
Sleep 1500ms
Type "e"
Sleep 1500ms
Down
Sleep 800ms
Enter
Sleep 2500ms

# --- End ---
Type "q"
Sleep 1s
