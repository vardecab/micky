#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/build-logging.sh"
source "$ROOT/package-app-icon.sh"
APP="$ROOT/build/Micky.app"

BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
swift build --package-path "$ROOT" -c release
rm -rf "$APP" "$ROOT/build/Mic Meter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts" "$APP/Contents/Resources/icons"
cp "$BIN_DIR/Micky" "$APP/Contents/MacOS/Micky"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Fonts/SplineSansMono-Regular.ttf" "$ROOT/Fonts/SplineSansMono-SemiBold.ttf" "$ROOT/Fonts/OFL-SplineSansMono.txt" "$APP/Contents/Resources/Fonts/"
cp "$ROOT/icons/mic-on.png" "$ROOT/icons/mic-off.png" "$APP/Contents/Resources/icons/"
package_app_icon "$APP/Contents/Resources"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
