#!/bin/zsh
set -euo pipefail
"${0:A:h}/install.sh"
open "/Applications/KoffeeLid.app"
exec tail -n 20 -F "$HOME/Library/Application Support/KoffeeLid/diagnostics.log"
