#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_BIN="$(xcrun --find swiftc)"
TESTING_PLUGIN="$(dirname "$SWIFT_BIN")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
# Some Command Line Tools releases omit this installed plugin from macro discovery.
if [ -f "$TESTING_PLUGIN" ]; then
  swift test --package-path "$ROOT" -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN"
else
  swift test --package-path "$ROOT"
fi
python3 -m unittest discover -s "$ROOT/Tests/Adapters" -p 'test_*.py'
node --test "$ROOT/Tests/Adapters/pi-extension.test.mjs"
