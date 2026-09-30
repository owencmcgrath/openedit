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

# SwiftPM emits a resource bundle per tree-sitter grammar target next to the
# executable; they hold the highlight queries (AGENTS/GRAMMARS.md). The
# highlighter resolves them from Bundle.main.resourceURL, so they belong in
# Contents/Resources. Only grammar bundles are copied, so an unrelated SwiftPM
# resource bundle added later is not dragged in accidentally.
for grammar_bundle in "$BIN_PATH"/TreeSitter*.bundle; do
    [ -e "$grammar_bundle" ] || continue
    cp -R "$grammar_bundle" "$APP_DIR/Contents/Resources/"
done

# Ad-hoc signature so the bundle launches cleanly via `open` during development.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built $APP_DIR"
