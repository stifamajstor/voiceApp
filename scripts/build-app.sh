#!/usr/bin/env bash
#
# Builds VoiceApp in release mode (arm64) and assembles a signed build/VoiceApp.app.
#
# Usage: scripts/build-app.sh [--install] [--run]
#   --install   also copy the app to /Applications (replacing any existing copy)
#   --run       launch the app afterwards (from /Applications if --install was given)
#
# Environment:
#   SIGN_IDENTITY   codesign identity; defaults to the "VoiceApp Local Signing" certificate if
#                   it is in the keychain, else "-" (ad-hoc, which loses Accessibility grants on
#                   every rebuild).

set -euo pipefail

APP_NAME="VoiceApp"
BUNDLE_ID="com.local.voiceapp"
LOCAL_IDENTITY="VoiceApp Local Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    # A stable certificate keeps macOS privacy grants (Accessibility) valid across rebuilds;
    # ad-hoc signatures change with every build. Untrusted self-signed certs still work.
    if security find-identity -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
        SIGN_IDENTITY="$LOCAL_IDENTITY"
    else
        SIGN_IDENTITY="-"
    fi
fi

INSTALL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --run) RUN=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/$APP_NAME.app"

# A half-built or rejected app must not be left where make-dmg.sh --skip-build would package it.
# Disarmed once the app is verified and signed.
trap '[[ $? -eq 0 ]] || rm -rf "$APP"' EXIT

echo "==> Building (release, arm64)"
# SwiftPM's executable accessor searches the app root, but signed macOS apps keep
# resource bundles in Contents/Resources. Compile adjusted copies through an overlay.
OVERLAY="$ROOT/.build/resource-accessors/overlay.json"
BUILD_ARGS=(-c release --arch arm64 -Xswiftc -vfsoverlay -Xswiftc "$OVERLAY")
# Planning does not read the overlay; use the same flags throughout to keep one cached plan.
swift build "${BUILD_ARGS[@]}" --print-manifest-job-graph >/dev/null
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
swift "$ROOT/scripts/prepare-resource-overlay.swift" "$BIN_DIR" "$(dirname "$OVERLAY")"
swift build "${BUILD_ARGS[@]}"

shopt -s nullglob
if [[ ! -x "$BIN_DIR/$APP_NAME" ]]; then
    echo "error: built executable not found at $BIN_DIR/$APP_NAME" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon: render every size macOS needs from the 1024 px master into AppIcon.icns.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/Resources/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT/Resources/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Resource accessors now resolve these bundles through Bundle.main.resourceURL.
for bundle in "$BIN_DIR"/*.bundle; do
    echo "    resource bundle: $(basename "$bundle")"
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

swift "$ROOT/scripts/verify-resource-overlay.swift" "$OVERLAY" "$APP"

# Dynamic frameworks from binary dependencies (Sparkle) go in Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
for framework in "$BIN_DIR"/*.framework; do
    echo "    framework: $(basename "$framework")"
    ditto "$framework" "$APP/Contents/Frameworks/$(basename "$framework")"
done
shopt -u nullglob
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"

echo "==> Signing (identity: $SIGN_IDENTITY)"
# Sign nested code inside-out instead of --deep, which would stamp the app's identifier onto
# Sparkle's helpers. Sparkle's updater requires every update to carry the same signature.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    for nested in \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app" \
        "$SPARKLE"; do
        codesign --force --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements "$nested"
    done
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

trap - EXIT
echo "==> Built $APP"

TARGET="$APP"
if [[ "$INSTALL" -eq 1 ]]; then
    TARGET="/Applications/$APP_NAME.app"
    echo "==> Installing to $TARGET"
    pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
    rm -rf "$TARGET"
    ditto "$APP" "$TARGET"
fi

if [[ "$RUN" -eq 1 ]]; then
    echo "==> Launching $TARGET"
    open "$TARGET"
fi
