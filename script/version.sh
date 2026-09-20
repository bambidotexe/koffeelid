#!/bin/zsh
# The version rule, and the only place that knows where the version is written.
#
#   source script/version.sh
#   version_tree                 the version this tree builds
#   version_published            the newest release on GitHub, or 0.0.0 when there is none
#   version_next <x.y.z>         that version with its patch raised by one
#   version_set  <x.y.z>         write it everywhere it must agree
#   version_check                say whether the tree holds published + 1, and what to do if not
#
# **The tree is always one patch ahead of what is published.** A local install therefore carries a version
# no release can offer, so the installed copy is never told to replace itself with something older, and the
# copy on this Mac is always the newest that exists. Publishing makes the tree's version the published one,
# and raises the tree again.
set -uo pipefail
VERSION_ROOT="${0:A:h:h}"

# Where the version is written. All of these must agree; `version_set` is what keeps them agreeing.
#   App/Info.plist                              CFBundleShortVersionString, and CFBundleVersion with it
#   Sources/KoffeeLidCore/KoffeeLidCore.swift   the constant the app reports
#   Tests/KoffeeLidCoreTests/SmokeTests.swift   the assertion that catches the other two drifting
version_tree() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERSION_ROOT/App/Info.plist"
}

version_published() {
  local tag
  tag="$(gh release list -R "$GITHUB_REPO" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null)"
  # No release, no network, no repository: all read as nothing published, which makes the tree's 0.0.1 right.
  [ -n "$tag" ] || { echo "0.0.0"; return }
  echo "${tag#v}"
}

version_next() {
  local v="${1:?version_next <x.y.z>}"
  local major="${v%%.*}" rest="${v#*.}" minor patch
  minor="${rest%%.*}"; patch="${rest#*.}"
  echo "$major.$minor.$((patch + 1))"
}

version_set() {
  local v="${1:?version_set <x.y.z>}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $v" "$VERSION_ROOT/App/Info.plist"
  # A build number that only ever rises, so a rebuild of the same version is still the newer bundle.
  local build
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$VERSION_ROOT/App/Info.plist")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((build + 1))" "$VERSION_ROOT/App/Info.plist"
  /usr/bin/sed -i '' -E "s/(public static let version = \")[^\"]*(\")/\1$v\2/" \
    "$VERSION_ROOT/Sources/KoffeeLidCore/KoffeeLidCore.swift"
  /usr/bin/sed -i '' -E "s/(XCTAssertEqual\(KoffeeLidCore\.version, \")[^\"]*(\"\))/\1$v\2/" \
    "$VERSION_ROOT/Tests/KoffeeLidCoreTests/SmokeTests.swift"
}

# Prints the version a build should carry and returns 0; prints why it cannot and returns 1.
version_check() {
  local tree published wanted
  tree="$(version_tree)"; published="$(version_published)"; wanted="$(version_next "$published")"
  if [ "$tree" = "$wanted" ]; then echo "$tree"; return 0; fi
  # Ahead of the rule is a tree someone has already raised further; that is theirs to keep.
  if [ "$(printf '%s\n%s\n' "$wanted" "$tree" | sort -V | tail -1)" = "$tree" ]; then echo "$tree"; return 0; fi
  echo "the tree is at $tree, but $published is published: a build must be $wanted or newer." >&2
  echo "  script/version.sh holds the rule; 'version_set $wanted' writes it everywhere." >&2
  return 1
}
