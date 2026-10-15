#!/usr/bin/env bash
#
# Builds, signs and packages a VoiceApp release that installed copies pick up through Sparkle.
#
# Usage: scripts/release.sh <version> [--notes "What changed"] [--publish]
#   <version>   marketing version, e.g. 0.2.0 (the build number is bumped automatically)
#   --notes     release notes shown in the update window (plain text, one item per line)
#   --publish   push the commit and tag and create the GitHub release; without it the release
#               is only prepared locally in build/release/
#
# Run it on this Mac only: every update must be signed with the same "VoiceApp Local Signing"
# certificate and the Sparkle EdDSA key ("voiceapp" keychain account), or installed copies
# reject it and macOS drops the Accessibility grant.

set -euo pipefail

REPO="stifamajstor/voiceApp"
APP_NAME="VoiceApp"
KEY_ACCOUNT="voiceapp"

VERSION=""
NOTES=""
PUBLISH=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) NOTES="$2"; shift 2 ;;
        --publish) PUBLISH=1; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) VERSION="$1"; shift ;;
    esac
done
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/release.sh <major.minor.patch> [--notes \"...\"] [--publish]" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
ROOT="$PWD"
PLIST="$ROOT/Resources/Info.plist"
TAG="v$VERSION"
OUT="$ROOT/build/release"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "error: release from the main branch" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree has uncommitted changes; commit them first" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    swift package resolve
fi

echo "==> Versioning $VERSION"
# If anything fails before the release commit, put Info.plist back so the script can be rerun.
trap 'git checkout -- "$PLIST"' ERR
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$PLIST"

"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/make-dmg.sh" --skip-build

echo "==> Packaging update archive"
rm -rf "$OUT"
mkdir -p "$OUT"
ARCHIVE="$OUT/$APP_NAME-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/$APP_NAME.app" "$ARCHIVE"

# Sparkle shows <archive name>.html as the release notes.
if [[ -n "$NOTES" ]]; then
    {
        echo "<ul>"
        while IFS= read -r line; do
            [[ -n "$line" ]] && printf '<li>%s</li>\n' "$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<<"$line")"
        done <<<"$NOTES"
        echo "</ul>"
    } > "$OUT/$APP_NAME-$VERSION.html"
fi

echo "==> Generating appcast"
# Start from the published feed so older entries are kept.
curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" -o "$OUT/appcast.xml" 2>/dev/null \
    || rm -f "$OUT/appcast.xml"
"$SPARKLE_BIN/generate_appcast" \
    --account "$KEY_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --embed-release-notes \
    "$OUT"

git add "$PLIST"
git commit -q -m "Release $VERSION"
trap - ERR
git tag "$TAG"
echo "==> Prepared $TAG (build $BUILD) in $OUT"

DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
if [[ "$PUBLISH" -eq 0 ]]; then
    echo "Not published. To publish:"
    echo "  git push origin HEAD $TAG"
    echo "  gh release create $TAG --repo $REPO --title \"$APP_NAME $VERSION\" \"$ARCHIVE\" \"$DMG\" \"$OUT/appcast.xml\""
    exit 0
fi

echo "==> Publishing $TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" --repo "$REPO" --title "$APP_NAME $VERSION" \
    --notes "${NOTES:-$APP_NAME $VERSION}" \
    "$ARCHIVE" "$DMG" "$OUT/appcast.xml"
echo "==> Published https://github.com/$REPO/releases/tag/$TAG"
