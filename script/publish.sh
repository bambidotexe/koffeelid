#!/bin/zsh
# **Release to GitHub.** The other of the two ways a build of this app ever reaches a Mac.
#
#   script/publish.sh <patch|minor|major> --notes=<file> [--install]
#
# Bumps the version by the given level, commits and pushes that alone, then tags the commit, attaches the
# signed and notarized disk image to a GitHub release; with `--install` it also installs the same bundle
# in /Applications. The tree is left exactly at the version just published — nothing bumps it further, so
# a later local install carries the same version until someone next runs this script. It leaves nothing
# behind: no .app and no .dmg anywhere under the repository.
#
# `--notes=<file>` is required: the release's description, in Markdown, written for the people who install
# the app from the commits since the last tag (skill `macos-publish-release`, *Release notes*), published
# as it is. The file lives outside the repository, which must stay clean.
#
# /Applications is left alone unless `--install` is passed, and that flag is passed only when the owner has
# asked for the release to be installed here. Left alone, the Mac stays on the version it runs, and that
# version finds the release and installs it itself, the way the users get it.
#
# The other way is script/install.sh, which does everything but the publishing.
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/script/signing.env"
source "$ROOT/script/version.sh"
source "$ROOT/script/no-leftovers.sh"

LEVEL=""
INSTALL=0
NOTES=""
for arg in "$@"; do
  case "$arg" in
    patch|minor|major) LEVEL="$arg" ;;
    --install) INSTALL=1 ;;
    --notes=*) NOTES="${arg#--notes=}" ;;
    *) echo "unknown argument: $arg (patch, minor, major, --notes=<file>, --install)" >&2; exit 1 ;;
  esac
done
[ -n "$LEVEL" ] || { echo "usage: script/publish.sh <patch|minor|major> --notes=<file> [--install]" >&2; exit 1; }
[ -n "$NOTES" ] && [ -s "$NOTES" ] || { echo "refusing: no release notes. Read the commits since the last tag and write what they change for the people who install the app, then pass --notes=<file>." >&2; exit 1; }

# Whatever happens — a refused release, a failed build, an interrupt — the repository is left with nothing
# launchable in it. The named paths keep the build tree tidy; the sweep is what enforces the rule.
cleanup() {
  rm -rf "$ROOT/dist" "$ROOT/build/Build" "$ROOT/DerivedData/Build/Products"
  no_leftovers "$ROOT"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------------------------------------
# A release names a commit, so everything it names has to be committed and pushed — including the version
# bump this script makes itself, below. This refusal comes before the bump and the build: dirty is not this
# script's to resolve, and none of what follows is worth five minutes of notarizing to discover it was.
# ---------------------------------------------------------------------------------------------------------
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "refusing: the working tree is dirty. Commit first — a release names a commit." >&2; exit 1; }

VERSION="$(version_bump "$LEVEL" "$(version_tree)")"
TAG="v$VERSION"
git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "refusing: $TAG already exists." >&2; exit 1; }
[ -z "$(gh release view "$TAG" -R "$GITHUB_REPO" --json tagName -q .tagName 2>/dev/null)" ] || { echo "refusing: a release $TAG already exists on GitHub." >&2; exit 1; }

# The bump is its own commit, pushed before anything is built: the commit this script tags is the commit
# that carries the version it releases, so nobody ever sees a tag whose bump is missing from the branch.
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
version_set "$VERSION"
git -C "$ROOT" add App/Info.plist Sources/KoffeeLidCore/KoffeeLidCore.swift Tests/KoffeeLidCoreTests/SmokeTests.swift
git -C "$ROOT" commit -q -m "build(version): the tree moves to $VERSION"
git -C "$ROOT" push -q origin "$BRANCH"

echo "releasing $APP_NAME $VERSION" >&2
DMG="$("$ROOT/script/release.sh")"

# The tag is made and pushed only once there is an image to attach to it.
git -C "$ROOT" tag -a "$TAG" -m "$APP_NAME $VERSION"
git -C "$ROOT" push -q origin "$TAG"
gh release create "$TAG" "$DMG" -R "$GITHUB_REPO" --title "$APP_NAME $VERSION" \
  --notes-file "$NOTES" >&2

# With `--install`, what was just published is what this Mac runs, by the same path as any other install:
# script/install.sh with the image it would otherwise build, so the refusal while quitting would sleep the
# Mac, the sleep lock held across the relaunch and the mode put back are the same. A refusal leaves the
# release published and /Applications as it was. Without the flag, the app already on the Mac finds the
# release and installs it itself.
if [ "$INSTALL" -eq 1 ]; then
  "$ROOT/script/install.sh" --dmg="$DMG" || {
    echo "the release $VERSION is published; /Applications was left as it was (see above). The copy running there will offer it, or run script/install.sh once the lid is open." >&2
    exit 1
  }
else
  echo "/Applications is untouched: the copy running there is what this release is offered to." >&2
fi

echo "https://github.com/$GITHUB_REPO/releases/tag/$TAG"
