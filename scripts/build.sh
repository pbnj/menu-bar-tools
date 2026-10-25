#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" -c release
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
mkdir -p "$ROOT/dist"
for NAME in GitHubAttention ClaudeStatus; do
  APP="$ROOT/dist/$NAME.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Adapters"
  cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"
  cp "$ROOT/Adapters/agent_bridge.py" "$ROOT/Adapters/install_integrations.py" \
    "$ROOT/Adapters/pi-extension.js" "$APP/Contents/Resources/Adapters/"
  PLIST="$APP/Contents/Info.plist"
  if [ ! -e "$PLIST" ]; then plutil -create xml1 "$PLIST"; fi
  for KEY in CFBundleExecutable CFBundleIdentifier CFBundleName CFBundlePackageType \
    CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion LSUIElement NSHighResolutionCapable; do
    plutil -remove "$KEY" "$PLIST" 2>/dev/null || true
  done
  plutil -insert CFBundleExecutable -string "$NAME" "$PLIST"
  plutil -insert CFBundleIdentifier -string "local.menubartools.$NAME" "$PLIST"
  plutil -insert CFBundleName -string "$NAME" "$PLIST"
  plutil -insert CFBundlePackageType -string APPL "$PLIST"
  plutil -insert CFBundleShortVersionString -string "0.1.0" "$PLIST"
  plutil -insert CFBundleVersion -string "1" "$PLIST"
  plutil -insert LSMinimumSystemVersion -string "13.0" "$PLIST"
  plutil -insert LSUIElement -bool true "$PLIST"
  plutil -insert NSHighResolutionCapable -bool true "$PLIST"
  codesign --force --sign "${SIGNING_IDENTITY:--}" "$APP"
done
printf 'Built %s/dist/GitHubAttention.app and ClaudeStatus.app\n' "$ROOT"
