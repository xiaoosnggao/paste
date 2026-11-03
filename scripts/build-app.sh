#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${1:-release}
cd "$ROOT"
TOOLCHAIN=$(dirname "$(dirname "$(xcrun --find swiftc)")")
PROTOCOLS_SOURCE="$TOOLCHAIN/share/swift/SwiftConstantValues/AppIntents.json"
PROTOCOLS="$ROOT/.build/AppIntents-protocols.json"
mkdir -p "$ROOT/.build"
# The compiler expects an array; recent SDKs wrap it in constValueProtocols.
python3 - "$PROTOCOLS_SOURCE" "$PROTOCOLS" <<'PY_PROTOCOLS'
import json
import sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text())
if isinstance(value, dict):
    value = value['constValueProtocols']
if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
    raise SystemExit('Invalid App Intents protocol list in the selected toolchain.')
Path(sys.argv[2]).write_text(json.dumps(value))
PY_PROTOCOLS
# The protocol list is a frontend-only option; the driver rejects it unless
# it is forwarded with -Xfrontend.
swift build --configuration "$CONFIGURATION" --scratch-path "$ROOT/.build" -Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PROTOCOLS"
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
python3 "$ROOT/scripts/extract-appintents.py" "$CONFIGURATION" "$APP/Contents/Resources" "$BIN"
# Keep one certificate identity across updates so macOS can retain privacy grants.
# Ad-hoc builds have a content-hash identity and cannot promise retained grants.
SIGNING_IDENTITY=${PASTEBOARD_SIGNING_IDENTITY:-}
if [ -z "$SIGNING_IDENTITY" ] && [ -f "$ROOT/.signing-identity" ]; then
    SIGNING_IDENTITY=$(cat "$ROOT/.signing-identity")
fi
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
if [ "$SIGNING_IDENTITY" = "-" ]; then
    printf '%s\n' 'Warning: ad-hoc signature; macOS privacy permissions may require renewal after an update.' >&2
fi
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP/Contents/MacOS/PasteboardMCP"
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/PasteboardMCP"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
