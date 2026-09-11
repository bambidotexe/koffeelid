#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
CONFIG="${1:-Release}"
[ -d "$ROOT/KoffeeLid.xcodeproj" ] || "$ROOT/script/bootstrap.sh"
xcodebuild -project "$ROOT/KoffeeLid.xcodeproj" -scheme KoffeeLid -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/DerivedData" build 2>&1 | tail -20
echo "$ROOT/DerivedData/Build/Products/$CONFIG/KoffeeLid.app"
