#!/bin/zsh
# Shippable build: Release archive → Developer ID export → notarize → staple → zip. Prints the zip path last.
# One-time setup (docs/development.md § Known limitations): a "Developer ID Application" certificate for the
# Wooflab team and `xcrun notarytool store-credentials koffeelid-notary …`.
set -euo pipefail
ROOT="${0:A:h:h}"
PROFILE="${NOTARY_PROFILE:-koffeelid-notary}"
TEAM="75MADVD27T"
DIST="$ROOT/dist"
ARCHIVE="$DIST/KoffeeLid.xcarchive"
EXPORT="$DIST/export"
APP="$EXPORT/KoffeeLid.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/App/Info.plist")"
ZIP="$DIST/KoffeeLid-$VERSION.zip"

security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)" \
  || { echo "no 'Developer ID Application' certificate for team $TEAM in the keychain"; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "no notarytool keychain profile '$PROFILE'; run: xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id $TEAM"; exit 1; }
[ -z "$(git -C "$ROOT" status --porcelain)" ] || echo "warning: working tree is dirty"

[ -d "$ROOT/KoffeeLid.xcodeproj" ] || "$ROOT/script/bootstrap.sh"
rm -rf "$ARCHIVE" "$EXPORT" "$ZIP"; mkdir -p "$DIST"
xcodebuild -project "$ROOT/KoffeeLid.xcodeproj" -scheme KoffeeLid -configuration Release \
  -derivedDataPath "$ROOT/DerivedData" -archivePath "$ARCHIVE" archive 2>&1 | grep -E 'error|warning:|ARCHIVE' || true
[ -d "$ARCHIVE" ] || { echo "archive failed"; exit 1; }
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$ROOT/script/ExportOptions.plist" \
  -exportPath "$EXPORT" 2>&1 | grep -E 'error|EXPORT' || true
[ -d "$APP" ] || { echo "export failed"; exit 1; }

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application: .*($TEAM)" \
  || { echo "app is not signed with Developer ID Application ($TEAM)"; codesign -dvv "$APP"; exit 1; }

ditto -c -k --keepParent "$APP" "$ZIP"
echo "notarizing $ZIP …"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$DIST/notarize.log" | grep -q "status: Accepted"; then
  ID="$(grep -m1 '  id:' "$DIST/notarize.log" | awk '{print $2}')"
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
  echo "notarization failed"; exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # the shipped zip holds the stapled bundle
spctl -a -vv -t exec "$APP" 2>&1 | grep -q "accepted" || { echo "Gatekeeper rejects the exported app"; spctl -a -vv -t exec "$APP"; exit 1; }
echo "$ZIP"
