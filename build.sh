#!/bin/bash
# Builds InvoiceGen.app — a self-contained, offline macOS app bundle.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/InvoiceGen.app"

# Version: VERSION holds the marketing version; the build number is the commit
# count, so every build is traceable to a commit.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
    COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
    if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then COMMIT="$COMMIT+"; fi
else
    BUILD="0"
    COMMIT="nogit"
fi
echo "==> InvoiceGen $VERSION (build $BUILD, $COMMIT)"

echo "==> Compiling (release)"
swift build -c release

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/InvoiceGen" "$APP/Contents/MacOS/InvoiceGen"

# macOS decides whether an app gets the current design -- Liquid Glass, the
# current window controls, the current control metrics -- from the SDK version
# recorded in LC_BUILD_VERSION, not from the SDK on disk. SwiftPM derives that
# field from the platform in Package.swift, so declaring .macOS(.v13) records
# "sdk 13.0" even though the build used the 27 SDK, and the app is handed the
# legacy appearance.
#
# vtool records the SDK actually used while leaving minos alone, so the app
# still runs on macOS 13. This runs before signing, since it rewrites the
# binary. Harmless if the SDK is older than 26: it just records that instead.
SDK_VERSION="$(xcrun --show-sdk-version --sdk macosx 2>/dev/null || echo '')"
if [ -n "$SDK_VERSION" ]; then
    vtool -set-build-version macos 13.0 "$SDK_VERSION" -replace \
        -output "$APP/Contents/MacOS/InvoiceGen" "$APP/Contents/MacOS/InvoiceGen" 2>/dev/null
    echo "    linked SDK recorded as $SDK_VERSION (minos stays 13.0)"
fi

echo "==> Building icon"
WORK="$(mktemp -d)"
swiftc -O "$ROOT/Tools/MakeIcon.swift" -o "$WORK/makeicon"
"$WORK/makeicon" "$WORK" >/dev/null
iconutil -c icns "$WORK/InvoiceGen.iconset" -o "$APP/Contents/Resources/InvoiceGen.icns"
rm -rf "$WORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>InvoiceGen</string>
    <key>CFBundleDisplayName</key>       <string>InvoiceGen</string>
    <key>CFBundleExecutable</key>        <string>InvoiceGen</string>
    <key>CFBundleIdentifier</key>        <string>com.finecut.invoicegen</string>
    <key>CFBundleIconFile</key>          <string>InvoiceGen</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$BUILD</string>
    <key>InvoiceGenCommit</key>          <string>$COMMIT</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.business</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Local, offline invoicing.</string>
</dict>
</plist>
PLIST

# Signing. The identity matters for more than Gatekeeper: Keychain items are
# access-controlled by the signature's designated requirement, and an ad-hoc
# signature's requirement is the cdhash, which changes on every build. That is
# what orphaned the payment vault once already. Any real certificate gives a
# stable requirement, so prefer one; fall back to ad-hoc so the app still
# builds on a machine with no certificates at all.
#
# Override with:  INVOICEGEN_IDENTITY="Developer ID Application: ..." ./build.sh
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/^ *[0-9]*) [0-9A-F]* \"\(.*$1.*\)\"$/\1/p" \
        | head -1
}

IDENTITY="${INVOICEGEN_IDENTITY:-}"
NOTARIZABLE=no
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(find_identity "Developer ID Application")"
    [ -n "$IDENTITY" ] && NOTARIZABLE=yes
fi
[ -z "$IDENTITY" ] && IDENTITY="$(find_identity "Apple Development")"

if [ -n "$IDENTITY" ]; then
    echo "==> Signing as $IDENTITY"
    # --options runtime: hardened runtime, required for notarization and good
    # hygiene for an app holding an HMAC key and an encrypted vault.
    # --timestamp needs the network and only matters for notarized builds.
    SIGN_ARGS=(--force --options runtime --identifier com.finecut.invoicegen)
    if [ "$NOTARIZABLE" = yes ]; then SIGN_ARGS+=(--timestamp); else SIGN_ARGS+=(--timestamp=none); fi
    # Inside-out, not --deep: --deep is discouraged and mis-signs nested code.
    codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP/Contents/MacOS/InvoiceGen"
    codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP"
else
    echo "==> Signing (ad-hoc — no certificate found)"
    echo "    Warning: the Keychain vault will not survive the next rebuild."
    codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (ad-hoc signing skipped)"
fi

echo "==> Verifying signature"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed "s/^/    /"
# The designated requirement IS the Keychain access rule. Print it so a change
# here is never silent: if this line changes, the vault needs re-entering.
echo "    designated requirement:"
codesign -d -r- "$APP" 2>/dev/null | sed -n "s/^designated => /      /p"

echo "==> Done: $APP"
# Replace, never overwrite in place: cp reuses the existing inodes, and the
# kernel then checks the new bytes against the signature it already cached
# for that vnode, killing the app with "Invalid Page" on first launch.
echo "    Install with:  rm -rf /Applications/InvoiceGen.app && ditto \"$APP\" /Applications/InvoiceGen.app"
