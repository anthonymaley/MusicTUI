#!/bin/bash
# §20 live gate: proves ONE `music playlist cleanup` invocation removes ALL
# stale __album__ containers it creates, not roughly half of them. Run BY
# HAND against a real, ALREADY-RUNNING Music.app — this script never
# launches Music.app, never starts playback, and only ever creates or
# deletes playlists whose exact names it generated itself this run.
#
# Usage: scripts/verify-album-sweep.sh [path-to-music-binary]
#   (default: $HOME/.local/bin/music)
#
# Exits non-zero on any assertion failure. Always removes its own four
# throwaway containers on exit, success or failure (trap below never
# references a relative path, so it is safe regardless of cwd when it fires).
set -euo pipefail

MUSIC_BIN="${1:-$HOME/.local/bin/music}"

if [ ! -x "$MUSIC_BIN" ]; then
    echo "✗ Not executable: $MUSIC_BIN" >&2
    exit 1
fi

# Refuse to run unless Music.app is ALREADY running. Never launch it.
running=$(osascript -e 'tell application "System Events" to return (exists process "Music")' 2>&1)
if [ "$running" != "true" ]; then
    echo "✗ Music.app is not running. Start it by hand first — this script never launches it." >&2
    exit 1
fi

# Escape a string for embedding inside a double-quoted AppleScript literal.
esc() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

count_user_playlists() {
    osascript -e 'tell application "Music" to count of user playlists'
}

count_library_tracks() {
    osascript -e 'tell application "Music" to count of tracks of playlist "Library"'
}

count_named() {
    local name_esc
    name_esc=$(esc "$1")
    osascript -e "tell application \"Music\" to count of (every user playlist whose name is \"$name_esc\")"
}

delete_named() {
    local name_esc
    name_esc=$(esc "$1")
    osascript -e "tell application \"Music\" to delete (every user playlist whose name is \"$name_esc\")" >/dev/null 2>&1 || true
}

NAMES=()
cleanup() {
    local n
    for n in "${NAMES[@]+"${NAMES[@]}"}"; do
        delete_named "$n"
    done
}
trap cleanup EXIT

echo "== §20 live gate: one cleanup invocation must remove all four stale __album__ containers =="
echo "binary under test: $MUSIC_BIN"
echo "version: $("$MUSIC_BIN" --version)"

echo "-- baseline --"
baseline_playlists=$(count_user_playlists)
baseline_tracks=$(count_library_tracks)
echo "user playlists: $baseline_playlists"
echo "library tracks: $baseline_tracks"

echo "-- creating four throwaway containers --"
for i in 1 2 3 4; do
    uuid=$(uuidgen)
    name="__album__ ${uuid} — SWEEP-VERIFY-THROWAWAY"
    NAMES+=("$name")
    osascript -e "tell application \"Music\" to make new playlist with properties {name:\"$(esc "$name")\"}" >/dev/null
    echo "  created: $name"
done

after_create=$(count_user_playlists)
created_delta=$((after_create - baseline_playlists))
if [ "$created_delta" -ne 4 ]; then
    echo "✗ setup: user playlist count rose by $created_delta, not 4 (baseline $baseline_playlists -> $after_create)" >&2
    exit 1
fi
echo "✓ setup: user playlist count rose by exactly 4 ($baseline_playlists -> $after_create)"

echo "-- running: $MUSIC_BIN playlist cleanup (ONE invocation) --"
"$MUSIC_BIN" playlist cleanup

echo "-- checking all four are gone after that ONE invocation --"
remaining=0
for n in "${NAMES[@]}"; do
    c=$(count_named "$n")
    if [ "$c" != "0" ]; then
        echo "✗ still present: $n ($c)" >&2
        remaining=$((remaining + c))
    fi
done
removed=$((4 - remaining))
echo "four created, four removed: created=4 removed=$removed remaining=$remaining"

if [ "$remaining" -ne 0 ]; then
    echo "✗ FAIL: $remaining of 4 stale containers survived one cleanup invocation" >&2
    exit 1
fi
echo "✓ all four removed by exactly one cleanup invocation"

echo "-- verifying net effect on the real library is zero --"
after_playlists=$(count_user_playlists)
after_tracks=$(count_library_tracks)
if [ "$after_playlists" != "$baseline_playlists" ]; then
    echo "✗ user playlist count changed: $baseline_playlists -> $after_playlists" >&2
    exit 1
fi
if [ "$after_tracks" != "$baseline_tracks" ]; then
    echo "✗ library track count changed: $baseline_tracks -> $after_tracks" >&2
    exit 1
fi
echo "✓ user playlists unchanged ($after_playlists), library tracks unchanged ($after_tracks)"

echo "== PASS =="
