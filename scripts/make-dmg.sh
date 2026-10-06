#!/usr/bin/env bash
#
# Builds VoiceApp and packages it as build/VoiceApp-<version>.dmg (drag-to-Applications).
#
# Usage: scripts/make-dmg.sh [--skip-build]
#   --skip-build   package the existing build/VoiceApp.app instead of rebuilding
#
# The app is signed with the local "VoiceApp Local Signing" certificate (see build-app.sh), not a
# Developer ID, so it isn't notarized: on another Mac, open it once via System Settings >
# Privacy & Security > Open Anyway. Build every release on this Mac so the signature (and the
# Accessibility grant tied to it) stays the same.

set -euo pipefail

APP_NAME="VoiceApp"
SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/$APP_NAME.app"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    "$ROOT/scripts/build-app.sh"
fi
if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found; run scripts/build-app.sh first" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Staging"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Read Me First.txt" <<'EOF'
VoiceApp — install

1. Drag VoiceApp onto the Applications folder.
2. Open VoiceApp from Applications. macOS will say it can't verify the developer
   (the app is signed locally, not by Apple). Click Done, then open
   System Settings > Privacy & Security, scroll down and click "Open Anyway".
   This is needed only once.
3. Click the mic icon in the menu bar > Settings:
   - download and select a model (Parakeet v3 recommended),
   - grant Microphone and Accessibility.
4. Hold right Option to dictate (push to talk).

Tip: to skip the model downloads, copy
~/Library/Application Support/VoiceApp/models from the other Mac to the same place.
EOF

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"
