#!/bin/bash
# Swift Testing only; also handle CLT toolchains whose testing macros live in a subdirectory.
set -euo pipefail
cd "$(dirname "$0")/.."
OPTIONS=(--disable-xctest)
TOOL_BIN="$(dirname "$(xcrun --find swiftc)")"
PLUGIN="$TOOL_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then
  OPTIONS+=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
fi
exec swift test "${OPTIONS[@]}" "$@"
