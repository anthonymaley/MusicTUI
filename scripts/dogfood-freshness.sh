#!/usr/bin/env bash
# Rebuild both binaries from the current trees, then report what a gate will run.
#
# On 2026-09-16 a live gate failed twice and neither failure was real: the CLI had
# been rebuilt with scripts/install.sh while the source app bundle was three builds
# stale, so a new wire operation reached an app that had never heard of it and was
# refused. The symptom looked exactly like a protocol defect.
#
# It REBUILDS rather than comparing timestamps. The first version of this script
# compared each binary's mtime against its newest source file and was wrong within
# a minute of being written: SwiftPM hashes content, so a file whose mtime moved
# without its content changing leaves the binary permanently "stale". A no-op
# build is a second or two and cannot be wrong in either direction.
#
# `--version` answers nothing here — it is a hand-maintained string.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${MUSICTUI_SOURCE_REPO:-$(cd "$REPO/.." && pwd)/musictui-source}"

echo "Rebuilding both binaries before the gate."

"$REPO/scripts/install.sh" > /tmp/dogfood-cli-build.log 2>&1 \
    || { echo "  music (CLI)      BUILD FAILED — see /tmp/dogfood-cli-build.log"; exit 1; }
cli="$(readlink -f "$(command -v music)")"
printf '  %-16s %s\n' "music (CLI)" "$(shasum -a 256 "$cli" | cut -c1-12)"

if [ -d "$SOURCE_APP" ]; then
    ( cd "$SOURCE_APP" && ./scripts/make-bundle.sh ) > /tmp/dogfood-app-build.log 2>&1 \
        || { echo "  MusicTUISource   BUILD FAILED — see /tmp/dogfood-app-build.log"; exit 1; }
    app="$SOURCE_APP/build/MusicTUISource.app/Contents/MacOS/MusicTUISource"
    printf '  %-16s %s\n' "MusicTUISource" "$(shasum -a 256 "$app" | cut -c1-12)"
    running="$(pgrep -f MusicTUISource || true)"
    if [ -n "$running" ]; then
        echo
        echo "  MusicTUISource is running as PID $running — it is the OLD binary until relaunched:"
        echo "    osascript -e 'tell application \"MusicTUISource\" to quit'"
        echo "    /usr/bin/open $SOURCE_APP/build/MusicTUISource.app"
        echo "  Never exec the binary directly: a direct exec lands in a [tty,remote] session"
        echo "  and reads .notDetermined."
    fi
else
    echo "  MusicTUISource   not found at $SOURCE_APP (set MUSICTUI_SOURCE_REPO)"
fi
