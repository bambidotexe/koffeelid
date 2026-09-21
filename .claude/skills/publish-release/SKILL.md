---
name: publish-release
description: Use when the owner asks to publish, release, or ship KoffeeLid, to push a release to GitHub, to cut a version, or to make a build available for download. This is one of only two ways a build of this app ever reaches a Mac; the other is install-locally. Use it whenever a GitHub release is involved, including deciding what version to release.
---

# Publish a release

**This app reaches a Mac in exactly two ways.** This skill is the second: the same production build as
`install-locally`, tagged, pushed, attached to a GitHub release — **and installed in `/Applications` too**,
so this Mac runs what was just published.

```bash
script/publish.sh <patch|minor|major>
```

The level is required: `patch` for a fix, `minor` for a new feature, `major` for a breaking change. If the
owner has not said which, ask before running it — this is the one call that names what a release is. It
takes about five minutes, most of it Apple's notary service. It publishes; that is the point. Only run it
when the owner has asked for a release.

## What it does, in order

1. **Refuses on a dirty tree.** A release names a commit, and the version bump below is about to add one, so
   whatever is already there must be resolved first.
2. **Bumps the version by the level given, commits that alone, and pushes it** (`script/version.sh`): the
   tree held exactly the last published version until now, so this is the only version change in the whole
   flow. `git push` happens before anything is built, so the commit this script tags always carries the
   version it releases.
3. **Refuses if that version's tag already exists**, locally or on GitHub — checked *before* the bump, so a
   collision costs nothing.
4. **Builds the real thing** — Release, Developer ID, Hardened Runtime, notarized, stapled, in its disk
   image. The same bytes for GitHub and for `/Applications`.
5. **Tags and pushes**, then creates the GitHub release with the disk image attached. The tag is made only
   once there is an image to attach to it.
6. **Installs it in `/Applications`**, by the same path as any other install.
7. **Leaves nothing behind**: no `.app`, no `.dmg` under the repository, on every exit path.

Nothing bumps the version again afterward. The tree sits at exactly what was just published until the next
`publish.sh <level>` — a local install (`install-locally`) always carries that same version.

## Publishing without installing

`--no-install` skips the install step: the release is published and `/Applications` keeps the version it is
running, which is then the version that finds the release, fetches it and installs it itself. It is the only
way to walk the path a user walks, so it is how an update is tested before anyone relies on it. Everything
else is unchanged.

```bash
script/publish.sh <patch|minor|major> --no-install
```

## Afterwards

Check the release page the script printed, and confirm an installed copy sees it:

```bash
/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid status
```

Nothing is left to commit — the version bump was already committed and pushed before the build started.

## The version rule, and why publishing is the only thing that moves it

`script/version.sh` holds the version; nothing enforces the tree being ahead of what is published. A local
install always carries exactly the tree's version (see `install-locally`). Publishing is the only thing that
ever changes it: it bumps the tree by the level asked for, commits and pushes that bump, then releases
exactly that version — not a feature, not a fix, not a local install.

## Never do these

| Never | Instead |
|---|---|
| Publish without the owner asking, or guess the level | A release is public and cannot be quietly undone; ask patch/minor/major if it is not obvious |
| Hand-run `gh release create` | `script/publish.sh <level>`, which bumps, commits, builds, notarizes, tags, publishes, installs and cleans up in the right order |
| Tag before there is an image | The script tags after the build for exactly this reason |
| Attach anything but the notarized image | The updater requires a `.dmg` asset with `KoffeeLid.app` at the image's root |
| Set the version by hand | `version_set` in `script/version.sh` writes all three places that must agree; the script calls it, never you |
| Leave a built bundle behind | Spotlight will offer it and it will run beside `/Applications` as a second instance |

## If it fails part way

- **Before the version-bump commit**: nothing changed. Fix and run it again.
- **After the bump is committed and pushed, before the tag**: the tree already carries the new version.
  Either fix the problem and run `script/publish.sh <level>` again — it will bump *again* from here, which is
  wrong — or, more often, just re-tag and release by hand from the commit that is already there
  (`git tag -a v<version> -m "KoffeeLid <version>"`, push the tag, `gh release create`).
- **After the tag, before the release**: the tag is pushed. Either `gh release create` it by hand with the
  image, or delete the tag locally and on `origin` and start over.
- **After the release**: the release exists. Deleting it is the owner's call, not yours — say what happened
  and let them decide.
