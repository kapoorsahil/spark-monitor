#!/usr/bin/env bash
# Build SparkMonitor.app — a double-clickable macOS menu bar app bundle.
#
#   ./make-app.sh            build SparkMonitor.app in this folder
#   ./make-app.sh --install  also copy it to /Applications and launch it
#
set -euo pipefail
cd "$(dirname "$0")"

echo "Building release binary..."
swift build -c release

APP="SparkMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SparkMonitor "$APP/Contents/MacOS/SparkMonitor"
cp Info.plist "$APP/Contents/Info.plist"
# Local build run by its author isn't quarantined, but strip just in case.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/SparkMonitor.app"
    # Quit any running copy so the file isn't busy.
    osascript -e 'tell application "SparkMonitor" to quit' 2>/dev/null || true
    pkill -f "/Applications/SparkMonitor.app/Contents/MacOS/SparkMonitor" 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed to $DEST and launched."
    echo "To start it automatically at login: System Settings > General > Login Items > +  ->  /Applications/SparkMonitor.app"
else
    echo "Next: drag SparkMonitor.app to /Applications (or re-run with --install)."
    echo "Add it under System Settings > General > Login Items to start at login."
fi
