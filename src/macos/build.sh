#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$ROOT/../.." && pwd)"
APP="$PROJECT/dist/DSHWidget.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

swiftc \
  -O \
  -swift-version 5 \
  -parse-as-library \
  -target "${ARCH}-apple-macosx14.0" \
  -framework SwiftUI \
  -framework AppKit \
  "$ROOT/DSHWidget/Models.swift" \
  "$ROOT/DSHWidget/WidgetLog.swift" \
  "$ROOT/DSHWidget/Transcript.swift" \
  "$ROOT/DSHWidget/BridgeClient.swift" \
  "$ROOT/DSHWidget/WidgetModel.swift" \
  "$ROOT/DSHWidget/MarkdownText.swift" \
  "$ROOT/DSHWidget/ContentView.swift" \
  "$ROOT/DSHWidget/ComposerKey.swift" \
  "$ROOT/DSHWidget/ComposerKeys.swift" \
  "$ROOT/DSHWidget/ComposerEditor.swift" \
  "$ROOT/DSHWidget/DSHWidgetApp.swift" \
  -o "$APP/Contents/MacOS/DSHWidget"

chmod +x "$APP/Contents/MacOS/DSHWidget"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
