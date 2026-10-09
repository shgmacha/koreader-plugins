#!/bin/sh
# Builds (and with --publish, publishes) a GitHub Release for one plugin, for the in-plugin updater.
#
#   tools/release.sh blossom 1.1.0               # dry run: bump _meta.lua, build zip + sha256, show what would be published
#   tools/release.sh blossom 1.1.0 --publish     # also create release "blossom-v1.1.0" on GitHub
#   tools/release.sh blossomreads 1.1.0 notes.md --publish
#
# The release gets:
#   <plugin>.koplugin.zip         (top folder <plugin>.koplugin/ inside)
#   <plugin>.koplugin.zip.sha256  ("<hex>  <plugin>.koplugin.zip")
# Publishing needs the version bump committed and pushed first (the tag points at that commit).
set -e

PLUGIN="$1"; VERSION="$2"; shift 2 2>/dev/null || true
NOTES=""; PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        *) NOTES="$arg" ;;
    esac
done

if [ -z "$PLUGIN" ] || [ -z "$VERSION" ]; then
    echo "usage: tools/release.sh <plugin> <version> [notes.md] [--publish]" >&2; exit 2
fi
case "$VERSION" in
    *[!0-9.]*|.*|*.) echo "version must look like 1.2.3" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$PLUGIN.koplugin"
META="$ROOT/$DIR/_meta.lua"
TAG="$PLUGIN-v$VERSION"
DIST="$ROOT/dist"
ZIP="$DIST/$DIR.zip"
SUM="$ZIP.sha256"
REPO="shgmacha/koreader-plugins"

[ -f "$META" ] || { echo "no $DIR/_meta.lua" >&2; exit 2; }

# 1. Version in _meta.lua
sed -i '' -E "s/(version = \")[0-9.]+(\")/\1$VERSION\2/" "$META"
grep -q "version = \"$VERSION\"" "$META" || { echo "couldn't set the version in $META" >&2; exit 1; }
echo "✓ $DIR/_meta.lua → $VERSION"

# 2. Zip (only files git knows about, so no stray local files ship) + checksum
mkdir -p "$DIST"
rm -f "$ZIP" "$SUM"
cd "$ROOT"
git ls-files -co --exclude-standard "$DIR" | grep -v '/\.DS_Store$' | zip -q -X "$ZIP" -@
( cd "$DIST" && shasum -a 256 "$DIR.zip" > "$DIR.zip.sha256" )
echo "✓ $(basename "$ZIP") ($(du -h "$ZIP" | cut -f1)), sha256 $(cut -c1-12 "$SUM")…"
unzip -l "$ZIP" | grep -q "$DIR/_meta.lua" || { echo "zip is missing _meta.lua" >&2; exit 1; }

if [ "$PUBLISH" -ne 1 ]; then
    echo "Dry run. To publish: commit + push the version bump, then"
    echo "  tools/release.sh $PLUGIN $VERSION ${NOTES:+$NOTES }--publish"
    exit 0
fi

# 3. Publish: the bump must be committed and on GitHub, and the tag new.
if ! git diff --quiet -- "$DIR" || ! git diff --cached --quiet -- "$DIR"; then
    echo "commit the changes in $DIR first" >&2; exit 1
fi
git fetch -q origin
if [ -z "$(git branch -r --contains HEAD)" ]; then
    echo "push this commit to GitHub first" >&2; exit 1
fi
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "release $TAG already exists" >&2; exit 1
fi
NAME="$(sed -n 's/.*fullname = _("\(.*\)"),/\1/p' "$META")"
set -- "$TAG" "$ZIP" "$SUM" -R "$REPO" --target "$(git rev-parse HEAD)" --title "${NAME:-$PLUGIN} v$VERSION"
if [ -n "$NOTES" ]; then set -- "$@" --notes-file "$NOTES"; else set -- "$@" --notes "${NAME:-$PLUGIN} v$VERSION"; fi
gh release create "$@"
echo "✓ published $TAG"
