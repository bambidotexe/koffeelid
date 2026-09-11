#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
command -v xcodegen >/dev/null || brew install xcodegen
cd "$ROOT" && xcodegen generate
