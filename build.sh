#!/bin/zsh
# Baut Flow.app im Release-Modus nach build/ und signiert sie.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --disable-sandbox
bin="$(swift build -c release --disable-sandbox --show-bin-path)"

app=build/Flow.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Flow" "$app/Contents/MacOS/Flow"
cp Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Feste Identität, damit macOS die Freigabe für Laufwerke über Builds hinweg behält.
identity="${FLOW_SIGN_IDENTITY:-Apple Development: info@wiredframe.de (2H27H4933B)}"
codesign --force --sign "$identity" "$app" 2>/dev/null || codesign --force --sign - "$app"
echo "$app"
