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
# (`__temp__` and `__album__ `), not only this script's four. That is why the
# preflight below FAILS CLOSED four ways: if any owned container already
# exists, if the probe cannot be read, if normalising its output fails, or if
# the filter over it fails. Each stage is checked separately, because under
# pipefail a later stage's "no match" would otherwise mask an earlier failure. The broad cleanup is only exercised in a fixture positively confirmed
# clean, so its
# measured effect is exactly the four this run created and the net-effect
# assertions below are meaningful rather than accidental.
#
# Run BY HAND against a real, ALREADY-RUNNING Music.app. Never launches
# Music.app, never starts playback, never touches a library track.
#
# Usage: scripts/verify-album-sweep.sh [path-to-music-binary]
#   (default: $HOME/.local/bin/music)
#
# Exits non-zero on any assertion failure or on a dirty preflight. The trap
# never references a relative path, so teardown is safe regardless of cwd.
set -euo pipefail

MUSIC_BIN="${1:-$HOME/.local/bin/music}"
OWNED_PREFIXES=('__temp__' '__album__ ')
# Single source of truth: the preflight regex is BUILT from OWNED_PREFIXES, so
# a prefix added to the array cannot fail to reach the filter. Entries are used
# as ERE fragments, so an entry containing a metacharacter would break the
# filter — which is why the filter's exit status is checked below rather than
# being swallowed.
OWNED_RE=$(printf '^%s|' "${OWNED_PREFIXES[@]}"); OWNED_RE=${OWNED_RE%|}

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
# probe above: grep exit 1 means "no match" (genuinely clean), but exit 2 means
# the filter FAILED — an unbalanced bracket in an OWNED_PREFIXES entry, say —
# and collapsing the two reports a clean fixture that was never established.
# Split the stages. Under pipefail a pipeline reports the RIGHTMOST non-zero
# status, so grep's exit 1 ("no match" — the clean case) would mask a failure in
# tr or sed and read as a clean fixture. Each stage is checked on its own.
set +e
stripped=$(printf '%s' "$all_names" | tr ',' '\n' | sed 's/^ *//')
strip_rc=$?
set -e
if [ "$strip_rc" -ne 0 ]; then
    echo "✗ PREFLIGHT ABORTED: could not normalise the playlist list (exit $strip_rc)." >&2
    echo "  Refusing to run a broad cleanup on an unverified fixture." >&2
    exit 1
fi
set +e
preexisting=$(printf '%s' "$stripped" | grep -E "$OWNED_RE")
filter_rc=$?
set -e
if [ "$filter_rc" -gt 1 ]; then
    echo "✗ PREFLIGHT ABORTED: could not filter the playlist list (exit $filter_rc)." >&2
    echo "  OWNED_RE was: $OWNED_RE" >&2
    echo "  Refusing to run a broad cleanup on an unverified fixture." >&2
    exit 1
fi
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
echo "✓ preflight: no pre-existing __temp__ or __album__ containers"

echo "-- baseline --"
baseline_playlists=$(count_user_playlists)
baseline_tracks=$(count_library_tracks)
echo "user playlists: $baseline_playlists"
echo "library tracks: $baseline_tracks"

echo "-- creating four throwaway containers --"
for i in 1 2 3 4; do
    name="__album__ $(uuidgen) — SWEEP-VERIFY-THROWAWAY"
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
