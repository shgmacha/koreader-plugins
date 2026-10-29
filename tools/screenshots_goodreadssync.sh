#!/bin/sh
# Screenshots of Goodreads Sync's pages over a made-up demo book, with made-up
# Goodreads data (nothing goes online). Blossom isn't installed in the demo.
#   tools/screenshots_goodreadssync.sh [path/to/KOReader.app]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Applications/KOReader.app}"
DEMO="${TMPDIR:-/tmp}/goodreadssync-demo"
OUT="$ROOT/docs/screenshots"
PYTHON="$(command -v /usr/bin/python3 || command -v python3)"

"$PYTHON" "$ROOT/tools/make_demo.py" "$DEMO"
rm -f "$DEMO/home/plugins/blossom.koplugin"
cp -R "$ROOT/goodreadssync.koplugin" "$DEMO/home/plugins/goodreadssync.koplugin" # a copy: a symlink would make Blossom (next to it in the repo) look installed
mkdir -p "$DEMO/home/patches" "$OUT"
cp "$ROOT/tools/screenshot_goodreadssync_patch.lua" "$DEMO/home/patches/2-goodreadssync-shots.lua"
rm -f "$OUT"/gs*-*.png

cd "$APP/Contents/koreader"
KO_HOME="$DEMO/home" GOODREADSSYNC_SHOTS="$OUT" EMULATE_READER_W=758 EMULATE_READER_H=1024 EMULATE_READER_DPI=212 \
    ./luajit reader.lua > "$DEMO/koreader.log" 2>&1 &
PID=$!
i=0
while kill -0 $PID 2>/dev/null && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
kill $PID 2>/dev/null || true
ls "$OUT"/gs*-*.png
