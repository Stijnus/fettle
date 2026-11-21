#!/usr/bin/env bash
# Builds a release of Fettle: signed app, drag-to-install DMG, zip and checksums.
#
#   make release                       # build into dist/
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" make release
#   NOTARY_PROFILE=fettle-notary make release   # also notarize + staple
#
# Signing:
#   - If SIGN_IDENTITY is set, that identity is used.
#   - Otherwise the first "Developer ID Application" identity in the keychain is used.
#   - Otherwise the app is signed ad hoc. That runs on this Mac, but other Macs
#     will block it until the user right-clicks → Open (or runs
#     `xattr -dr com.apple.quarantine /Applications/Fettle.app`).
#
# Notarization (needs a Developer ID identity) — store credentials once with:
#   xcrun notarytool store-credentials fettle-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME=Fettle
PROJECT=Fettle.xcodeproj
DERIVED=.build-release
DIST=dist

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
BUILD=$(xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}')
[[ -n "$VERSION" ]] || { echo "Could not read MARKETING_VERSION" >&2; exit 1; }

echo "==> Building $APP_NAME $VERSION ($BUILD)"
xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO clean build -quiet

rm -rf "$DIST"
mkdir -p "$DIST"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
ditto "$DERIVED/Build/Products/Release/$APP_NAME.app" "$STAGE/$APP_NAME.app"
APP="$STAGE/$APP_NAME.app"

# --- Sign -----------------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')
fi

if [[ -n "$IDENTITY" ]]; then
  echo "==> Signing with: $IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  SIGNED=developer-id
else
  echo "==> No Developer ID identity found — signing ad hoc"
  codesign --force --sign - "$APP"
  SIGNED=adhoc
fi
codesign --verify --strict --verbose=2 "$APP"

# --- DMG ------------------------------------------------------------------
DMG="$DIST/$APP_NAME-$VERSION.dmg"
echo "==> Creating $DMG"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
SetFile -c icnC "$STAGE/.VolumeIcon.icns" 2>/dev/null || true

RW_DMG="$DIST/rw.dmg"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDRW -ov "$RW_DMG"
# Turn on the custom volume icon.
MOUNT=$(hdiutil attach -quiet -nobrowse -noverify -noautoopen "$RW_DMG" \
  | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
if [[ -z "$MOUNT" ]]; then
  MOUNT=$(hdiutil info | awk -F'\t' -v n="/Volumes/$APP_NAME $VERSION" '$NF==n{print $NF; exit}')
fi
SetFile -a C "$MOUNT" 2>/dev/null || true
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW_DMG"

if [[ "$SIGNED" == developer-id ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

# --- Notarize -------------------------------------------------------------
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$SIGNED" != developer-id ]]; then
    echo "NOTARY_PROFILE is set but no Developer ID identity was used; skipping notarization." >&2
  else
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    SIGNED=notarized
  fi
fi

# --- Zip + checksums ------------------------------------------------------
ZIP="$DIST/$APP_NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$APP_NAME-$VERSION.dmg" "$APP_NAME-$VERSION.zip" > SHA256SUMS.txt)

echo
echo "Done: $APP_NAME $VERSION ($SIGNED)"
ls -lh "$DIST"
