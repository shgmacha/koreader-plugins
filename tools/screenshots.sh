#!/bin/sh
# Rebuilds the README screenshots from the made-up demo library.
#   tools/screenshots.sh [path/to/KOReader.app]
# Needs the KOReader macOS build (koreader-macos-*.7z from KOReader's GitHub releases).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Applications/KOReader.app}"
DEMO="${TMPDIR:-/tmp}/blossom-demo"
OUT="$ROOT/docs/screenshots"

python3 "$ROOT/tools/make_demo.py" "$DEMO"
mkdir -p "$DEMO/home/patches" "$OUT"
cp "$ROOT/tools/screenshot_patch.lua" "$DEMO/home/patches/2-blossom-shots.lua"
rm -f "$OUT"/*.png

cd "$APP/Contents/koreader"
KO_HOME="$DEMO/home" BLOSSOM_SHOTS="$OUT" EMULATE_READER_W=758 EMULATE_READER_H=1024 EMULATE_READER_DPI=212 \
    ./luajit reader.lua > "$DEMO/koreader.log" 2>&1 &
PID=$!
i=0
while kill -0 $PID 2>/dev/null && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
kill $PID 2>/dev/null || true
ls "$OUT"
