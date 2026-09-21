#!/bin/zsh
# The version rule, and the only place that knows where the version is written.
#
#   source script/version.sh
#   version_tree                 the version this tree builds
#   version_next <x.y.z>         that version with its patch raised by one
#   version_set  <x.y.z>         write it everywhere it must agree
#
# A local install always builds and installs exactly the tree's own version — the same version production
# runs, until the tree is next bumped. Publishing is the only thing that moves the version: it releases the
# tree's version as it stands, then raises the tree to the next patch so that version is never built again.
set -uo pipefail
VERSION_ROOT="${0:A:h:h}"

# Where the version is written. All of these must agree; `version_set` is what keeps them agreeing.
#   App/Info.plist                              CFBundleShortVersionString, and CFBundleVersion with it
#   Sources/KoffeeLidCore/KoffeeLidCore.swift   the constant the app reports
#   Tests/KoffeeLidCoreTests/SmokeTests.swift   the assertion that catches the other two drifting
version_tree() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERSION_ROOT/App/Info.plist"
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
