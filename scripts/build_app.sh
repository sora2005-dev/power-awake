#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="OCC.app"
APP_DIR="$HOME/Applications/$APP_NAME"
EXECUTABLE="$APP_DIR/Contents/MacOS/OCC"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build script is macOS-only." >&2
  exit 1
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  "$OCC_ROOT/Sources/OCC.swift" \
  -o "$EXECUTABLE"

cp "$OCC_ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$EXECUTABLE"

echo "$APP_DIR"
echo "OCC_APP_BUILT"
