#!/bin/zsh
# What keeps a build from being launchable by accident.
#
#   source script/no-leftovers.sh
#   no_leftovers        delete every .app and .dmg under the repository
#   never_indexed <dir> keep Spotlight out of a directory builds write into
#
# A signed bundle in build/ or DerivedData/ is a complete, working application: Spotlight indexes it, the
# Finder opens it, and it runs beside the copy in /Applications as a second instance with the same bundle
# identifier, its own preferences and its own launch agent. Only /Applications ever holds this app, so a build
# is a step on the way there and never a thing left lying about.
#
# Two defences, because either alone leaks. `no_leftovers` removes the bundles when the work is done or has
# failed; `never_indexed` stops Spotlight seeing them while the work is still going on.
set -uo pipefail

no_leftovers() {
  local root="${1:-${0:A:h:h}}"
  # -prune: a bundle is a directory, and there is nothing to walk into once it is going.
  find "$root" \( -name '*.app' -o -name '*.dmg' \) -prune -exec rm -rf {} + 2>/dev/null || true
}

never_indexed() {
  local dir="${1:?never_indexed <dir>}"
  mkdir -p "$dir"
  # Spotlight reads this file's presence, not its contents, and skips the whole tree beneath it.
  : > "$dir/.metadata_never_index"
}
