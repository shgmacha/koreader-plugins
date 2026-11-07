#!/bin/sh
# Publishes a Page Frame release that the in-app updater can install.
#   tools/release_pageframe.sh "What's new (one line or more)"
# Packs exactly what's committed in pageframe.koplugin/ (git archive), adds its SHA-256,
# and creates the GitHub release "pageframe-vX.Y.Z" (version from _meta.lua).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/.*version = "\([0-9.]*\)".*/\1/p' pageframe.koplugin/_meta.lua)"
TAG="pageframe-v$VERSION"
[ -n "$VERSION" ] || { echo "No version in _meta.lua"; exit 1; }
git diff --quiet HEAD -- pageframe.koplugin || { echo "Commit pageframe.koplugin first"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then echo "$TAG already exists"; exit 1; fi

OUT="${TMPDIR:-/tmp}/pageframe-release"
rm -rf "$OUT" && mkdir -p "$OUT"
git archive --format=zip -o "$OUT/pageframe.koplugin.zip" HEAD pageframe.koplugin
(cd "$OUT" && shasum -a 256 pageframe.koplugin.zip > pageframe.koplugin.zip.sha256)

gh release create "$TAG" "$OUT/pageframe.koplugin.zip" "$OUT/pageframe.koplugin.zip.sha256" \
    --title "Page Frame v$VERSION" --notes "${1:-Page Frame v$VERSION}"
echo "Published $TAG"
