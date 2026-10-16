#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Pasteboard Demo.app"
ditto "$ROOT/dist/Pasteboard.app" "$APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.gaoxs.pasteboard.demo' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Pasteboard Demo' "$APP/Contents/Info.plist"
# Keep the demo out of production deep-link and Shortcuts routing.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$APP/Contents/Info.plist"
rm -rf "$APP/Contents/Resources/Metadata.appintents"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
