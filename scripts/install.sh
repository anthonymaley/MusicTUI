#!/bin/bash
# scripts/install.sh — Build music CLI and make it available on PATH
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLI_DIR="$PROJECT_DIR/tools/music"
INSTALL_DIR="${HOME}/.local/bin"

# Each machine builds on its own local disk and installs its own copy. The
# checkout can be shared between machines over a network mount (the laptop
# reaches the Studio's home over SMB), so building into tools/music/.build
# would compile across the network and let two machines overwrite one build,
# and a symlink into that folder would stop working whenever the mount is
# unreachable. MUSIC_BUILD_DIR overrides the scratch path.
BUILD_DIR="${MUSIC_BUILD_DIR:-$HOME/Library/Caches/musictui/build}"

echo "Building music CLI..."
cd "$CLI_DIR"
swift build -c release --scratch-path "$BUILD_DIR" 2>&1

BINARY="$BUILD_DIR/release/music"
if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed — binary not found at $BINARY"
    exit 1
fi

# Copy, then rename into place: the swap is atomic, so a `music` already
# running keeps its old file, and an old symlink at this path is replaced.
mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_DIR/.music.new"
chmod +x "$INSTALL_DIR/.music.new"
mv -f "$INSTALL_DIR/.music.new" "$INSTALL_DIR/music"

# Copy (don't symlink) the status line script to a stable, version-independent
# path. The plugin cache dir is versioned (.../music/<version>/) and rotates on
# every update; a copy here lets the Claude Code statusLine config point at one
# fixed path that never breaks. The script only shells out to the `music` CLI,
# so a plain copy has no dependency on the cache dir.
cp "$SCRIPT_DIR/statusline.sh" "$INSTALL_DIR/music-statusline"
chmod +x "$INSTALL_DIR/music-statusline"

if ! echo "$PATH" | tr ':' '\n' | grep -q "^${INSTALL_DIR}$"; then
    echo ""
    echo "Add to your shell profile:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

if command -v music &>/dev/null; then
    echo "✓ Installed: $(music --version 2>/dev/null || echo 'music ready')"
else
    echo "✓ Built and symlinked to $INSTALL_DIR/music"
    echo "  Restart your shell or run: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
echo "✓ Status line: $INSTALL_DIR/music-statusline (point statusLine.command here)"
