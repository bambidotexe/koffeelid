#!/bin/zsh
# **Install locally.** One of the two ways a build of this app ever reaches a Mac.
#
#   script/install.sh [--dmg=<image>]
#
# Builds the same signed, notarized, stapled production bundle a release ships, at the version the rule in
# script/version.sh gives, puts it in /Applications, and leaves nothing behind: when this script returns there
# is no .app and no .dmg anywhere under the repository, so nothing but /Applications can be launched by
# Spotlight, opened by the Finder, or started by launchd.
#
# The other way is script/publish.sh, which does all of this and puts the disk image on GitHub as well; with
# `--dmg=<image>` this script installs an image already built (publish.sh's, with `--install`) by the very
# same path — the refusal while quitting would sleep the Mac, the sleep lock held across the relaunch, the
# mode put back — and builds nothing.
#
# There is no third way. A Debug build is for reading a crash that a Release build will not show, it is never
# installed, and it is not made without the owner asking for it (see script/build.sh).
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/script/signing.env"
source "$ROOT/script/version.sh"
source "$ROOT/script/no-leftovers.sh"

DEST="/Applications/$APP_NAME.app"
MOUNT=""
GIVEN_DMG=""
for arg in "$@"; do
  case "$arg" in
    --dmg=*) GIVEN_DMG="${arg#--dmg=}"; [ -f "$GIVEN_DMG" ] || { echo "no disk image at $GIVEN_DMG" >&2; exit 1; } ;;
    *) echo "unknown argument: $arg (--dmg=<image>)" >&2; exit 1 ;;
  esac
done

# The sleep lock (`pmset disablesleep`), run under the app's own sudoers rule; fails, harmlessly, without it.
# BRIDGE=1 while this script holds it for the relaunch (below).
BRIDGE=0
sleep_lock() { [ -f /etc/sudoers.d/koffeelid ] && sudo -n /usr/bin/pmset disablesleep "$1" >/dev/null 2>&1; }

# Whatever happens — a failed build, a refused install, an interrupt — the repository is left with nothing
# launchable in it, and a sleep lock held for a copy that is not armed is let go. This runs on the way out of
# every path through the script.
cleanup() {
  [ -n "$MOUNT" ] && [ -d "$MOUNT" ] && /usr/bin/hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  rm -rf "$ROOT/dist" "$ROOT/build/Build" "$ROOT/DerivedData/Build/Products"
  no_leftovers "$ROOT"
  if [ "$BRIDGE" = 1 ]; then sleep_lock 0 && echo "sleep lock released: $APP_NAME is not armed" >&2; fi
}
trap cleanup EXIT INT TERM

VERSION="$(version_tree)"
echo "installing $APP_NAME $VERSION" >&2

# ---------------------------------------------------------------------------------------------------------
# An install quits the running copy, which ends every arm it holds. **Quitting must never be able to sleep
# the Mac.** `KoffeeLidController.quitWouldSleepTheMac` is the one place that rule lives — armed, the lid
# shut, and no external display keeping the desktop up — and it has no override: an open lid, an external
# display, or an unarmed app are all safe to quit over. An armed Mac that is safe to quit is installed over,
# and the manual mode is put back afterwards — the arm is down only for the seconds between the quit and the
# relaunch, because the build and the notarizing are already done by then.
# ---------------------------------------------------------------------------------------------------------
quit_would_sleep() { case "$1" in *"quitting would sleep the Mac"*) return 0 ;; *) return 1 ;; esac }

# The manual mode to restore. The auto level is not one of these: it re-establishes itself at the next launch
# from the activity journal, so it needs no putting back.
manual_mode() {
  case "$1" in
    *"mode: armed + screen on"*) echo caffeinate ;;
    *"mode: armed"*) echo arm ;;
    *) echo "" ;;
  esac
}

STATUS=""
if [ -x "$DEST/Contents/MacOS/$APP_NAME" ]; then
  STATUS="$("$DEST/Contents/MacOS/$APP_NAME" status 2>/dev/null || true)"
  if quit_would_sleep "$STATUS"; then
    echo "refusing: quitting would sleep the Mac ($STATUS)." >&2
    echo "Open the lid, or connect an external display, and run this again." >&2
    exit 1
  fi
fi

if [ -n "$GIVEN_DMG" ]; then DMG="$GIVEN_DMG"; else DMG="$("$ROOT/script/release.sh")"; fi

# Read it again: the build took minutes, and the state may have changed in them.
if [ -x "$DEST/Contents/MacOS/$APP_NAME" ]; then
  STATUS="$("$DEST/Contents/MacOS/$APP_NAME" status 2>/dev/null || true)"
  if quit_would_sleep "$STATUS"; then
    echo "refusing: quitting would sleep the Mac ($STATUS). The image is built; open the lid or connect an external display and run this again." >&2
    exit 1
  fi
