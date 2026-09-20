#!/bin/zsh
# Install locally, then watch the app say what it is doing. Never returns; interrupt it to stop watching.
#
#   script/run.sh
#
# The install is script/install.sh, which is the only local path there is; this adds the log and nothing else.
set -euo pipefail
ROOT="${0:A:h:h}"
"$ROOT/script/install.sh" >/dev/null
exec tail -n 20 -F "$HOME/Library/Application Support/KoffeeLid/diagnostics.log"
