---
name: music
description: "Control Apple Music playback, AirPlay speakers, and AirPods/Bluetooth headphones on macOS using AppleScript. Use this skill whenever the user wants to play music, control playback (play, pause, skip, volume, shuffle), manage playlists, play an album or artist, search their music library, route audio to AirPlay speakers or AirPods, add or remove speakers from a group, adjust per-speaker volume, switch between headphones and speakers, or check what's currently playing. Trigger on any mention of: Apple Music, AirPlay, speakers, playlist, play a song, what's playing, music volume, now playing, queue, HomePod, AirPods, headphones, Bluetooth audio, album, artist, or any request to control audio playback on their Mac — even casual ones like 'put on some music', 'switch to my AirPods', 'switch to the kitchen speaker', 'add the bedroom to the group', or 'turn down the kitchen'."
---

# Apple Music Controller

This skill lets you control Apple Music and AirPlay speakers on the user's Mac via AppleScript (`osascript`). Every command runs through `osascript -e '...'` in bash — no extra dependencies needed.

## Important: This only works on macOS

AppleScript is a macOS-only technology. If the user is on Linux or Windows, let them know this skill won't work and suggest alternatives (like Spotify's API or the music-mcp npm package if they have Node.js).

## How it works

All commands follow the same pattern — you construct an AppleScript snippet and run it via `osascript`. The Music app must be installed (it comes with macOS). The user may need to grant automation permissions the first time (System Settings → Privacy & Security → Automation).

## Core Commands Reference

### Playback Control

```bash
# Play / Resume
osascript -e 'tell application "Music" to play'

# Pause
osascript -e 'tell application "Music" to pause'

# Next track
osascript -e 'tell application "Music" to next track'

# Previous track
osascript -e 'tell application "Music" to previous track'

# Stop
osascript -e 'tell application "Music" to stop'
```

### Now Playing

```bash
# Get current track info
osascript -e 'tell application "Music"
    set trackName to name of current track
    set trackArtist to artist of current track
    set trackAlbum to album of current track
    set trackDuration to duration of current track
    set playerPos to player position
    return trackName & " | " & trackArtist & " | " & trackAlbum & " | " & (round playerPos) & "s / " & (round trackDuration) & "s"
end tell'

# Get player state (playing, paused, stopped)
osascript -e 'tell application "Music" to get player state'
```

### Volume

The Music app has a global volume, and each AirPlay device has its own independent volume (both 0–100). Use global volume for quick adjustments, and per-device volume when the user names a specific speaker.

```bash
# Get global Music volume (0-100)
osascript -e 'tell application "Music" to get sound volume'

# Set global Music volume
osascript -e 'tell application "Music" to set sound volume to 50'

# Increase volume by 10
osascript -e 'tell application "Music" to set sound volume to (sound volume + 10)'

# Decrease volume by 10
osascript -e 'tell application "Music" to set sound volume to (sound volume - 10)'

# Set volume on a specific AirPlay speaker
osascript -e 'tell application "Music" to set sound volume of AirPlay device "Kitchen" to 75'

# Get volume of a specific speaker
osascript -e 'tell application "Music" to get sound volume of AirPlay device "Kitchen"'

# Set different volumes on multiple speakers at once
osascript -e 'tell application "Music"
    set sound volume of AirPlay device "Kitchen" to 60
    set sound volume of AirPlay device "Bedroom" to 30
end tell'
```

### Shuffle & Repeat

```bash
# Toggle shuffle on
osascript -e 'tell application "Music" to set shuffle enabled to true'

# Toggle shuffle off
osascript -e 'tell application "Music" to set shuffle enabled to false'

# Check shuffle state
osascript -e 'tell application "Music" to get shuffle enabled'

# Set repeat mode: off, one, all
osascript -e 'tell application "Music" to set song repeat to all'
osascript -e 'tell application "Music" to set song repeat to one'
osascript -e 'tell application "Music" to set song repeat to off'
```

### Playlists

```bash
# List all playlist names
osascript -e 'tell application "Music" to get name of every playlist'

# Play a specific playlist
osascript -e 'tell application "Music" to play playlist "Working Vibes"'

# Play a playlist with shuffle
osascript -e 'tell application "Music"
    set shuffle enabled to true
    play playlist "Working Vibes"
end tell'

# Switch to a different playlist (just play the new one — it replaces the current queue)
osascript -e 'tell application "Music" to play playlist "Chill Evening"'

# Get tracks in a playlist
osascript -e 'tell application "Music"
    set trackList to name of every track of playlist "Working Vibes"
    return trackList
end tell'

# Get track count in a playlist
osascript -e 'tell application "Music" to get count of tracks of playlist "Working Vibes"'
```

### Search Library

```bash
# Search for tracks by name
osascript -e 'tell application "Music"
    set results to (every track of playlist "Library" whose name contains "search term")
    set output to ""
    repeat with t in results
        set output to output & name of t & " - " & artist of t & linefeed
    end repeat
    return output
end tell'

# Search by artist
osascript -e 'tell application "Music"
    set results to (every track of playlist "Library" whose artist contains "artist name")
    set output to ""
    repeat with t in results
        set output to output & name of t & " - " & album of t & linefeed
    end repeat
    return output
end tell'

# Search by album
osascript -e 'tell application "Music"
    set results to (every track of playlist "Library" whose album contains "album name")
    set output to ""
    repeat with t in results
        set output to output & name of t & " - " & artist of t & linefeed
    end repeat
    return output
end tell'
```

