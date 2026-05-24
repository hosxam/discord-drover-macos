#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Discord Drover.app"
ARCHIVE="$ROOT/build/Discord-Drover-macOS.zip"

if [[ ! -d "$APP" ]]; then
    bash "$ROOT/Scripts/build-app.sh"
fi

rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
echo "Packaged $ARCHIVE"

