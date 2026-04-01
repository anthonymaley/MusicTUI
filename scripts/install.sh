#!/bin/bash
# scripts/install.sh — Build music CLI and make it available on PATH
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLI_DIR="$PROJECT_DIR/tools/music"
INSTALL_DIR="${HOME}/.local/bin"

echo "Building music CLI..."
cd "$CLI_DIR"
swift build -c release 2>&1

BINARY="$CLI_DIR/.build/release/music"
if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed — binary not found at $BINARY"
    exit 1
fi

mkdir -p "$INSTALL_DIR"
ln -sf "$BINARY" "$INSTALL_DIR/music"

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
