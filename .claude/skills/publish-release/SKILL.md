---
name: publish-release
description: Use when the owner asks to publish, release, or ship KoffeeLid, to push a release to GitHub, to cut a version, or to make a build available for download. This is one of only two ways a build of this app ever reaches a Mac; the other is install-locally. Use it whenever a GitHub release is involved, including deciding what version to release.
---

# Publish a release

**This app reaches a Mac in exactly two ways.** This skill is the second: the same production build as
`install-locally`, tagged, pushed, attached to a GitHub release — **and installed in `/Applications` too**,
so this Mac runs what was just published.

```bash
script/publish.sh
```

It takes about five minutes, most of it Apple's notary service. It publishes; that is the point. Only run it
when the owner has asked for a release.

## What it does, in order

1. **Refuses on a dirty tree, an existing tag, or a `HEAD` that differs from `origin`.** A release names a
   commit, so the commit must exist, be pushed, and be the one you mean. All three refusals come *before*
   the build, because none is worth five minutes of notarizing to discover.
2. **Publishes exactly the tree's version** (`script/version.sh`): no requirement that it be ahead of what
   is already published — bump it by hand first if this release should carry a new version.
3. **Builds the real thing** — Release, Developer ID, Hardened Runtime, notarized, stapled, in its disk
   image. The same bytes for GitHub and for `/Applications`.
4. **Tags and pushes**, then creates the GitHub release with the disk image attached. The tag is made only
   once there is an image to attach to it.
5. **Installs it in `/Applications`**, by the same path as any other install.
6. **Raises the tree to the next patch**, so it is one ahead of what is now published. **That change is
   uncommitted — commit it.**
7. **Leaves nothing behind**: no `.app`, no `.dmg` under the repository, on every exit path.

## Publishing without installing

`--no-install` skips the install step: the release is published and `/Applications` keeps the version it is
running, which is then the version that finds the release, fetches it and installs it itself. It is the only
way to walk the path a user walks, so it is how an update is tested before anyone relies on it. Everything
else, the version rule and the raise of the tree included, is unchanged.

```bash
script/publish.sh --no-install
```

## Afterwards

The version bump in step 6 is left in the working tree on purpose, so the owner sees it. Commit it:

```
build(version): the tree moves to <next>
```

Then check the release page the script printed, and confirm an installed copy sees it:

```bash
/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid status
```

## The version rule, and why publishing is the only thing that moves it

`script/version.sh` holds the version; nothing enforces the tree being ahead of what is published. A local
install always carries exactly the tree's version (see `install-locally`). Publishing releases exactly that
version, then raises the tree to the next patch, so the version just published is never built again by
mistake — that is the only thing that ever changes the version, not a feature, not a fix, not a local
install.

## Never do these

| Never | Instead |
|---|---|
| Publish without the owner asking | A release is public and cannot be quietly undone |
| Hand-run `gh release create` | `script/publish.sh`, which builds, notarizes, tags, publishes, installs and cleans up in the right order |
| Tag before there is an image | The script tags after the build for exactly this reason |
| Attach anything but the notarized image | The updater requires a `.dmg` asset with `KoffeeLid.app` at the image's root |
| Set the version by hand | `version_set` in `script/version.sh` writes all three places that must agree |
| Leave a built bundle behind | Spotlight will offer it and it will run beside `/Applications` as a second instance |

## If it fails part way

- **Before the tag**: nothing was published. Fix and run it again.
- **After the tag, before the release**: the tag is pushed. Either `gh release create` it by hand with the
  image, or delete the tag locally and on `origin` and start over.
- **After the release**: the release exists. Deleting it is the owner's call, not yours — say what happened
  and let them decide.
