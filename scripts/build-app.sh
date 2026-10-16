#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${1:-release}
cd "$ROOT"
TOOLCHAIN=$(dirname "$(dirname "$(xcrun --find swiftc)")")
PROTOCOLS="$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json"
swift build --configuration "$CONFIGURATION" --scratch-path "$ROOT/.build" -Xswiftc -emit-const-values -Xswiftc -const-gather-protocols-list -Xswiftc "$PROTOCOLS"
BIN=$(swift build --configuration "$CONFIGURATION" --scratch-path "$ROOT/.build" --show-bin-path)
APP=${PASTEBOARD_APP_OUTPUT:-"$ROOT/dist/Pasteboard.app"}
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Pasteboard" "$APP/Contents/MacOS/Pasteboard"
cp "$BIN/PasteboardMCP" "$APP/Contents/MacOS/PasteboardMCP"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PreviewSample.txt" "$APP/Contents/Resources/PreviewSample.txt"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/Resources/Icon/Lucide-LICENSE.txt" "$APP/Contents/Resources/Licenses/Lucide-LICENSE.txt"
ICONSET="$ROOT/dist/Pasteboard.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/Pasteboard.icns"
python3 "$ROOT/scripts/extract-appintents.py" "$CONFIGURATION" "$APP/Contents/Resources"
codesign --force --sign - "$APP/Contents/MacOS/PasteboardMCP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
