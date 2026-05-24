#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/build/Discord Drover.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product DiscordDrover
swift build -c "$CONFIGURATION" --product DroverShim
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

SHIM="$BIN_DIR/libDroverShim.dylib"
if [[ ! -f "$SHIM" ]]; then
    echo "Could not locate the built DroverShim dylib at $SHIM" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/DiscordDrover" "$APP/Contents/MacOS/DiscordDrover"
cp "$SHIM" "$APP/Contents/Resources/libdrover.dylib"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP/Contents/Resources/libdrover.dylib"
    codesign --force --deep --sign - "$APP"
else
    codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/libdrover.dylib"
    codesign --force --deep --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP"
fi

bash "$ROOT/Scripts/test-shim.sh" "$APP/Contents/Resources/libdrover.dylib"

echo "Built $APP"
