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

run_test() {
    local label="$1"
    local mode="$2"
    local pid

    echo "Testing $label..."
    env DROVER_CONFIG_DIR="$CONFIG" DYLD_INSERT_LIBRARIES="$SHIM" "$HARNESS" "$mode" &
    pid=$!
    for _ in {1..15}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            if wait "$pid"; then
                return
            fi
            echo "::error title=Shim integration test failed::$label failed. See build output for details."
            exit 1
        fi
        sleep 1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "::error title=Shim integration test timed out::$label timed out after 15 seconds."
    exit 1
}

printf '[drover]\nproxy = \n' > "$CONFIG/drover.ini"
printf 'packet-test' > "$CONFIG/drover-packet.bin"
run_test "Direct-mode UDP injection" udp

rm -f "$CONFIG/drover-packet.bin"
printf '[drover]\nproxy = http://user:pass@127.0.0.1:8080\n' > "$CONFIG/drover.ini"
run_test "HTTP proxy authentication injection" http

printf '[drover]\nproxy = socks5://127.0.0.1:1080\n' > "$CONFIG/drover.ini"
run_test "SOCKS5 CONNECT translation" socks5

echo "Drover shim integration tests passed."
