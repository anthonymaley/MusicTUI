#!/bin/bash
# §20 live gate: proves ONE `music playlist cleanup` invocation removes ALL
# four stale __album__ containers this script creates, not roughly half of
# them, and that it reports the removal honestly.
#
# WHAT THIS SCRIPT TOUCHES, stated precisely because the previous header did
# not: it creates four throwaway playlists whose exact names it generates
# this run, and its own teardown deletes ONLY those exact names. It does not
# broad-sweep during setup or teardown.
#
# It DOES invoke `music playlist cleanup` once, as the behaviour under test,
# and that command deletes EVERY owned temp container in the library
# (the `manualTempPlaylistPrefix` and `albumPlaylistPrefix` values, read from
# source below), not only this script's four. That is why the
# preflight below FAILS CLOSED five ways: if either prefix cannot be read from
# source, if the checkout does not build, if the probe cannot be read, if
# normalising its output fails, or if any owned container already exists.
# Ownership is a LITERAL prefix comparison per name, never a regex built from
# the values, so a value that happens to contain a metacharacter cannot
# silently change what counts as owned.
# The broad cleanup is therefore only exercised in a fixture positively
# confirmed clean, so its measured effect is exactly the four containers this
# run created, and the net-effect assertions below are meaningful rather than
# accidental.
#
# Run BY HAND against a real, ALREADY-RUNNING Music.app. Never launches
# Music.app, never starts playback, never touches a library track.
#
# Usage: scripts/verify-album-sweep.sh
#   No arguments. The binary under test is BUILT from this checkout
#   (`swift build -c release` in tools/music) and run from its build product,
#   because the owned prefixes are read from this checkout's source and a
#   binary from anywhere else could carry different ones (Codex, 2026-09-06).
#
# Exits non-zero on any assertion failure or on a dirty preflight. The trap
# never references a relative path, so teardown is safe regardless of cwd.
set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "✗ this gate takes no arguments: the binary under test is built from this checkout" >&2
    exit 2
fi
# The two owned prefixes are READ FROM SOURCE, never copied here: the cleanup
# under test matches `manualTempPlaylistPrefix` and `albumPlaylistPrefix`, and a
# gate carrying its own copies would stop protecting pre-existing containers the
# moment either value moved (found by Codex, 2026-09-06). The binary under test
# is built from the same checkout below, so the two cannot come from different
# sources. Fails closed if either constant cannot be read.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
read_swift_string_constant() {
    # $1 = Swift file, $2 = top-level `let` name. Prints the literal's contents;
    # a trailing space inside the literal (`__album__ `) is preserved. Accepts
    # exactly ONE simple quoted literal: a second definition or a backslash
    # escape in the value is refused rather than guessed at.
    local matches
    matches=$(sed -n "s/^let $2 = \"\(.*\)\"\$/\1/p" "$1")
    [ -n "$matches" ] || return 1
    [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -eq 1 ] || return 1
    case "$matches" in *\\*) return 1 ;; esac
    printf '%s' "$matches"
}
if ! TEMP_PREFIX=$(read_swift_string_constant "$REPO_ROOT/tools/music/Sources/TUI/PlaylistDataSources.swift" manualTempPlaylistPrefix); then
    echo "✗ could not read manualTempPlaylistPrefix from source; refusing to guess a prefix" >&2
    exit 1
fi
if ! ALBUM_PREFIX=$(read_swift_string_constant "$REPO_ROOT/tools/music/Sources/TUI/AlbumContainer.swift" albumPlaylistPrefix); then
    echo "✗ could not read albumPlaylistPrefix from source; refusing to guess a prefix" >&2
    exit 1
fi
OWNED_PREFIXES=("$TEMP_PREFIX" "$ALBUM_PREFIX")
# Ownership is decided by LITERAL prefix comparison, never by a regex built
# from the values: a value carrying a regex metacharacter (`__temp.+`, say)
# would compile, return an ordinary status, and silently match a different
# language than Swift's `starts with` (Codex, 2026-09-06). A quoted pattern in
# bash's `[[ == ]]` is literal, which is exactly the comparison the sweep makes.
is_owned_name() {
    local name="$1" p
    for p in "${OWNED_PREFIXES[@]}"; do
        [[ "$name" == "$p"* ]] && return 0
    done
    return 1
}

# Build the binary under test from THIS checkout, so the prefixes read above
# and the sweep that runs below come from the same source. Same configuration
# as scripts/install.sh. Fails closed on a failed build; the last lines of the
# build output are shown either way.
echo "-- building the binary under test from this checkout --"
if ! swift build -c release --package-path "$REPO_ROOT/tools/music" 2>&1 | tail -n 20; then
    echo "✗ swift build failed; refusing to run the gate against any other binary" >&2
    exit 1
fi
MUSIC_BIN="$REPO_ROOT/tools/music/.build/release/music"

if [ ! -x "$MUSIC_BIN" ]; then
    echo "✗ Not executable: $MUSIC_BIN" >&2
    exit 1
fi

# `|| true` so a failing osascript cannot kill the script under `set -e`
# before the explanatory message below can print.
running=$(osascript -e 'tell application "System Events" to return (exists process "Music")' 2>&1 || true)
if [ "$running" != "true" ]; then
    echo "✗ Music.app is not running (probe said: $running)." >&2
    echo "  Start it by hand first — this script never launches it." >&2
    exit 1
fi

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

