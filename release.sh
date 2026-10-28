#!/bin/bash
# Cuts a release: builds, signs, zips, tags, and publishes to GitHub Releases.
# The app's updater reads exactly what this produces.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty. Commit first — the build stamps the commit hash." >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists. Bump VERSION first." >&2
    exit 1
fi

./build.sh

APP="$ROOT/build/InvoiceGen.app"

# The updater refuses anything not signed by our Developer ID, so refuse to
# ship one too rather than publishing a release nobody can install.
if ! codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "error: $APP is not Developer ID signed — the updater would reject it." >&2
    exit 1
fi

echo "==> Packaging"
ZIP="$ROOT/build/InvoiceGen-$VERSION.zip"
rm -f "$ZIP"
# ditto, not zip: it keeps the extended attributes carrying the signature.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Checking the packaged copy still verifies"
VERIFY="$(mktemp -d)"
ditto -x -k "$ZIP" "$VERIFY"
codesign --verify --strict --deep "$VERIFY/InvoiceGen.app"
rm -rf "$VERIFY"
echo "    round-trips through the zip intact"

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "InvoiceGen $VERSION"
git push origin "$TAG"
git push origin HEAD

echo "==> Publishing the release"
NOTES_FILE="$(mktemp)"
if [ -n "${RELEASE_NOTES:-}" ]; then
    printf '%s\n' "$RELEASE_NOTES" > "$NOTES_FILE"
else
    PREV="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
    if [ -n "$PREV" ]; then
        git log --pretty='- %s' "$PREV..$TAG" > "$NOTES_FILE"
    else
        printf 'First release.\n' > "$NOTES_FILE"
    fi
fi

gh release create "$TAG" "$ZIP" --title "InvoiceGen $VERSION" --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"

echo "==> Released $TAG"
echo "    Other Macs will offer it within a day, or immediately via"
echo "    InvoiceGen ▸ Check for Updates…"
