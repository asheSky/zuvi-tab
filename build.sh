#!/bin/bash
# Builds "Zuvi Tab.app" and installs it to ~/Applications.
# Signs with a local "Zuvi Tab Local Signing" certificate when one exists, so macOS keeps the
# Accessibility / Screen Recording grants across rebuilds. Without it the app is ad-hoc signed and
# macOS asks for those permissions again after every build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Zuvi Tab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ZuviTab "$APP/Contents/MacOS/ZuviTab"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Zuvi Tab Local Signing"/ {print $2; exit}')
codesign --force --options runtime --sign "${IDENTITY:--}" --identifier com.zuvitab.ZuviTab "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

# Privacy check: fail the build if any networking API sneaks into the binary.
scripts/check-no-network.sh "$APP/Contents/MacOS/ZuviTab"

mkdir -p "$HOME/Applications"
pkill -x ZuviTab 2>/dev/null || true
rm -rf "$HOME/Applications/Zuvi Tab.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed to ~/Applications/Zuvi Tab.app"
