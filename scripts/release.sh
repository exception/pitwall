#!/bin/zsh
# Builds a release of Pitwall and packages it as a drag-to-install DMG.
#
#   scripts/release.sh            # version from project.yml
#
# Signing: uses the first "Developer ID Application" identity in your
# keychain (or $SIGN_ID). Without one the app is ad-hoc signed and macOS will
# block it on other Macs, so this only produces a local test DMG.
#
# Notarization: if a notarytool keychain profile named $NOTARY_PROFILE
# (default "pitwall-notary") exists, the app and DMG are notarized and
# stapled. Create it once with:
#   xcrun notarytool store-credentials pitwall-notary --apple-id <id> --team-id <team> --password <app-specific-password>
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)
OUT=build/release
DD=build/rel
APP=$DD/Build/Products/Release/Pitwall.app
NOTARY_PROFILE=${NOTARY_PROFILE:-pitwall-notary}
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}
SIGN_ID=${SIGN_ID:--}

echo "==> Pitwall $VERSION (signing: ${SIGN_ID})"
rm -rf $OUT && mkdir -p $OUT

echo "==> Building (Release, arm64)"
xcodebuild -project Pitwall.xcodeproj -scheme Pitwall -configuration Release -derivedDataPath $DD \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build | grep -E "error:|\*\* BUILD" || true
[[ -d $APP ]] || { echo "build failed"; exit 1; }

echo "==> Signing"
TS=(); [[ $SIGN_ID != "-" ]] && TS=(--timestamp)
codesign --force --sign "$SIGN_ID" --options runtime $TS "$APP/Contents/Helpers/pitwall"
codesign --force --sign "$SIGN_ID" --options runtime $TS --entitlements Resources/Pitwall.entitlements "$APP"
codesign --verify --strict --deep "$APP"

notarize() {  # notarize <file>; staples if accepted
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
CAN_NOTARIZE=0
if [[ $SIGN_ID != "-" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then CAN_NOTARIZE=1; fi
if (( CAN_NOTARIZE )); then
  echo "==> Notarizing the app"
  ditto -c -k --keepParent "$APP" $OUT/Pitwall.zip
  notarize $OUT/Pitwall.zip
  xcrun stapler staple "$APP"
  rm $OUT/Pitwall.zip
fi

echo "==> Making the DMG"
STAGE=$OUT/stage
mkdir -p $STAGE/.background
ditto "$APP" $STAGE/Pitwall.app
ln -s /Applications $STAGE/Applications
[[ -x build/dmg-background ]] || swiftc -O scripts/tools/dmg-background.swift -o build/dmg-background
build/dmg-background $STAGE/.background >/dev/null
tiffutil -cathidpicheck $STAGE/.background/background.png $STAGE/.background/background@2x.png -out $STAGE/.background/background.tiff >/dev/null 2>&1
rm $STAGE/.background/background*.png
RW=$OUT/rw.dmg
hdiutil create -srcfolder $STAGE -volname "Pitwall" -fs HFS+ -format UDRW -ov $RW >/dev/null
MNT=$(hdiutil attach -readwrite -noverify -noautoopen $RW | awk -F'\t' '/\/Volumes\//{print $NF}')
# Window layout: 660×400, big icons, app on the left, Applications on the right.
osascript <<EOF
tell application "Finder"
  tell disk "Pitwall"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Pitwall.app" of container window to {165, 200}
    set position of item "Applications" of container window to {495, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
SetFile -a V "$MNT/.background" 2>/dev/null || true
sync; hdiutil detach "$MNT" >/dev/null
DMG=$OUT/Pitwall-$VERSION.dmg
hdiutil convert $RW -format UDZO -imagekey zlib-level=9 -o $DMG >/dev/null
rm -f $RW; rm -rf $STAGE
[[ $SIGN_ID != "-" ]] && codesign --force --sign "$SIGN_ID" $TS $DMG
if (( CAN_NOTARIZE )); then
  echo "==> Notarizing the DMG"
  notarize $DMG && xcrun stapler staple $DMG
fi
echo "==> $DMG ($(du -h $DMG | cut -f1))"
if [[ $SIGN_ID == "-" ]]; then
  echo "    Ad-hoc signed: fine on this Mac, blocked by Gatekeeper elsewhere. Needs a Developer ID to ship."
elif (( ! CAN_NOTARIZE )); then
  echo "    Signed but not notarized: other Macs will warn. Set up '$NOTARY_PROFILE' (see top of this script)."
fi
