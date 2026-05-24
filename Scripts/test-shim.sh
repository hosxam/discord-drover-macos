#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM="${1:?Usage: Scripts/test-shim.sh /path/to/libdrover.dylib}"
TEMP_ROOT="$(mktemp -d)"
HARNESS="$TEMP_ROOT/shim-harness"
CONFIG="$TEMP_ROOT/config"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$CONFIG"
clang -std=c11 -Wall -Wextra -Werror \
    "$ROOT/Tests/ShimHarness/main.c" -o "$HARNESS" -lpthread

printf '[drover]\nproxy = \n' > "$CONFIG/drover.ini"
printf 'packet-test' > "$CONFIG/drover-packet.bin"
echo "Testing Direct-mode UDP injection..."
DROVER_CONFIG_DIR="$CONFIG" DYLD_INSERT_LIBRARIES="$SHIM" "$HARNESS" udp

rm -f "$CONFIG/drover-packet.bin"
printf '[drover]\nproxy = http://user:pass@127.0.0.1:8080\n' > "$CONFIG/drover.ini"
echo "Testing HTTP proxy authentication injection..."
DROVER_CONFIG_DIR="$CONFIG" DYLD_INSERT_LIBRARIES="$SHIM" "$HARNESS" http

printf '[drover]\nproxy = socks5://127.0.0.1:1080\n' > "$CONFIG/drover.ini"
echo "Testing SOCKS5 CONNECT translation..."
DROVER_CONFIG_DIR="$CONFIG" DYLD_INSERT_LIBRARIES="$SHIM" "$HARNESS" socks5

echo "Drover shim integration tests passed."
