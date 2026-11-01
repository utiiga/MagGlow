#!/bin/bash
# Removes MagGlow completely and gives the LED and sleep back to macOS.
# Usage: sudo /Applications/MagGlow.app/Contents/Resources/uninstall.sh
set -uo pipefail

LABEL="com.magglow.helper"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: run with sudo" >&2
    exit 1
fi

osascript -e 'tell application "MagGlow" to quit' >/dev/null 2>&1
pkill -x MagGlow 2>/dev/null

# Stopping the daemon already resets the LED and re-enables sleep; do it
# explicitly too in case it wasn't running.
launchctl bootout "system/$LABEL" 2>/dev/null
[ -x "/Library/PrivilegedHelperTools/$LABEL" ] && "/Library/PrivilegedHelperTools/$LABEL" --reset
pmset disablesleep 0

rm -f "/Library/PrivilegedHelperTools/$LABEL" "/Library/LaunchDaemons/$LABEL.plist"
rm -rf "/Library/Application Support/MagGlow" /Library/Logs/MagGlow /Applications/MagGlow.app
echo "MagGlow uninstalled."
