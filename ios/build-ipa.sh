#!/bin/bash
# Builds an unsigned Pane.ipa (sign + install with Sideloadly). Runs on macOS with Xcode (GitHub Actions runner).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/Payload/Pane.app
APP=build/Payload/Pane.app
xcrun -sdk iphoneos swiftc -target arm64-apple-ios16.0 -O -wmo -parse-as-library -module-name Pane \
  Sources/*.swift -o "$APP/Pane"
cp Info.plist "$APP/Info.plist"
if xcrun actool Assets.xcassets --compile "$APP" --platform iphoneos --minimum-deployment-target 16.0 \
     --app-icon AppIcon --target-device ipad --target-device iphone \
     --output-partial-info-plist build/icon.plist --output-format human-readable-text; then
  /usr/libexec/PlistBuddy -c "Merge build/icon.plist" "$APP/Info.plist" || true
else
  echo "icon compile skipped"
fi
plutil -lint "$APP/Info.plist"
(cd build && zip -qry Pane.ipa Payload)
ls -la build/Pane.ipa
