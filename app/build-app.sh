#!/bin/bash
# Builds CacheCue.app from this package.
#
#   ./build-app.sh                     build/CacheCue.app, ad-hoc signed (runs on this Mac only)
#   ./build-app.sh --install           the same, copied to ~/Applications and (re)started
#   ./build-app.sh --release [x.y.z]   Developer ID signed, notarized, stapled DMG in build/
#
# A release takes the next version by itself: the latest release on GitHub with its patch
# number raised by one, or 1.0.0 when there is none yet. Give a version to choose it yourself.
# It needs two things from your own keychain, named in the environment:
#   SIGN_ID          a "Developer ID Application: ..." identity (found automatically if you have one)
#   NOTARY_PROFILE   a notarytool keychain profile (xcrun notarytool store-credentials <name>)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP="build/CacheCue.app"
BUNDLE_ID="${BUNDLE_ID:-com.elvisli.CacheCue}"
REPO="${REPO:-MinLi999/CacheCue}"

# A local build is no release: it shows "dev" and is never told to update.
VERSION="dev"
BUILD_NUMBER="0"
ARCHS=()
if [[ "$MODE" == "--release" ]]; then
    VERSION="${2:-}"
    if [[ -z "$VERSION" ]]; then
        LATEST="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null | sed 's/^v//' || true)"
        if [[ "$LATEST" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
        else
            VERSION="1.0.0"
        fi
    fi
    [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "Version must be x.y.z, got '$VERSION'." >&2; exit 1; }
    # One number that only ever grows, for the system to compare builds by: 1.0.4 -> 10004.
    BUILD_NUMBER=$(( BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3] ))
    # A release runs on Intel and Apple silicon alike; a local build only needs this Mac.
    ARCHS=(--arch arm64 --arch x86_64)
    echo "version $VERSION (build $BUILD_NUMBER)"
fi

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/CacheCue" "$APP/Contents/MacOS/CacheCue"

# The icon is drawn by the app itself, then cut to the sizes an .icns holds.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/CacheCue" --render-icon "$ICONSET/icon_512x512@2x.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    [[ $size == 512 ]] || sips -z $((size * 2)) $((size * 2)) "$ICONSET/icon_512x512@2x.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>CacheCue</string>
    <key>CFBundleDisplayName</key><string>CacheCue</string>
    <key>CFBundleExecutable</key><string>CacheCue</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <!-- Menu bar only: no Dock icon, no app menu. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [[ "$MODE" == "--release" ]]; then
    SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
    [[ -n "$SIGN_ID" ]] || { echo "No Developer ID Application identity found; set SIGN_ID." >&2; exit 1; }
    [[ -n "${NOTARY_PROFILE:-}" ]] || { echo "Set NOTARY_PROFILE to a notarytool keychain profile." >&2; exit 1; }
    DMG="build/CacheCue_$VERSION.dmg"

    # Hardened runtime and a secure timestamp are what notarization asks for.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"

    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG" build/CacheCue.dmg
    hdiutil create -volname "CacheCue" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    # The same file under a name that never changes, for a download link that never breaks.
    cp "$DMG" build/CacheCue.dmg
    echo "$VERSION" > build/VERSION
    echo "release ready: $DMG"
    shasum -a 256 "$DMG"
    exit 0
fi

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "$MODE" == "--install" ]]; then
    DEST="$HOME/Applications/CacheCue.app"
    mkdir -p "$HOME/Applications"
    pkill -x CacheCue 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "installed and started $DEST"
fi
