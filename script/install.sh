#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$("$ROOT/script/build.sh" Release | tail -1)"
DEST="/Applications/KoffeeLid.app"
# Installing quits the running app. Refuse while it is armed: that would end the user's session
# (and can sleep a closed Mac). Override with FORCE=1 when you really mean it.
if [ -x "$DEST/Contents/MacOS/KoffeeLid" ] && [ "${FORCE:-0}" != "1" ]; then
  STATUS="$("$DEST/Contents/MacOS/KoffeeLid" status 2>/dev/null || true)"
  case "$STATUS" in
    *"auto-armed"*) echo "refusing to install: KoffeeLid is auto-armed ($STATUS). Wait for the work to end, switch the feature off, or FORCE=1."; exit 1 ;;
    "mode: off"*|"") ;;
    *) echo "refusing to install: KoffeeLid is running and not off ($STATUS). Run 'koffeelid off' first or FORCE=1."; exit 1 ;;
  esac
fi
osascript -e 'tell application id "dev.rubens.koffeelid" to quit' 2>/dev/null || true
sleep 1
pkill -f "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidWatchdog" 2>/dev/null || true
# launchd may restart the watchdog right after this pkill (KeepAlive on unsuccessful exit).
# That is harmless: a watchdog that finds no armed app stands down, and the app kickstarts
# the agent again on its next launch.
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST"
echo "installed $DEST"

# `koffeelid <verb>` command line: a wrapper (not a symlink, so Bundle.main resolves to the app).
BIN_DIR="/usr/local/bin"
if [ -w "$BIN_DIR" ] || [ ! -e "$BIN_DIR" ]; then
  mkdir -p "$BIN_DIR"
  printf '#!/bin/zsh\nexec "%s/Contents/MacOS/KoffeeLid" "$@"\n' "$DEST" > "$BIN_DIR/koffeelid"
  chmod +x "$BIN_DIR/koffeelid"
  echo "installed $BIN_DIR/koffeelid"
else
  echo "skipped $BIN_DIR/koffeelid (not writable); create it with:"
  printf '  sudo sh -c '"'"'printf "#!/bin/zsh\\nexec \"%s/Contents/MacOS/KoffeeLid\" \"\$@\"\\n" > %s/koffeelid && chmod +x %s/koffeelid'"'"'\n' "$DEST" "$BIN_DIR" "$BIN_DIR"
fi

# Sleep lock: `pmset disablesleep` needs root. With this sudoers rule the app engages it on every arm, and
# macOS can no longer sleep a closed armed Mac when powerd rewrites the lid-sleep bit (charger, display).
if sudo -n -l /usr/bin/pmset disablesleep 1 >/dev/null 2>&1; then
  echo "sleep lock: sudoers rule present"
else
  echo "sleep lock unavailable (a charger or display change can still sleep the closed armed Mac); enable it once with:"
  echo "  echo \"$USER ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\" | sudo tee /etc/sudoers.d/koffeelid >/dev/null && sudo chmod 0440 /etc/sudoers.d/koffeelid && sudo visudo -cf /etc/sudoers.d/koffeelid"
fi
