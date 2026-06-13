#!/usr/bin/env bash
# One-shot setup: build, install, register as login item, bake config.
# Re-run any time to change the host.
set -euo pipefail
cd "$(dirname "$0")"

APP=SparkMonitor.app
DEST=/Applications/$APP
PB=/usr/libexec/PlistBuddy

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode command line tools are required. Install with:"
    echo "  xcode-select --install"
    exit 1
fi

default_host="${SPARK_HOST:-nvidia-dgx-spark}"
read -rp "SSH host to monitor [$default_host]: " host
host="${host:-$default_host}"

if ! ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" true 2>/dev/null; then
    echo
    echo "Heads up: ssh '$host' didn't connect non-interactively. The app needs"
    echo "passwordless SSH (key auth, no password prompt) to work."
    read -rp "Continue setup anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy] ]] || exit 1
fi

echo
echo "Building..."
./make-app.sh

PLIST=$APP/Contents/Info.plist
"$PB" -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null || true
"$PB" -c "Add :LSEnvironment dict" "$PLIST"
"$PB" -c "Add :LSEnvironment:SPARK_HOST string $host" "$PLIST"

echo "Installing to /Applications..."
osascript -e 'tell application "SparkMonitor" to quit' 2>/dev/null || true
pkill -f "$DEST/Contents/MacOS/SparkMonitor" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "Registering as a login item..."
osascript >/dev/null <<EOF || echo "(skipped: System Events permission denied; add it manually under System Settings > General > Login Items)"
tell application "System Events"
    if not (exists login item "SparkMonitor") then
        make new login item at end with properties {path:"$DEST", hidden:false}
    end if
end tell
EOF

open "$DEST"

echo
echo "Done. Look for the bolt icon in your menu bar."
echo "To change the host later, re-run ./setup.sh."
