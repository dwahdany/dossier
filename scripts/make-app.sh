#!/bin/bash
# Builds Dossier in release mode and assembles build/Dossier.app.
#
#   scripts/make-app.sh                      native build + bundle + ad-hoc sign
#   scripts/make-app.sh --universal          arm64 + x86_64
#   scripts/make-app.sh --dmg                also write build/Dossier-<version>.dmg
#   scripts/make-app.sh --notarize --dmg     Developer ID build, notarized and stapled
#
# Without options nothing here needs a signing identity, the keychain, sudo or the network:
# the app icon is drawn by scripts/make-icon.swift at build time and the bundle is signed
# ad hoc. The script never launches the app.
#
# Environment:
#   CODESIGN_IDENTITY   "Developer ID Application: Name (TEAMID)". Signs with the hardened
#                       runtime and a secure timestamp instead of ad hoc. Needed by --notarize.
#   NOTARY_PROFILE      notarytool keychain profile for --notarize (default "dossier-notary").
#                       Create it once with: xcrun notarytool store-credentials dossier-notary
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

universal=0; make_dmg=0; notarize=0
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) universal=1 ;;
        --dmg)       make_dmg=1 ;;
        --notarize)  notarize=1; universal=1 ;;
        -h|--help)   sed -n '2,/^set -e/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "unknown option: $1" ;;
    esac
    shift
done

APP_NAME="Dossier"
BUNDLE_ID="dev.dossier.viewer"
VERSION="$(tr -d ' \t\r\n' < "$ROOT/VERSION")"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
MIN_SYSTEM="15.0"
IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-dossier-notary}"

if [ "$notarize" -eq 1 ]; then
    case "$IDENTITY" in
        "Developer ID Application:"*) ;;
        *) die "--notarize needs CODESIGN_IDENTITY set to a \"Developer ID Application: …\" identity" ;;
    esac
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "notarytool profile '$NOTARY_PROFILE' is missing or invalid; run: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi

# Submits a file to Apple's notary service and waits; prints the log and stops on rejection.
notarize_file() { # <path to .zip or .dmg>
    local out id status
    out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || { echo "$out" >&2; die "notarytool failed for $(basename "$1")"; }
    id="$(printf '%s\n' "$out" | awk '/^ *id:/ {print $2; exit}')"
    status="$(printf '%s\n' "$out" | awk '/^ *status:/ {print $2}' | tail -1)"
    if [ "$status" != "Accepted" ]; then
        echo "$out" >&2
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        die "notarization of $(basename "$1") ended with status '${status:-unknown}'"
    fi
    echo "    notarized $(basename "$1") (submission $id)"
}

ARCH_FLAGS=()
[ "$universal" -eq 0 ] || ARCH_FLAGS=(--arch arm64 --arch x86_64)

OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
WORK="$OUT/.work"

echo "==> swift build -c release${ARCH_FLAGS[*]:+ (universal)}"
swift build -c release --product "$APP_NAME" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
[ -x "$BINARY" ] || { echo "error: $BINARY not found" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundles (none today, but keep the app self-contained if any appear).
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
shopt -u nullglob

echo "==> drawing the app icon"
ICONSET="$WORK/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><true/>
    <key>NSHumanReadableCopyright</key><string>Reads on-device stores only. Nothing is modified and Dossier sends no store content anywhere; maps download Apple map tiles.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ -n "$IDENTITY" ]; then
    echo "==> code signing (hardened runtime)"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    echo "==> ad-hoc code signing"
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

if [ "$notarize" -eq 1 ]; then
    echo "==> notarizing the app"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarize.zip"
    notarize_file "$WORK/notarize.zip"
    xcrun stapler staple -q "$APP"
    xcrun stapler validate -q "$APP"
    spctl --assess --type execute "$APP" || die "Gatekeeper rejects the notarized app"
fi

if [ "$make_dmg" -eq 1 ]; then
    DMG="$OUT/$APP_NAME-$VERSION.dmg"
    echo "==> building $DMG"
    STAGE="$WORK/dmg"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
    if [ -n "$IDENTITY" ]; then codesign --force --timestamp --sign "$IDENTITY" "$DMG"; fi
    if [ "$notarize" -eq 1 ]; then
        echo "==> notarizing the disk image"
        notarize_file "$DMG"
        xcrun stapler staple -q "$DMG"
        xcrun stapler validate -q "$DMG"
        spctl --assess --type open --context context:primary-signature "$DMG" || die "Gatekeeper rejects the notarized disk image"
    fi
fi

rm -rf "$WORK"
SIZE="$(du -sh "$APP" | cut -f1)"
echo "==> done: $APP ($SIZE)"
echo "    Self-test without opening a window:  \"$APP/Contents/MacOS/$APP_NAME\" --selftest"
echo "    The app needs Full Disk Access (System Settings › Privacy & Security). An ad-hoc"
echo "    signature changes with every build, so the permission has to be granted again"
echo "    after rebuilding; when the binary is run from a terminal, the terminal's"
echo "    permission applies instead."
