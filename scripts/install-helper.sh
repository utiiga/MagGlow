#!/bin/bash
# Installs the MagGlow root helper as a launchd daemon. It ships inside the
# app bundle (Contents/Resources) next to the helper binary and its plist.
# Usage: sudo /Applications/MagGlow.app/Contents/Resources/install-helper.sh <user>
set -euo pipefail

OWNER="$1"
LABEL="com.magglow.helper"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: run with sudo" >&2
    exit 1
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout returns before the old daemon is fully gone; bootstrapping too
# early fails with "5: Input/output error".
for _ in $(seq 1 50); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
done

install -d -m 755 /Library/PrivilegedHelperTools /Library/Logs/MagGlow
install -m 755 -o root -g wheel "$HERE/MagGlowHelper" "/Library/PrivilegedHelperTools/$LABEL"
install -m 644 -o root -g wheel "$HERE/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"

# The menu bar app runs as $OWNER and writes its requests here.
install -d -m 755 -o "$OWNER" -g staff "/Library/Application Support/MagGlow"

launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"
echo "MagGlow helper installed and running."
