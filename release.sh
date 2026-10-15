#!/bin/zsh
# Baut Flow.app für ein GitHub Release und packt sie als build/Flow-<version>.zip.
set -euo pipefail
cd "${0:A:h}"

FLOW_SIGN_IDENTITY="Developer ID Application: Ulf Schuster (7RN999S858)" ./build.sh
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
zip="build/Flow-$version.zip"
rm -f "$zip"
# Ohne erweiterte Attribute, sonst bricht die Signatur beim Auspacken.
ditto -c -k --keepParent --noextattr --norsrc build/Flow.app "$zip"

# Gegenprobe wie beim Nutzer: auspacken und Signatur prüfen.
check=$(mktemp -d)
ditto -x -k "$zip" "$check"
codesign --verify --strict --deep "$check/Flow.app"
rm -rf "$check"

shasum -a 256 "$zip"
