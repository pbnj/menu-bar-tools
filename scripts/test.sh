#!/bin/bash
# Usage: scripts/test.sh [swift|python|node]... (default: all suites)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

swift_tests() {
  local swift_bin testing_plugin
  swift_bin="$(xcrun --find swiftc)"
  testing_plugin="$(dirname "$swift_bin")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
  # Some Command Line Tools releases omit this installed plugin from macro discovery.
  if [ -f "$testing_plugin" ]; then
    swift test --package-path "$ROOT" -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin"
  else
    swift test --package-path "$ROOT"
  fi
}

python_tests() { python3 -m unittest discover -s "$ROOT/Tests/Adapters" -p 'test_*.py'; }
node_tests() { node --test "$ROOT/Tests/Adapters/pi-extension.test.mjs"; }

[ $# -gt 0 ] || set -- swift python node
for suite in "$@"; do
  case "$suite" in
    swift) swift_tests ;;
    python) python_tests ;;
    node) node_tests ;;
    *) printf 'Unknown suite: %s (expected swift, python or node)\n' "$suite" >&2; exit 2 ;;
  esac
done
