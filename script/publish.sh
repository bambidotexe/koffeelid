#!/bin/zsh
# **Release to GitHub.** The other of the two ways a build of this app ever reaches a Mac.
#
#   script/publish.sh
#
# Tags this commit, pushes it, attaches the signed and notarized disk image to a GitHub release, installs the
# same bundle in /Applications, and raises the tree to the next patch so that it is once again one ahead of
# what is published. It leaves nothing behind: no .app and no .dmg anywhere under the repository.
#
# The other way is script/install.sh, which does everything but the publishing.
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/script/signing.env"
source "$ROOT/script/version.sh"
source "$ROOT/script/no-leftovers.sh"

# Whatever happens — a refused release, a failed build, an interrupt — the repository is left with nothing
# launchable in it. The named paths keep the build tree tidy; the sweep is what enforces the rule.
cleanup() {
  rm -rf "$ROOT/dist" "$ROOT/build/Build" "$ROOT/DerivedData/Build/Products"
  no_leftovers "$ROOT"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------------------------------------
# A release names a commit, so everything it names has to be committed and pushed first. These refusals come
# before the build: none of them is worth five minutes of notarizing to discover.
# ---------------------------------------------------------------------------------------------------------
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "refusing: the working tree is dirty. Commit first — a release names a commit." >&2; exit 1; }

VERSION="$(version_check)" || exit 1
TAG="v$VERSION"
git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "refusing: $TAG already exists." >&2; exit 1; }
[ -z "$(gh release view "$TAG" -R "$GITHUB_REPO" --json tagName -q .tagName 2>/dev/null)" ] || { echo "refusing: a release $TAG already exists on GitHub." >&2; exit 1; }

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
git -C "$ROOT" fetch -q origin "$BRANCH"
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse "origin/$BRANCH")" ] \
  || { echo "refusing: HEAD and origin/$BRANCH differ. Push first — a release names a commit others can fetch." >&2; exit 1; }

echo "releasing $APP_NAME $VERSION" >&2
DMG="$("$ROOT/script/release.sh")"

# The tag is made and pushed only once there is an image to attach to it.
git -C "$ROOT" tag -a "$TAG" -m "$APP_NAME $VERSION"
git -C "$ROOT" push -q origin "$TAG"
gh release create "$TAG" "$DMG" -R "$GITHUB_REPO" --title "$APP_NAME $VERSION" \
  --notes "Signed with the Wooflab team's Developer ID and notarized by Apple." >&2

# What was just published is what this Mac runs, by the same path as any other install.
MOUNT="$(mktemp -d)"
/usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null
DEST="/Applications/$APP_NAME.app"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -f "$DEST/Contents/MacOS/${APP_NAME}Watchdog" 2>/dev/null || true
rm -rf "$DEST"
/usr/bin/ditto "$MOUNT/$APP_NAME.app" "$DEST"
/usr/bin/hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
codesign --verify --deep --strict "$DEST" 2>/dev/null || { echo "the installed bundle does not verify" >&2; rm -rf "$DEST"; exit 1; }
open "$DEST"
echo "installed $DEST ($VERSION)" >&2

# The tree goes one ahead of what is now published, which is the rule every later build is held to.
NEXT="$(version_next "$VERSION")"
version_set "$NEXT"
echo "the tree is now $NEXT; commit it." >&2

echo "https://github.com/$GITHUB_REPO/releases/tag/$TAG"
