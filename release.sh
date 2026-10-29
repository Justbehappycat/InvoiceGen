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
# ship one too rather than publishing a release nobody can install. Testing the
# requirement directly beats grepping codesign's prose -- `codesign -dv` does
# not even print Authority lines below verbosity 2, which made the first
# version of this check reject every good build. This is the same requirement
# the updater evaluates, so the two cannot disagree.
DEVELOPER_ID_REQUIREMENT='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */'
if ! codesign --verify --strict -R "=$DEVELOPER_ID_REQUIREMENT" "$APP" 2>/dev/null; then
    echo "error: $APP is not Developer ID signed — the updater would reject it." >&2
    echo "       signed as:$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=/ /p' | head -1)" >&2
    exit 1
fi

ZIP="$ROOT/build/InvoiceGen-$VERSION.zip"
package() {
    rm -f "$ZIP"
    # ditto, not zip: it keeps the extended attributes carrying the signature.
    ditto -c -k --keepParent "$APP" "$ZIP"
}

echo "==> Packaging"
package

# Notarization. Developer ID signing alone is NOT enough: the moment a browser
# download puts a quarantine flag on the file, Gatekeeper asks Apple whether
# the app was notarized, and an unnotarized app is refused outright with
# "Apple could not verify ... is free of malware". Stapling attaches the
# ticket so the check also works offline.
NOTARY_PROFILE="${NOTARY_PROFILE:-InvoiceGen}"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> Skipping notarization (SKIP_NOTARIZE=1)"
    echo "    Other Macs WILL refuse to open this build after downloading it."
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no notarytool profile named '$NOTARY_PROFILE'." >&2
    echo "       Create one with your Apple ID and an app-specific password:" >&2
    echo "         xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
    echo "           --apple-id <your-apple-id> --team-id T7R6S9637T" >&2
    echo "       Or set SKIP_NOTARIZE=1 to publish anyway -- but other Macs" >&2
    echo "       will refuse to open the download." >&2
    exit 1
else
    echo "==> Notarizing (this usually takes a few minutes)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "==> Stapling the ticket to the app"
    xcrun stapler staple "$APP"

    # Stapling modifies the bundle, so the zip made before it has no ticket.
    echo "==> Repackaging with the ticket attached"
    package
fi

echo "==> Checking the packaged copy still verifies"
VERIFY="$(mktemp -d)"
ditto -x -k "$ZIP" "$VERIFY"
codesign --verify --strict --deep "$VERIFY/InvoiceGen.app"
echo "    signature round-trips through the zip intact"

# The real test: would a Mac that just downloaded this actually open it?
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    if spctl -a -vv -t exec "$VERIFY/InvoiceGen.app" 2>&1 | grep -q "source=Notarized Developer ID"; then
        echo "    Gatekeeper: accepted, Notarized Developer ID"
    else
        echo "error: the packaged app is not accepted by Gatekeeper:" >&2
        spctl -a -vv -t exec "$VERIFY/InvoiceGen.app" 2>&1 | sed "s/^/       /" >&2
        rm -rf "$VERIFY"
        exit 1
    fi
fi
rm -rf "$VERIFY"

# The landing page prints the version and size next to its download button,
# and the download URL carries the filename. All three go stale the moment a
# new version ships, so rewrite them here rather than trusting anyone to
# remember. Markers in the HTML (data-version, data-size, data-download) make
# this a targeted edit instead of a guess at prose.
PAGE="$ROOT/web/site/public/index.html"
if [ -f "$PAGE" ]; then
    echo "==> Updating the landing page"
    SIZE_MB="$(python3 -c "import os;print(f'{os.path.getsize(\"$ZIP\")/1048576:.1f}')")"
    python3 - "$PAGE" "$VERSION" "$SIZE_MB" "$(basename "$ZIP")" <<'PYEOF'
import re, sys
path, version, size, filename = sys.argv[1:5]
with open(path) as f:
    html = f.read()
before = html
html = re.sub(r'(<span data-version>)[^<]*(</span>)', rf'\g<1>{version}\g<2>', html)
html = re.sub(r'(<span data-size>)[^<]*(</span>)', rf'\g<1>{size}&nbsp;MB\g<2>', html)
html = re.sub(r'(data-download href="https://github\.com/[^"]*/releases/latest/download/)[^"]*(")',
              rf'\g<1>{filename}\g<2>', html)
if html != before:
    with open(path, 'w') as f:
        f.write(html)
    print(f"    version {version}, {size} MB, {filename}")
else:
    print("    already current")
PYEOF
    if [ -n "$(git status --porcelain "$PAGE")" ]; then
        git add "$PAGE"
        git commit -q -m "Landing page: version $VERSION"
    fi
fi

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
