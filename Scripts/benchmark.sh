#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
swiftc -O -I "$BIN_DIR/Modules" -I "$BIN_DIR/CSQLite.build" \
    Scripts/Performance/main.swift "$BIN_DIR"/KeyDropCore.build/*.o \
    "$BIN_DIR"/CSQLite.build/*.o -o "$BIN_DIR/KeyDropBenchmark"
"$BIN_DIR/KeyDropBenchmark"
