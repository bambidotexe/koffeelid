#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
CONFIG="${1:-Release}"

# A Debug build exists to read something a Release build will not show. It is never installed, and it is not
# made unless the owner has asked for one: DEBUG_OK=1 is how the caller says so.
if [ "$CONFIG" = "Debug" ] && [ "${DEBUG_OK:-0}" != "1" ]; then
  echo "refusing to build Debug without the owner asking for it." >&2
  echo "A Debug build is not installed and is not a way to run the app: script/install.sh is." >&2
  echo "If the owner has asked for one, run: DEBUG_OK=1 script/build.sh Debug" >&2
  exit 1
fi
[ -d "$ROOT/KoffeeLid.xcodeproj" ] || "$ROOT/script/bootstrap.sh"
xcodebuild -project "$ROOT/KoffeeLid.xcodeproj" -scheme KoffeeLid -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/DerivedData" build 2>&1 | tail -20
echo "$ROOT/DerivedData/Build/Products/$CONFIG/KoffeeLid.app"
