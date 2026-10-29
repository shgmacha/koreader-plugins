#!/bin/sh
# Publishes a Goodreads Sync release that the in-app updater can install.
#   tools/release_reads.sh "What's new (one line or more)"
# Packs exactly what's committed in goodreadssync.koplugin/ (git archive), adds its SHA-256,
# and creates the GitHub release "goodreadssync-vX.Y.Z" (version from _meta.lua).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/.*version = "\([0-9.]*\)".*/\1/p' goodreadssync.koplugin/_meta.lua)"
TAG="goodreadssync-v$VERSION"
[ -n "$VERSION" ] || { echo "No version in _meta.lua"; exit 1; }
git diff --quiet HEAD -- goodreadssync.koplugin || { echo "Commit goodreadssync.koplugin first"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then echo "$TAG already exists"; exit 1; fi

OUT="${TMPDIR:-/tmp}/goodreadssync-release"
rm -rf "$OUT" && mkdir -p "$OUT"
git archive --format=zip -o "$OUT/goodreadssync.koplugin.zip" HEAD goodreadssync.koplugin
(cd "$OUT" && shasum -a 256 goodreadssync.koplugin.zip > goodreadssync.koplugin.zip.sha256)

gh release create "$TAG" "$OUT/goodreadssync.koplugin.zip" "$OUT/goodreadssync.koplugin.zip.sha256" \
    --title "Goodreads Sync v$VERSION" --notes "${1:-Goodreads Sync v$VERSION}"
echo "Published $TAG"