### Play by Artist, Album, or Song

AppleScript doesn't have a direct "play this album" command, so the approach is: search the library, then play the results. This works well and is reliable.

```bash
# Play an album — find all tracks from that album and play the first one
# (Music will continue playing the album in order)
osascript -e 'tell application "Music"
    set results to (every track of playlist "Library" whose album contains "Album Name")
    if (count of results) > 0 then
        play item 1 of results
    else
        return "No tracks found for that album"
    end if
end tell'

# Play all songs by an artist
osascript -e 'tell application "Music"
    set results to (every track of playlist "Library" whose artist contains "Artist Name")
    if (count of results) > 0 then
        play item 1 of results
    else
        return "No tracks found for that artist"
    end if
end tell'

# Play a specific song
osascript -e 'tell application "Music"
    set results to (every track of playlist "Library" whose name contains "Song Name")
    if (count of results) > 0 then
        play item 1 of results
    else
        return "No tracks found with that name"
    end if
end tell'

# Play a specific song by a specific artist (narrow search)
osascript -e 'tell application "Music"
    set results to (every track of playlist "Library" whose name contains "Song Name" and artist contains "Artist Name")
    if (count of results) > 0 then
        play item 1 of results
    else
        return "No matching track found"
    end if
end tell'

# List all albums in the library (useful for browsing — can be slow on large libraries)
osascript -e 'tell application "Music"
    set albumList to {}
    set allTracks to every track of playlist "Library"
    repeat with t in allTracks
        set albumName to album of t
        if albumName is not in albumList then
            set end of albumList to albumName
        end if
    end repeat
    return albumList
end tell'
```

### Queue Management

```bash
# Add a track to Up Next (by searching for it first)
osascript -e 'tell application "Music"
    set results to (every track of playlist "Library" whose name contains "Song Name")
    if (count of results) > 0 then
        play item 1 of results
    end if
end tell'
```

Note: AppleScript's queue management is limited. For "add to Up Next" functionality, the user may need to interact with the Music app directly or use a workaround playlist.

### Create a Playlist

```bash
# Create a new empty playlist
osascript -e 'tell application "Music" to make new playlist with properties {name:"My New Playlist"}'

# Create a playlist and add tracks to it
osascript -e 'tell application "Music"
    set newList to make new playlist with properties {name:"My New Playlist"}
    set results to (every track of playlist "Library" whose artist contains "Artist Name")
    repeat with t in results
        duplicate t to newList
    end repeat
end tell'
```

## AirPlay Control

This is the key differentiator. AppleScript can discover, list, and route audio to AirPlay speakers — including multi-room grouping.

### Discover Available AirPlay Devices

Always run this first before any speaker operation. Speaker names are user-configured and can be anything.

```bash
# List all AirPlay device names
osascript -e 'tell application "Music" to get name of every AirPlay device'

# List devices with full details (name, selected, volume, kind)
osascript -e 'tell application "Music"
    set deviceList to every AirPlay device
    set output to ""
    repeat with d in deviceList
        set output to output & name of d & " | selected: " & selected of d & " | volume: " & sound volume of d & " | kind: " & kind of d & linefeed
    end repeat
    return output
end tell'
```

### Switch to a Single Speaker

Deselect everything else first so audio only goes to the target:

```bash
osascript -e 'tell application "Music"
    set allDevices to every AirPlay device
    repeat with d in allDevices
        set selected of d to false
    end repeat
    set selected of AirPlay device "Kitchen" to true
end tell'
```

### Multi-Room: Add a Speaker to the Current Group

If the user says "also play in the bedroom" or "add the bedroom", just select it without deselecting others:

```bash
# Add a speaker to the active group
osascript -e 'tell application "Music"
    set selected of AirPlay device "Bedroom" to true
end tell'
```

### Multi-Room: Remove a Speaker from the Group

```bash
# Remove a speaker from the active group
osascript -e 'tell application "Music"
    set selected of AirPlay device "Bedroom" to false
end tell'
```

### Multi-Room: Set Up a Specific Group

Deselect all, then select only the ones you want:

```bash
# Play on Kitchen and Bedroom only
osascript -e 'tell application "Music"
    set allDevices to every AirPlay device
    repeat with d in allDevices
        set selected of d to false
    end repeat
    set selected of AirPlay device "Kitchen" to true
    set selected of AirPlay device "Bedroom" to true
end tell'
```

### Per-Speaker Volume in a Group

Each AirPlay device has its own volume (0-100), independent of global volume:

```bash
# Set volume on a specific speaker
osascript -e 'tell application "Music" to set sound volume of AirPlay device "Kitchen" to 75'

# Get volume of a specific speaker
osascript -e 'tell application "Music" to get sound volume of AirPlay device "Kitchen"'

# Quieter in the bedroom, louder in the kitchen
osascript -e 'tell application "Music"
    set sound volume of AirPlay device "Kitchen" to 70
    set sound volume of AirPlay device "Bedroom" to 30
end tell'
```

