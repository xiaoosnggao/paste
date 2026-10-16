#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
RECEIVER_APP="$PROJECT_ROOT/dist/PasteReceiver.app"
mkdir -p "$RECEIVER_APP/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$PROJECT_ROOT/.build/receiver-module-cache" \
  "$PROJECT_ROOT/scripts/PasteReceiver.swift" -o "$RECEIVER_APP/Contents/MacOS/PasteReceiver"
cat > "$RECEIVER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.pasteboard.acceptance.receiver</string>
<key>CFBundleName</key><string>PasteReceiver</string>
<key>CFBundleExecutable</key><string>PasteReceiver</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$RECEIVER_APP"
codesign --verify --strict "$RECEIVER_APP"
print "Built acceptance fixture: $RECEIVER_APP"
