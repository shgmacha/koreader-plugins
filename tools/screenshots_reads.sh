#!/bin/sh
# Screenshots of Blossom Reads' popups over a made-up demo book, with made-up
# Goodreads data (nothing goes online).
#   tools/screenshots_reads.sh [path/to/KOReader.app]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Applications/KOReader.app}"
DEMO="${TMPDIR:-/tmp}/blossomreads-demo"
OUT="$ROOT/docs/screenshots"

python3 "$ROOT/tools/make_demo.py" "$DEMO"
ln -s "$ROOT/blossomreads.koplugin" "$DEMO/home/plugins/blossomreads.koplugin"
mkdir -p "$DEMO/home/patches" "$OUT"
cp "$ROOT/tools/screenshot_reads_patch.lua" "$DEMO/home/patches/2-blossomreads-shots.lua"
rm -f "$OUT"/r*-*.png

cd "$APP/Contents/koreader"
KO_HOME="$DEMO/home" BLOSSOMREADS_SHOTS="$OUT" EMULATE_READER_W=758 EMULATE_READER_H=1024 EMULATE_READER_DPI=212 \
    ./luajit reader.lua > "$DEMO/koreader.log" 2>&1 &
PID=$!
i=0
while kill -0 $PID 2>/dev/null && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
kill $PID 2>/dev/null || true
ls "$OUT"/r*-*.png
