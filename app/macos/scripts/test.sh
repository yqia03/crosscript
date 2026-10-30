#!/bin/bash
set -euo pipefail
APP_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_EXECUTABLE="$(xcrun --find swift)"
TOOLCHAIN_ROOT="$(cd "$(dirname "$SWIFT_EXECUTABLE")/.." && pwd)"
TEST_FLAGS=(--package-path "$APP_PROJECT_ROOT" --arch arm64 --disable-xctest)
# Some Command Line Tools releases ship Testing's macro plugin separately
# without adding it to Swift Build's default plugin discovery paths.
for TEST_MACRO_LIBRARY in "$TOOLCHAIN_ROOT/lib/swift/host/plugins/testing/libTestingMacros.dylib" "$TOOLCHAIN_ROOT/lib/swift/host/plugins/libTestingMacros.dylib"; do
    if [[ -f "$TEST_MACRO_LIBRARY" ]]; then
        TEST_FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TEST_MACRO_LIBRARY")
        break
    fi
done
exec "$SWIFT_EXECUTABLE" test "${TEST_FLAGS[@]}" "$@"
