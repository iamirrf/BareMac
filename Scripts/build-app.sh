#!/usr/bin/env bash
# Builds dist/BareMac.app from the Swift package.
#
#   Scripts/build-app.sh                 release, this Mac's architecture, ad-hoc signed
#   Scripts/build-app.sh --universal     arm64 + x86_64
#   Scripts/build-app.sh --sign "Developer ID Application: Name (TEAMID)"
#   Scripts/build-app.sh --debug
#
# For the notarized release build, see Scripts/release.sh (Xcode archive + notarization).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG=release
UNIVERSAL=0
IDENTITY="-"
OUTPUT="$ROOT/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIG=debug ;;
    --release) CONFIG=release ;;
    --universal) UNIVERSAL=1 ;;
    --adhoc) IDENTITY="-" ;;
    --sign) IDENTITY="$2"; shift ;;
    --output) OUTPUT="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCH_FLAGS=()
if [[ $UNIVERSAL == 1 ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "==> Building BareMac $VERSION ($BUILD_NUMBER), $CONFIG"
swift build -c "$CONFIG" --product BareMac ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" --product BareMac ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$OUTPUT/BareMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BareMac" "$APP/Contents/MacOS/BareMac"

# Info.plist with the version filled in.
sed -e "s/\$(MARKETING_VERSION)/$VERSION/" -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# App icon: an Icon Composer document if there is one, else a plain .icns.
if [[ -d Resources/AppIcon.icon ]]; then
  TMP="$(mktemp -d)"
  xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --include-all-app-icons \
    --output-partial-info-plist "$TMP/partial.plist" --output-format human-readable-text >/dev/null
  rm -rf "$TMP"
elif [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing ($([[ $IDENTITY == "-" ]] && echo ad-hoc || echo "$IDENTITY"))"
if [[ $IDENTITY == "-" ]]; then
  codesign --force --sign - --options runtime "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature|Runtime" || true
echo "==> $APP"
