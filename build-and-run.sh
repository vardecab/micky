#!/bin/bash
set -euo pipefail

# Standalone macOS build, app-bundle packaging, and launch script.
# This uses Swift Package Manager directly and does not call build-app.sh or
# rebuild-and-launch.sh.

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/build-logging.sh"
source "$ROOT/package-app-icon.sh"
BUILD_ROOT="$ROOT/.build/micky-direct"
SWIFT_BUILD_ROOT="$BUILD_ROOT/SwiftPM"
STAGED_APP="$BUILD_ROOT/Micky.app"
APP="$ROOT/build/Micky.app"
INSTALL_APP="/Applications/Micky.app"
EXECUTABLE="$STAGED_APP/Contents/MacOS/Micky"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This script must run on macOS with Xcode Command Line Tools installed." >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun was not found. Install Xcode Command Line Tools, then try again." >&2
    exit 1
fi

SWIFT="$(xcrun --find swift)"
mkdir -p "$BUILD_ROOT" "$ROOT/build"
BIN_DIR="$("$SWIFT" build --package-path "$ROOT" --configuration release --build-path "$SWIFT_BUILD_ROOT" --show-bin-path)"

echo "Compiling Micky with Swift Package Manager…"
"$SWIFT" build \
    --package-path "$ROOT" \
    --configuration release \
    --build-path "$SWIFT_BUILD_ROOT"

rm -rf "$STAGED_APP"
mkdir -p "$STAGED_APP/Contents/MacOS" \
         "$STAGED_APP/Contents/Resources/Fonts" \
         "$STAGED_APP/Contents/Resources/icons"
cp "$BIN_DIR/Micky" "$EXECUTABLE"

cp "$ROOT/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT/Fonts/SplineSansMono-Regular.ttf" \
   "$ROOT/Fonts/SplineSansMono-SemiBold.ttf" \
   "$ROOT/Fonts/OFL-SplineSansMono.txt" \
   "$STAGED_APP/Contents/Resources/Fonts/"
cp "$ROOT/icons/mic-on.png" "$ROOT/icons/mic-off.png" \
   "$STAGED_APP/Contents/Resources/icons/"
package_app_icon "$STAGED_APP/Contents/Resources"

codesign --force --deep --sign - "$STAGED_APP"

# Close the old copy only after the replacement has compiled and signed.
osascript -e 'tell application id "com.vaultomix.Micky" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "com.vaultomix.MicMeter" to quit' >/dev/null 2>&1 || true
for _ in {1..40}; do
    if ! pgrep -x Micky >/dev/null 2>&1 && ! pgrep -x MicMeter >/dev/null 2>&1; then
        break
    fi
    sleep 0.25
done
if pgrep -x Micky >/dev/null 2>&1 || pgrep -x MicMeter >/dev/null 2>&1; then
    echo "Micky is still running. Quit it, then run this script again." >&2
    exit 1
fi

rm -rf "$APP"
/usr/bin/ditto "$STAGED_APP" "$APP"

if [[ -w /Applications ]]; then
    rm -rf "$INSTALL_APP"
    /usr/bin/ditto "$APP" "$INSTALL_APP"
else
    osascript -e 'on run argv
        set sourcePath to quoted form of (POSIX path of (item 1 of argv))
        set destinationPath to quoted form of "/Applications/Micky.app"
        do shell script "/bin/rm -rf " & destinationPath & " && /usr/bin/ditto " & sourcePath & " " & destinationPath with administrator privileges
    end run' "$APP"
fi

open -g -n "$INSTALL_APP"
echo "Built $APP, installed $INSTALL_APP, and launched it."
