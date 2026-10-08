#!/bin/sh
# Publishes a Blossom Reads release that the in-app updater can install.
#   tools/release_reads.sh "What's new (one line or more)"
# Packs exactly what's committed in blossomreads.koplugin/ (git archive), adds its SHA-256,
# and creates the GitHub release "blossomreads-vX.Y.Z" (version from _meta.lua).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/.*version = "\([0-9.]*\)".*/\1/p' blossomreads.koplugin/_meta.lua)"
TAG="blossomreads-v$VERSION"
[ -n "$VERSION" ] || { echo "No version in _meta.lua"; exit 1; }
git diff --quiet HEAD -- blossomreads.koplugin || { echo "Commit blossomreads.koplugin first"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then echo "$TAG already exists"; exit 1; fi

OUT="${TMPDIR:-/tmp}/blossomreads-release"
rm -rf "$OUT" && mkdir -p "$OUT"
git archive --format=zip -o "$OUT/blossomreads.koplugin.zip" HEAD blossomreads.koplugin
(cd "$OUT" && shasum -a 256 blossomreads.koplugin.zip > blossomreads.koplugin.zip.sha256)

gh release create "$TAG" "$OUT/blossomreads.koplugin.zip" "$OUT/blossomreads.koplugin.zip.sha256" \
    --title "Blossom Reads v$VERSION" --notes "${1:-Blossom Reads v$VERSION}"
echo "Published $TAG"
