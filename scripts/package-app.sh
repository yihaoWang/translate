#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/MacLiveTranslator.app"
EXECUTABLE="$ROOT_DIR/.build/arm64-apple-macosx/debug/MacLiveTranslator"

swift build

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/translate_zt.py" "$APP_DIR/Contents/Resources/translate_zt.py"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/MacLiveTranslator"
chmod +x "$APP_DIR/Contents/MacOS/MacLiveTranslator"

echo "$APP_DIR"
