#!/bin/bash
# Builds InvoiceGen.app — a self-contained, offline macOS app bundle.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/InvoiceGen.app"

echo "==> Compiling (release)"
swift build -c release

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/InvoiceGen" "$APP/Contents/MacOS/InvoiceGen"

echo "==> Building icon"
WORK="$(mktemp -d)"
swiftc -O "$ROOT/Tools/MakeIcon.swift" -o "$WORK/makeicon"
"$WORK/makeicon" "$WORK" >/dev/null
iconutil -c icns "$WORK/InvoiceGen.iconset" -o "$APP/Contents/Resources/InvoiceGen.icns"
rm -rf "$WORK"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.business</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Local, offline invoicing.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (ad-hoc signing skipped)"

echo "==> Done: $APP"
echo "    Install with:  cp -R \"$APP\" /Applications/"