### Show Currently Active Speakers

```bash
osascript -e 'tell application "Music"
    set deviceList to every AirPlay device
    set output to ""
    repeat with d in deviceList
        if selected of d then
            set output to output & name of d & " (vol: " & sound volume of d & ")" & linefeed
        end if
    end repeat
    if output is "" then
        return "No AirPlay devices currently selected"
    end if
    return output
end tell'
```

## AirPods & Bluetooth Headphones

AirPods (and other Bluetooth audio devices) appear as AirPlay devices in the Music app — so the same commands work. The device name is typically the user's AirPods name (e.g., "Anthony's AirPods Pro", "AirPods").

### Switch to AirPods

```bash
# First discover devices to find the exact AirPods name
osascript -e 'tell application "Music" to get name of every AirPlay device'

# Switch output to AirPods (deselect all speakers first)
osascript -e 'tell application "Music"
    set allDevices to every AirPlay device
    repeat with d in allDevices
        set selected of d to false
    end repeat
    set selected of AirPlay device "Anthony'\''s AirPods Pro" to true
end tell'
```

Note the escaped apostrophe (`'\''`) — AirPods names often contain the user's name with an apostrophe. In bash, you close the single quote, add an escaped quote, then reopen: `'Anthony'\''s AirPods Pro'`.

### Switch from AirPods Back to a Speaker

```bash
osascript -e 'tell application "Music"
    set allDevices to every AirPlay device
    repeat with d in allDevices
        set selected of d to false
    end repeat
    set selected of AirPlay device "Kitchen" to true
end tell'
```

### Check if AirPods Are Connected

AirPods will only appear in the AirPlay device list if they're connected to the Mac via Bluetooth. If they're not showing up, the user needs to connect them first (via Bluetooth settings or by opening the AirPods case near the Mac).

```bash
# Check if a specific device is available and selected
osascript -e 'tell application "Music"
    try
        set isAvailable to available of AirPlay device "Anthony'\''s AirPods Pro"
        set isSelected to selected of AirPlay device "Anthony'\''s AirPods Pro"
        return "Available: " & isAvailable & ", Selected: " & isSelected
    on error
        return "AirPods not found — they may not be connected via Bluetooth"
    end try
end tell'
```

## Workflow Examples

**"Play Working Vibes on the kitchen speaker"**
1. Discover devices → confirm "Kitchen" exists
2. Switch to Kitchen (deselect all, select Kitchen)
3. Play playlist "Working Vibes"
4. Report back

**"Also add the bedroom speaker and turn it down a bit"**
1. Add Bedroom to group (select without deselecting others)
2. Set Bedroom volume to 30
3. Confirm the active group

**"Switch to the Daft Punk album"**
1. Search library for album containing "Daft Punk"
2. Play the first result
3. Report what's now playing

**"Turn the kitchen up to 80"**
1. Set Kitchen AirPlay device volume to 80
2. Confirm

**"Switch to my AirPods"**
1. Discover devices → find the AirPods name
2. Deselect all speakers, select the AirPods device
3. Confirm output switched

**"Remove the bedroom from the group"**
1. Deselect Bedroom only (leave others selected)
2. Show remaining active speakers

Always discover devices and playlists first rather than guessing names. Speaker and playlist names are user-configured and can be anything.

## Error Handling

Common issues and how to handle them:

- **"Parameter error (-50)"** — This often happens when combining AirPlay device selection with playlist playback in a single `tell` block. Split them into separate `osascript` calls: route audio first, then play.
- **"Music got an error: AppleEvent timed out"** — The Music app may not be running. Try `osascript -e 'tell application "Music" to activate'` first, wait a moment, then retry.
- **"execution error: Music got an error: Can't get AirPlay device"** — The device name doesn't match. Re-run the device list command and check for exact spelling (names are case-sensitive).
- **Automation permission denied** — The user needs to go to System Settings → Privacy & Security → Automation and enable access for their terminal app.
- **No tracks found** — The search term may be too specific. Try a shorter or broader search. AppleScript `contains` is case-insensitive, so casing isn't the issue — it's usually a spelling mismatch.

## Tips

- **Split AirPlay routing and playback into separate `osascript` calls.** Combining speaker selection and `play playlist` in a single `tell` block can trigger a "Parameter error (-50)". Route first, then play in a second call.
- Always list AirPlay devices before trying to route — don't assume device names
- When playing a playlist, confirm the exact playlist name first by listing playlists
- Combine operations in a single `tell` block when possible to reduce latency
- The Music app needs to be running for commands to work — activate it if needed
- AppleScript search is case-insensitive for `contains` comparisons
- To "change" playlists, just play the new one — it replaces the current queue automatically
- To switch speakers, always deselect all first then select the target(s)
- To add/remove a speaker from a group, just set its `selected` property without touching others
- If the user wants Apple Music catalog content (not in their library), they'll need to search in the Music app UI — AppleScript primarily accesses the local library
