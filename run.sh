#!/bin/sh
# ponytail: build + launch + screenshot. Add UI automation when tapping is needed.
set -e
xcodebuild -scheme spectra-app -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/dd build -quiet
APP=/tmp/dd/Build/Products/Debug-iphonesimulator/spectra-app.app
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
sleep 3
xcrun simctl io booted screenshot "${1:-/tmp/shot.png}"
