#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP_DIR="$ROOT/build/OpenEdit.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/OpenEdit" "$APP_DIR/Contents/MacOS/OpenEdit"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ad-hoc signature so the bundle launches cleanly via `open` during development.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built $APP_DIR"