fi
RESTORE="$(manual_mode "$STATUS")"

# ---------------------------------------------------------------------------------------------------------
# The bundle that goes to /Applications is the one inside the disk image, so what is installed is exactly what
# a release would hand a stranger — stapled ticket and all.
# ---------------------------------------------------------------------------------------------------------
MOUNT="$(mktemp -d)"
/usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
# ---------------------------------------------------------------------------------------------------------
# From here until the mode is back, nothing holds the Mac: the old copy cleared the kernel flag under its
# sleep lock (so the kernel's clamshell evaluation could not start a sleep) and then released the lock. With
# the lid shut on an external display, a charger or display event in these seconds would sleep the Mac and
# lock the session, so the lock is held here across them, under the same sudoers rule, and handed to the new
# copy: its arm engages it again, with its own marker. Let go on the way out only if that copy is not armed.
# ---------------------------------------------------------------------------------------------------------
if [ -n "$RESTORE" ] && sleep_lock 1; then BRIDGE=1; echo "sleep lock held across the relaunch" >&2; fi
# Scoped to our own bundle path, never a bare process name.
pkill -f "$DEST/Contents/MacOS/${APP_NAME}Watchdog" 2>/dev/null || true

rm -rf "$DEST"
/usr/bin/ditto "$MOUNT/$APP_NAME.app" "$DEST"
/usr/bin/hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
MOUNT=""

# What was installed says for itself what it is. A bundle that fails this must not be left in /Applications.
codesign --verify --deep --strict "$DEST" 2>/dev/null || { echo "the installed bundle does not verify" >&2; rm -rf "$DEST"; exit 1; }
INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
[ "$INSTALLED" = "$VERSION" ] || { echo "installed $INSTALLED, expected $VERSION" >&2; exit 1; }
xcrun stapler validate "$DEST" >/dev/null 2>&1 || echo "warning: the installed bundle carries no stapled ticket" >&2
echo "installed $DEST ($INSTALLED)" >&2

# `koffeelid <verb>`: a wrapper, not a symlink, so Bundle.main still resolves to the app.
BIN_DIR="/usr/local/bin"
if [ -w "$BIN_DIR" ]; then
  printf '#!/bin/zsh\nexec "%s/Contents/MacOS/%s" "$@"\n' "$DEST" "$APP_NAME" > "$BIN_DIR/koffeelid"
  chmod +x "$BIN_DIR/koffeelid"
  echo "installed $BIN_DIR/koffeelid" >&2
else
  echo "skipped $BIN_DIR/koffeelid ($BIN_DIR is not writable); create it with:" >&2
  echo "  sudo sh -c 'printf \"#!/bin/zsh\\\\nexec \\\"$DEST/Contents/MacOS/$APP_NAME\\\" \\\"\\\$@\\\"\\\\n\" > $BIN_DIR/koffeelid && chmod +x $BIN_DIR/koffeelid'" >&2
fi

# The sleep lock needs root. Without it powerd can still sleep a closed armed Mac when it rewrites the flag.
if sudo -n -l /usr/bin/pmset disablesleep 1 >/dev/null 2>&1; then
  echo "sleep lock: sudoers rule present" >&2
else
  echo "sleep lock unavailable — a charger or display change can sleep the closed armed Mac. Enable it once with:" >&2
  echo "  echo \"$USER ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\" | sudo tee /etc/sudoers.d/koffeelid.tmp >/dev/null && sudo chmod 0440 /etc/sudoers.d/koffeelid.tmp && sudo visudo -cf /etc/sudoers.d/koffeelid.tmp && sudo mv /etc/sudoers.d/koffeelid.tmp /etc/sudoers.d/koffeelid" >&2
fi

open "$DEST"

# The mode the owner was in goes back. The auto level needs nothing: a launch while a session is working arms
# at once by itself.
if [ -n "$RESTORE" ]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    "$DEST/Contents/MacOS/$APP_NAME" status >/dev/null 2>&1 && break
    sleep 1
  done
  if "$DEST/Contents/MacOS/$APP_NAME" "$RESTORE" >/dev/null 2>&1; then
    echo "restored mode: $RESTORE" >&2
  else
    echo "WARNING: could not restore mode '$RESTORE' — the Mac is not armed. Set it from the menu." >&2
  fi
  # An armed copy holds the lock itself now (its arm wrote it, with its marker); the bridge is its to keep.
  case "$("$DEST/Contents/MacOS/$APP_NAME" status 2>/dev/null || true)" in
    *"mode: armed"*|*"auto-armed"*) BRIDGE=0 ;;
  esac
fi

echo "$DEST"
