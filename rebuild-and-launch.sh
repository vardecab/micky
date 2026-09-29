#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if pgrep -x Micky >/dev/null 2>&1 || pgrep -x MicMeter >/dev/null 2>&1; then
    osascript -e 'tell application id "com.vaultomix.Micky" to quit' >/dev/null 2>&1 || true
    osascript -e 'tell application id "com.vaultomix.MicMeter" to quit' >/dev/null 2>&1 || true

    for _ in {1..20}; do
        if ! pgrep -x Micky >/dev/null 2>&1 && ! pgrep -x MicMeter >/dev/null 2>&1; then
            break
        fi
        sleep 0.25
    done

    if pgrep -x Micky >/dev/null 2>&1 || pgrep -x MicMeter >/dev/null 2>&1; then
        echo "Micky did not quit; close it and run this script again." >&2
        exit 1
    fi
fi

"$ROOT/build-app.sh"
open -n "$ROOT/build/Micky.app"
