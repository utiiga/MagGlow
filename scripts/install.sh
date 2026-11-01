#!/bin/bash
# MagGlow one-line installer:
#
#   curl -fsSL https://raw.githubusercontent.com/utiiga/MagGlow/main/scripts/install.sh | bash
#
# Downloads the latest release into /Applications, installs the helper
# daemon (asks for your password once) and opens the app. curl doesn't set
# the quarantine attribute browsers do, so there's no Gatekeeper dialog.
set -euo pipefail

ZIP_URL="https://github.com/utiiga/MagGlow/releases/latest/download/MagGlow.zip"
DEST="/Applications/MagGlow.app"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Descargando MagGlow…"
curl -fsSL "$ZIP_URL" -o "$TMP/MagGlow.zip"
ditto -xk "$TMP/MagGlow.zip" "$TMP/unpacked"
APP="$TMP/unpacked/MagGlow.app"
if [ ! -d "$APP" ]; then
    echo "error: MagGlow.app no está en el archivo descargado" >&2
    exit 1
fi

osascript -e 'tell application "MagGlow" to quit' >/dev/null 2>&1 || true
pkill -x MagGlow 2>/dev/null || true

echo "Instalando en /Applications (te pedirá tu contraseña de administrador)…"
sudo rm -rf "$DEST"
sudo ditto "$APP" "$DEST"
sudo "$DEST/Contents/Resources/install-helper.sh" "$(id -un)"

open "$DEST"
echo "Listo: busca el icono del conector MagSafe en la barra de menús."
