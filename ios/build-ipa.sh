#!/bin/bash
# Builds Pane.ipa (ad-hoc signed; Sideloadly re-signs it with your Apple ID). Runs on the GitHub macOS runner.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/Payload/Pane.app
APP=build/Payload/Pane.app
xcrun -sdk iphoneos swiftc -target arm64-apple-ios16.0 -O -wmo -parse-as-library -module-name Pane \
  Sources/*.swift -o "$APP/Pane"
cp Info.plist "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
if xcrun actool Assets.xcassets --compile "$APP" --platform iphoneos --minimum-deployment-target 16.0 \
     --app-icon AppIcon --target-device ipad --target-device iphone \
     --output-partial-info-plist build/icon.plist --output-format human-readable-text; then
  /usr/libexec/PlistBuddy -c "Merge build/icon.plist" "$APP/Info.plist" || true
else
  echo "icon compile skipped"
fi
plutil -convert binary1 "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
codesign --force --sign - --timestamp=none "$APP"          # ad-hoc signature: a complete, valid bundle for sideloading tools
codesign --verify --verbose "$APP"
(cd build && rm -f Pane.ipa && /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload Pane.ipa)
unzip -l build/Pane.ipa | head -20
ls -la build/Pane.ipa
