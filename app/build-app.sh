#!/bin/bash
# Builds CacheCue.app from this package.
#
#   ./build-app.sh                     build/CacheCue.app, ad-hoc signed (runs on this Mac only)
#   ./build-app.sh --install           the same, copied to ~/Applications and (re)started
#   ./build-app.sh --release [x.y.z]   Developer ID signed, notarized, stapled DMG in build/,
#                                      and the signed appcast.xml that tells Sparkle about it
#
# A release takes the next version by itself: the latest release on GitHub with its patch
# number raised by one, or 1.0.0 when there is none yet. Give a version to choose it yourself.
# It needs three things from your own keychain, named in the environment:
#   SIGN_ID          a "Developer ID Application: ..." identity (found automatically if you have one)
#   NOTARY_PROFILE   a notarytool keychain profile (xcrun notarytool store-credentials <name>)
#   SPARKLE_ACCOUNT  the keychain account of the update-signing key (default: CacheCue; make one
#                    with Sparkle's generate_keys --account <name>, and set SPARKLE_PUBLIC_KEY)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP="build/CacheCue.app"
BUNDLE_ID="${BUNDLE_ID:-com.elvisli.CacheCue}"
REPO="${REPO:-MinLi999/CacheCue}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-CacheCue}"
# The public half of the update-signing key: the app trusts only updates signed with its pair.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-0oMHBeZaSDvaFARpVb8ce7f6I8f/H+prBxreVJbtSa4=}"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

# A local build is no release: it shows "dev" and does not update itself.
VERSION="dev"
BUILD_NUMBER="0"
ARCHS=()
UPDATER_KEYS=""
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
    # One number that only ever grows, which is what Sparkle compares builds by: 1.0.4 -> 10004.
    BUILD_NUMBER=$(( BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3] ))
    # A release runs on Intel and Apple silicon alike; a local build only needs this Mac.
    ARCHS=(--arch arm64 --arch x86_64)
    # Checks once a day without asking first; the switch in the popover turns it off.
    UPDATER_KEYS="    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>"
    echo "version $VERSION (build $BUILD_NUMBER)"
fi

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/CacheCue" "$APP/Contents/MacOS/CacheCue"
# Sparkle travels inside the app; ditto keeps the framework's symlinks as they are.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

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
$UPDATER_KEYS
</dict>
</plist>
PLIST

# Signs Sparkle from the inside out, then the app: every piece of code under one identity.
sign_app() {
    local sparkle="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign --force "$@" "$sparkle/XPCServices/Installer.xpc"
    codesign --force "$@" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
    codesign --force "$@" "$sparkle/Autoupdate"
    codesign --force "$@" "$sparkle/Updater.app"
    codesign --force "$@" "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force "$@" "$APP"
}

if [[ "$MODE" == "--release" ]]; then
    SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
    [[ -n "$SIGN_ID" ]] || { echo "No Developer ID Application identity found; set SIGN_ID." >&2; exit 1; }
    [[ -n "${NOTARY_PROFILE:-}" || "${NOTARIZE:-1}" != "1" ]] || { echo "Set NOTARY_PROFILE to a notarytool keychain profile." >&2; exit 1; }
    SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
    [[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "Sparkle's tools are missing from $SPARKLE_BIN." >&2; exit 1; }
    DMG="build/CacheCue_$VERSION.dmg"

    # Hardened runtime and a secure timestamp are what notarization asks for.
    sign_app --options runtime --timestamp --sign "$SIGN_ID"
    codesign --verify --deep --strict --verbose=2 "$APP"

    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG" build/CacheCue.dmg build/appcast.xml
    hdiutil create -volname "CacheCue" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

    # NOTARIZE=0 stops short of sending anything to Apple: a rehearsal, not a release.
    if [[ "${NOTARIZE:-1}" == "1" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    else
        echo "NOTARIZE=0: not notarized, not for distribution"
    fi

    # The feed Sparkle reads: this release alone, signed with the update key, pointing at
    # the DMG where the GitHub release will hold it.
    FEED_DIR="$(mktemp -d)"
    cp "$DMG" "$FEED_DIR/"
    "$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
        --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
        --link "https://github.com/$REPO" -o "$FEED_DIR/appcast.xml" "$FEED_DIR"
    cp "$FEED_DIR/appcast.xml" build/appcast.xml
    rm -rf "$FEED_DIR"
    grep -q 'sparkle:edSignature' build/appcast.xml || { echo "appcast.xml is not signed." >&2; exit 1; }

    # The same file under a name that never changes, for a download link that never breaks.
    cp "$DMG" build/CacheCue.dmg
    echo "$VERSION" > build/VERSION
    echo "release ready: $DMG and build/appcast.xml"
    shasum -a 256 "$DMG"
    exit 0
fi

# Ad-hoc signature: enough to run locally and to register as a login item.
sign_app --sign -
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
