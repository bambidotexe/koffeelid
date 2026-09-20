#!/bin/zsh
# The shippable build, in the order Apple's checks need: archive → Developer ID export → notarize the app →
# staple it → wrap it in the disk image → sign and notarize the image → staple that too → prove Gatekeeper
# accepts what came out. Prints the image's path and nothing else on stdout.
#
#   script/release.sh
#
# It publishes nothing: `script/publish.sh` is what attaches the image to a GitHub release.
#
# One-time setup, both by the Wooflab team's Account Holder (docs/development.md § Signing and notarization):
#   • a "Developer ID Application" certificate for the team in this Mac's keychain
#   • xcrun notarytool store-credentials <profile> --key <AuthKey.p8> --key-id <id> --issuer <issuer>
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/script/signing.env"

DIST="$ROOT/dist"
ARCHIVE="$DIST/$APP_NAME.xcarchive"
EXPORT="$DIST/export"
APP="$EXPORT/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/App/Info.plist")"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
ZIP="$DIST/$APP_NAME-$VERSION.zip"

# Everything that can be missing is named before anything is built.
[ -n "$SIGN_IDENTITY" ] || {
  echo "no 'Developer ID Application' certificate for team $TEAM_ID in the keychain." >&2
  echo "The Wooflab Account Holder creates it: Xcode › Settings › Accounts › Wooflab › Manage Certificates › + › Developer ID Application." >&2
  exit 1
}
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
  echo "no notarytool keychain profile '$NOTARY_PROFILE'. Store one from an App Store Connect API key:" >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>" >&2
  exit 1
}
[ -z "$(git -C "$ROOT" status --porcelain)" ] || echo "warning: the working tree is dirty" >&2

[ -d "$ROOT/$APP_NAME.xcodeproj" ] || "$ROOT/script/bootstrap.sh" >&2
rm -rf "$ARCHIVE" "$EXPORT" "$DMG" "$ZIP"
mkdir -p "$DIST"

echo "building ${APP_NAME} ${VERSION}…" >&2
xcodebuild -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$ROOT/DerivedData" -archivePath "$ARCHIVE" archive 2>&1 \
  | grep -E 'error|warning:|ARCHIVE' >&2 || true
[ -d "$ARCHIVE" ] || { echo "the archive was not produced" >&2; exit 1; }

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$ROOT/script/ExportOptions.plist" \
  -exportPath "$EXPORT" 2>&1 | grep -E 'error|EXPORT' >&2 || true
[ -d "$APP" ] || { echo "the export produced no bundle" >&2; exit 1; }

# The export is only trusted once it says, itself, what it was signed with.
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1 \
  || { echo "the exported app does not verify" >&2; codesign --verify --deep --strict --verbose=2 "$APP" >&2; exit 1; }

# Read once into a variable rather than piping: `grep -q` closes the pipe on its first match, `codesign`
# dies of SIGPIPE, and `set -o pipefail` then calls the whole pipeline failed although the match succeeded.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
case "$SIGNATURE" in
  *"Authority=Developer ID Application: "*"($TEAM_ID)"*) ;;
  *) echo "the exported app is not signed with a Developer ID Application certificate for $TEAM_ID:" >&2
     echo "$SIGNATURE" >&2; exit 1 ;;
esac
case "$SIGNATURE" in
  *"flags=0x10000(runtime)"*) ;;
  *) echo "the exported app was not built with the Hardened Runtime, which notarization requires:" >&2
     echo "$SIGNATURE" >&2; exit 1 ;;
esac
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
case "$ENTITLEMENTS" in
  *get-task-allow*) echo "the exported app carries com.apple.security.get-task-allow; it must not ship" >&2; exit 1 ;;
esac

# The app is notarized on its own so that the copy dragged out of the image carries its own ticket, and does
# not need the network to be trusted.
echo "notarizing the app…" >&2
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait > "$DIST/notarize-app.log" 2>&1 || true
cat "$DIST/notarize-app.log" >&2
case "$(cat "$DIST/notarize-app.log")" in
  *"status: Accepted"*) ;;
  *) ID="$(awk '/^  id: /{print $2; exit}' "$DIST/notarize-app.log")"
     [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
     echo "the app was not notarized" >&2; exit 1 ;;
esac
xcrun stapler staple "$APP" >&2
rm -f "$ZIP"

echo "building the disk image…" >&2
"$ROOT/script/make-dmg.sh" "$APP" "$DMG" >/dev/null

# The image is signed and notarized in its turn, so that the download itself opens without a warning.
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" >&2
echo "notarizing the disk image…" >&2
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait > "$DIST/notarize-dmg.log" 2>&1 || true
cat "$DIST/notarize-dmg.log" >&2
case "$(cat "$DIST/notarize-dmg.log")" in
  *"status: Accepted"*) ;;
  *) ID="$(awk '/^  id: /{print $2; exit}' "$DIST/notarize-dmg.log")"
     [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
     echo "the disk image was not notarized" >&2; exit 1 ;;
esac
xcrun stapler staple "$DMG" >&2

# What a first download actually meets, asked of the system that will meet it.
xcrun stapler validate "$DMG" >&2
VERDICT="$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
case "$VERDICT" in
  *accepted*) ;;
  *) echo "Gatekeeper does not accept the disk image:" >&2; echo "$VERDICT" >&2; exit 1 ;;
esac
VERDICT="$(spctl -a -vv -t exec "$APP" 2>&1 || true)"
case "$VERDICT" in
  *accepted*) ;;
  *) echo "Gatekeeper does not accept the app:" >&2; echo "$VERDICT" >&2; exit 1 ;;
esac

echo "$DMG"
