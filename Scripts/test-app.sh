#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN_DIR="$(swift build --show-bin-path)"
swiftc -swift-version 5 -I "$BIN_DIR/Modules" -I "$BIN_DIR/CSQLite.build" \
    Sources/KeyDrop/AppDelegate.swift Sources/KeyDrop/UI.swift \
    Sources/KeyDrop/MainWindow.swift Sources/KeyDrop/Updater.swift \
    Scripts/AppRegression/main.swift \
    "$BIN_DIR"/KeyDropCore.build/*.swift.o "$BIN_DIR"/CSQLite.build/*.o \
    -o "$BIN_DIR/KeyDropAppRegression"
"$BIN_DIR/KeyDropAppRegression"
