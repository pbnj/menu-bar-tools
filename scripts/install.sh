#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"
mkdir -p "$HOME/Applications"
for NAME in GitHubAttention ClaudeStatus; do
  DEST="$HOME/Applications/$NAME.app"
  if [ -e "$DEST" ]; then
    ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")"
    if [ "$ID" != "local.menubartools.$NAME" ]; then
      printf 'Refusing to overwrite an unrelated app: %s\n' "$DEST" >&2
      exit 1
    fi
  fi
  ditto "$ROOT/dist/$NAME.app" "$DEST"
done
python3 "$ROOT/Adapters/install_integrations.py" install
open "$HOME/Applications/GitHubAttention.app"
open "$HOME/Applications/ClaudeStatus.app"
printf 'Installed and opened both apps in %s/Applications.\n' "$HOME"