count_user_playlists() { osascript -e 'tell application "Music" to count of user playlists'; }

# NOTE: `playlist "Library"` is the English name of the built-in library
# playlist. On a non-English Music.app this read fails and the gate aborts
# rather than silently skipping the track-count assertion.
count_library_tracks() { osascript -e 'tell application "Music" to count of tracks of playlist "Library"'; }

count_named() {
    osascript -e "tell application \"Music\" to count of (every user playlist whose name is \"$(esc "$1")\")"
}

delete_named() {
    osascript -e "tell application \"Music\" to delete (every user playlist whose name is \"$(esc "$1")\")" >/dev/null 2>&1 || true
}

# Returns the raw playlist-name list on stdout and PROPAGATES osascript's exit
# status. It deliberately does NOT swallow errors: a probe that fails must be
# distinguishable from a probe that found nothing, or the preflight reports a
# state it never measured — the exact defect class this gate exists to catch.
read_playlist_names() {
    osascript -e 'tell application "Music" to return name of every user playlist' 2>&1
}

NAMES=()
# Teardown deletes ONLY the exact names this run recorded as created. It never
# broad-sweeps, so a failure cannot take an unrelated container with it.
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

echo "-- preflight: the fixture must already be clean of owned containers --"
if ! all_names=$(read_playlist_names); then
    echo "✗ PREFLIGHT ABORTED: could not read the playlist list, so the fixture" >&2
    echo "  could NOT be confirmed clean. Refusing to run a broad cleanup against" >&2
    echo "  a library this gate never actually read. osascript said:" >&2
    echo "    $all_names" >&2
    exit 1
fi
# `|| true` here would defeat pipefail exactly as `2>/dev/null` defeated the
# probe above. The normalisation pipeline has no legitimate non-zero status,
# so any non-zero from it is a real failure and aborts the preflight rather
# than reading as a clean fixture.
set +e
stripped=$(printf '%s' "$all_names" | tr ',' '\n' | sed 's/^ *//')
strip_rc=$?
set -e
if [ "$strip_rc" -ne 0 ]; then
    echo "✗ PREFLIGHT ABORTED: could not normalise the playlist list (exit $strip_rc)." >&2
    echo "  Refusing to run a broad cleanup on an unverified fixture." >&2
    exit 1
fi
# The ownership test is a literal comparison per name (is_owned_name above),
# so there is no filter stage with an exit status to interpret.
preexisting=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    if is_owned_name "$line"; then
        preexisting="${preexisting}${line}"$'\n'
    fi
done <<< "$stripped"
preexisting=${preexisting%$'\n'}
if [ -n "$preexisting" ]; then
    echo "✗ PREFLIGHT REFUSED: owned temp container(s) already exist:" >&2
    # Quoted + sed rather than unquoted printf: every `__album__ ` name
    # contains a space, which word-splitting would tear across lines.
    echo "$preexisting" | sed 's/^/    /' >&2
    echo "  This gate invokes a BROAD cleanup, which would delete these too and make" >&2
    echo "  its net-effect assertions meaningless (and could red-flag a clean tree)." >&2
    echo "  Remove or let them settle first, then re-run." >&2
    exit 1
fi
echo "✓ preflight: no pre-existing owned containers (prefixes read from source: '${TEMP_PREFIX}' '${ALBUM_PREFIX}')"

echo "-- baseline --"
baseline_playlists=$(count_user_playlists)
baseline_tracks=$(count_library_tracks)
echo "user playlists: $baseline_playlists"
echo "library tracks: $baseline_tracks"

echo "-- creating four throwaway containers --"
for i in 1 2 3 4; do
    name="${ALBUM_PREFIX}$(uuidgen) — SWEEP-VERIFY-THROWAWAY"
    NAMES+=("$name")
    osascript -e "tell application \"Music\" to make new playlist with properties {name:\"$(esc "$name")\"}" >/dev/null
    echo "  created: $name"
done

after_create=$(count_user_playlists)
created_delta=$((after_create - baseline_playlists))
if [ "$created_delta" -ne 4 ]; then
    echo "✗ setup: user playlist count rose by $created_delta, not 4 ($baseline_playlists -> $after_create)" >&2
    exit 1
fi
echo "✓ setup: user playlist count rose by exactly 4 ($baseline_playlists -> $after_create)"

echo "-- running: $MUSIC_BIN playlist cleanup (ONE invocation, broad by design) --"
cleanup_out=$("$MUSIC_BIN" playlist cleanup 2>&1)
echo "  reported: $cleanup_out"

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
echo "created=4 removed=$removed remaining=$remaining"

if [ "$remaining" -ne 0 ]; then
    echo "✗ FAIL: $remaining of 4 stale containers survived one cleanup invocation" >&2
    exit 1
fi
echo "✓ all four removed by exactly one cleanup invocation"

# §20.3 has live evidence here rather than resting on unit tests alone: the
# command must REPORT the four it removed, and must never say "Cleaned up 0".
echo "-- checking the reported outcome matches the measured one --"
case "$cleanup_out" in
    *"Cleaned up 4 temp playlist(s)."*) echo "✓ reported exactly: $cleanup_out" ;;
    *"Cleaned up 0"*)
        echo "✗ FAIL: reported a bare 'Cleaned up 0' while four were removed" >&2; exit 1 ;;
    *)
        echo "✗ FAIL: removed 4 but reported: $cleanup_out" >&2; exit 1 ;;
esac

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
