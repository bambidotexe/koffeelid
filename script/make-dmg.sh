#!/bin/zsh
# Wraps an already-built, already-signed KoffeeLid.app in the disk image a release ships:
# the app, an Applications folder beside it, and a backdrop naming the app and pointing from one to the other.
#
#   script/make-dmg.sh <path to KoffeeLid.app> [output.dmg]
#
# Prints the image's path and nothing else on stdout. It signs nothing and notarizes nothing — the app must
# already carry the signature the image is meant to ship (script/release.sh is what does all of it in order).
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/script/signing.env"

APP="${1:?usage: make-dmg.sh <path to KoffeeLid.app> [output.dmg]}"
[ -d "$APP" ] || { echo "no such bundle: $APP" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="${2:-$ROOT/dist/$APP_NAME-$VERSION.dmg}"
mkdir -p "${DMG:h}"

# dmgbuild writes the window layout straight into the image's .DS_Store. The Finder/AppleScript way of doing
# this needs an Automation grant and fails silently without one, which is no way to cut a release.
VENV="$ROOT/build/dmgvenv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "preparing the disk-image tool…" >&2
  /usr/bin/python3 -m venv "$VENV" >&2
  "$VENV/bin/pip" install --quiet --disable-pip-version-check dmgbuild >&2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The backdrop, at both scales, in the one file Finder reads a Retina background from.
swift "$ROOT/script/dmg-background.swift" "$APP_NAME" "$DMG_ACCENT" "$WORK/bg.png" "$WORK/bg@2x.png" >&2
/usr/bin/tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

# The volume takes the icon macOS renders for the app, not the .icns inside it: an icon that comes from an
# Icon Composer document is rendered from Assets.car, and the bundled .icns is at best a flat stand-in of it.
ICON="$WORK/VolumeIcon.icns"
if swift "$ROOT/script/dmg-volume-icon.swift" "$APP" "$WORK/icon.iconset" >&2 \
   && iconutil -c icns "$WORK/icon.iconset" -o "$ICON" >&2; then
    :
else
    echo "warning: the volume icon could not be taken from the app; the image goes without one" >&2
    ICON=""
fi

rm -f "$DMG"
"$VENV/bin/dmgbuild" \
  -s "$ROOT/script/dmg-settings.py" \
  -D app="$APP" \
  -D name="$APP_NAME" \
  -D background="$WORK/background.tiff" \
  -D volume_icon="$ICON" \
  "$APP_NAME" "$DMG" >&2

echo "$DMG"
