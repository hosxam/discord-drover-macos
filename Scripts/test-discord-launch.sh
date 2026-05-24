#!/bin/bash
set -euo pipefail

SHIM="${1:?Usage: Scripts/test-discord-launch.sh /path/to/libdrover.dylib}"
TEMP_ROOT="$(mktemp -d)"
DMG="$TEMP_ROOT/Discord.dmg"
MOUNT="$TEMP_ROOT/mount"
DISCORD="$TEMP_ROOT/Discord.app"
CONFIG="$TEMP_ROOT/config"
LOG="$TEMP_ROOT/discord.log"
PID=""
MOUNTED=0

cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    if [[ "$MOUNTED" -eq 1 ]]; then
        hdiutil detach "$MOUNT" -quiet || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$MOUNT" "$CONFIG" "$TEMP_ROOT/home"
echo "Downloading official Discord for launch smoke test..."
curl --fail --location --silent --show-error \
    "https://discord.com/api/download?platform=osx&format=dmg" \
    --output "$DMG"
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
MOUNTED=1

ditto "$MOUNT/Discord.app" "$DISCORD"
hdiutil detach "$MOUNT" -quiet
MOUNTED=0

codesign --force --deep --sign - --timestamp=none "$DISCORD"
xattr -dr com.apple.quarantine "$DISCORD" 2>/dev/null || true
printf '[drover]\nproxy = \n' > "$CONFIG/drover.ini"

echo "Launching prepared official Discord with the Drover shim..."
env HOME="$TEMP_ROOT/home" DROVER_CONFIG_DIR="$CONFIG" DYLD_INSERT_LIBRARIES="$SHIM" \
    "$DISCORD/Contents/MacOS/Discord" > "$LOG" 2>&1 &
PID=$!
sleep 8

if ! kill -0 "$PID" 2>/dev/null; then
    details="$(tail -c 1000 "$LOG" | tr '\n' ' ' | sed 's/::/--/g')"
    echo "::error title=Discord startup smoke test failed::Prepared Discord exited before opening. $details"
    exit 1
fi

echo "Prepared official Discord stayed running with the Drover shim."

