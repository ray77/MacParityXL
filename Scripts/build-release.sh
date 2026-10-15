#!/bin/bash
# Builds a self-contained, universal (arm64 + x86_64) MacParityXL.app with swiftc, without
# needing Xcode, and packs it into a DMG and a ZIP in build/release.
#
# The app carries everything it needs: par2cmdline-turbo in Contents/Helpers and RARLAB's
# UnRAR linked statically into the executable. It is signed ad hoc (no Developer ID).
#
# Requires: Scripts/bootstrap-vendor.sh has run, xcodegen (for Info.plist), Command Line Tools.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=MacParityXL
BUNDLE_ID=org.noisebay.MacParityXL
MIN_MACOS=14.0
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$ROOT/project.yml")
BUILD_NUMBER=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$ROOT/project.yml")
OUT=$ROOT/build/release
WORK=$OUT/work
APP=$OUT/$NAME.app

for f in "$ROOT/Vendor/build/bin/par2" "$ROOT/Vendor/build/lib/libunrar.a"; do
    [ -e "$f" ] || { echo "error: $f missing. Run Scripts/bootstrap-vendor.sh first." >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$WORK"

# Info.plist comes from project.yml through XcodeGen.
(cd "$ROOT" && xcodegen generate --quiet)

echo "==> Compiling $NAME $VERSION ($BUILD_NUMBER)"
PARITYKIT_SOURCES=$(find "$ROOT/Packages/ParityKit/Sources/ParityKit" -name '*.swift')
APP_SOURCES=$(find "$ROOT/App/Sources" -name '*.swift')
for ARCH in arm64 x86_64; do
    D=$WORK/$ARCH
    mkdir -p "$D/modules"
    TARGET=$ARCH-apple-macos$MIN_MACOS
    # shellcheck disable=SC2086
    swiftc -swift-version 6 -target "$TARGET" -O -wmo -parse-as-library -module-name ParityKit \
        -emit-module -emit-module-path "$D/modules/ParityKit.swiftmodule" \
        -emit-library -static -o "$D/libParityKit.a" $PARITYKIT_SOURCES
    # shellcheck disable=SC2086
    swiftc -swift-version 6 -target "$TARGET" -O -wmo -module-name "$NAME" \
        -I "$D/modules" -I "$ROOT/App/CUnrar" -Xcc "-I$ROOT/Vendor/build/include/unrar" \
        -L "$D" -lParityKit -L "$ROOT/Vendor/build/lib" -lunrar -lc++ \
        -Xlinker -dead_strip \
        $APP_SOURCES -o "$D/$NAME"
done

echo "==> Assembling $APP"
C=$APP/Contents
mkdir -p "$C/MacOS" "$C/Helpers" "$C/Resources/licenses"
lipo -create "$WORK/arm64/$NAME" "$WORK/x86_64/$NAME" -output "$C/MacOS/$NAME"
strip -x "$C/MacOS/$NAME"
cp "$ROOT/Vendor/build/bin/par2" "$C/Helpers/par2"
cp "$ROOT/Vendor/build/licenses/"* "$C/Resources/licenses/"
printf 'APPL????' > "$C/PkgInfo"

sed -e "s/\$(DEVELOPMENT_LANGUAGE)/en/" \
    -e "s/\$(PRODUCT_MODULE_NAME)/$NAME/g" \
    -e "s/\$(EXECUTABLE_NAME)/$NAME/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(PRODUCT_NAME)/$NAME/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/" \
    -e "s/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/" \
    "$ROOT/App/Info.plist" > "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$C/Info.plist"
if grep -q '\$(' "$C/Info.plist"; then
    echo "error: unresolved build variable in Info.plist:" >&2
    grep '\$(' "$C/Info.plist" >&2
    exit 1
fi
plutil -lint -s "$C/Info.plist"

# App icon: the asset catalog's PNGs already use iconset file names.
ICONSET=$WORK/AppIcon.iconset
mkdir -p "$ICONSET"
cp "$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset/"*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"

# Localizations.
python3 "$ROOT/Scripts/xcstrings-to-strings.py" "$C/Resources" "$ROOT/App/Resources/"*.xcstrings
plutil -lint -s "$C/Resources/"*.lproj/*.strings

echo "==> Signing (ad hoc)"
codesign --force --sign - --options runtime --timestamp=none "$C/Helpers/par2"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$ROOT/App/$NAME.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Packaging"
STAGE=$WORK/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG=$OUT/$NAME-$VERSION.dmg
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
ZIP=$OUT/$NAME-$VERSION.zip
(cd "$OUT" && ditto -c -k --keepParent "$NAME.app" "$ZIP")
rm -rf "$WORK"

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)
echo "==> Done"
ls -lh "$OUT"
