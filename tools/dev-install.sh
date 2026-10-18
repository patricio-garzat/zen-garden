#!/bin/bash
# Compila Zen Garden (Release, optimizado) y lo instala en el iPhone conectado por cable o Wi-Fi.
# No usa App Store Connect ni TestFlight. Los jardines guardados se conservan entre instalaciones.
# Uso: ./tools/dev-install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /iPhone/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')
[ -n "$DEVICE" ] || { echo "No encontré un iPhone conectado y disponible. Conéctalo, desbloquéalo y confía en esta Mac."; exit 1; }
UDID=$(xcrun devicectl device info details --device "$DEVICE" 2>/dev/null | awk '/udid:/ {print $NF; exit}')
echo "iPhone: $DEVICE ($UDID)"

# Si existe la clave de API del estudio, Xcode puede registrar el bundle id y el iPhone sin abrirse.
AUTH=()
if [ -f "$HOME/.appstoreconnect/cubeswipe.env" ]; then
  source "$HOME/.appstoreconnect/cubeswipe.env"
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

xcodebuild -project ZenGarden.xcodeproj -scheme ZenGarden -configuration Release \
  -destination "id=$UDID" -derivedDataPath build/DerivedData-device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration ${AUTH[@]+"${AUTH[@]}"} \
  build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'

APP=build/DerivedData-device/Build/Products/Release-iphoneos/ZenGarden.app
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E -i 'installed|error' || true
xcrun devicectl device process launch --device "$DEVICE" com.blubergames.zengarden >/dev/null 2>&1 || true
echo "Listo: Zen Garden instalado en tu iPhone."
