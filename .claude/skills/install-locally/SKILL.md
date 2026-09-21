---
name: install-locally
description: Use when the owner asks to install KoffeeLid on this Mac, to apply a change, to rebuild, to reinstall, to "run the app", to see a change working, or to get the newest build into /Applications. This is one of only two ways a build of this app ever reaches a Mac; the other is publish-release. Also use when about to build the app for any reason, to check first whether a build is even the right action.
---

# Install locally

**This app reaches a Mac in exactly two ways.** This skill is the first: a production build, installed in
`/Applications`, leaving nothing behind. The second is `publish-release`, which does the same and puts the
disk image on GitHub as well.

```bash
script/install.sh
```

That is the whole action. It takes about five minutes, most of it Apple's notary service.

## What it does, and why each part is not optional

1. **Refuses if quitting would sleep the Mac, and nothing overrides that.** An install quits the running app,
   which ends every arm it holds. That is only unsafe when the app is armed, the lid is shut, and no external
   display is keeping the desktop up (`quitWouldSleepTheMac`) — an open lid, an external display, or an
   unarmed app are all fine. So the warning `quitting would sleep the Mac` in `status` is a refusal with no
   override, and the script checks again after the build because the state may have changed during it.
   Otherwise it installs over any arm and puts the manual mode back afterwards, so the Mac is unarmed only for
   the seconds between the quit and the relaunch — the build and the notarizing are already done by then.
2. **Builds exactly the tree's version** (`script/version.sh`): no GitHub check, no requirement to be
   ahead of what is published. A local install always carries the same version as the code in the tree.
3. **Builds the real thing** — Release, signed with the Wooflab team's Developer ID under the Hardened
   Runtime, notarized by Apple, stapled, wrapped in the disk image. Not a shortcut, not a Debug build, not an
   unsigned one. What lands in `/Applications` is byte-for-byte what a stranger would download.
4. **Installs the bundle from inside the disk image**, so what runs is what a release would hand out,
   stapled ticket and all.
5. **Leaves nothing behind.** No `.app` and no `.dmg` anywhere under the repository when it returns,
   including when it fails. `script/no-leftovers.sh` holds that rule.

## The rule about leftovers, which is the point

A signed bundle sitting in `build/` or `DerivedData/` is a complete, working application. Spotlight indexes
it, the Finder opens it, and it runs **beside** the copy in `/Applications` as a second instance with the
same bundle identifier, the same preferences, the same launch agent and the same activity journal. Two
KoffeeLids both driving the kernel lid-sleep flag is exactly the fight `docs/pitfalls.md` warns about.

So: **only `/Applications/KoffeeLid.app` exists.** A build is a step on the way there, never a thing left
lying about. `script/install.sh` and `script/publish.sh` both clean up on every exit path. If you ever build
by another route, delete the bundle yourself before you finish.

## Never do these

| Never | Instead |
|---|---|
| Build Debug to "try something" | `script/install.sh`. Debug is refused without `DEBUG_OK=1`, and **you must ask the owner first** — see below |
| `open` a `.app` from `build/` or `DerivedData/` | Install it. Launching a build bundle is what creates a second instance |
| Leave a built bundle behind "for next time" | There is no next time; the next build makes its own |
| Skip notarizing "because it is only local" | Then the installed copy is not what a release ships, and the release path goes untested until it matters |
| Install while quitting would sleep the Mac | Open the lid, or connect an external display. The script refuses and offers no way round it otherwise |
| Leave the owner unarmed afterwards | The script restores `caffeinate`/`arm` itself; if it warns that it could not, say so plainly |

## Debug builds

A Debug build exists to read something a Release build will not show — a crash, a symbol, a log line. It is
**never installed** and it is **never made without the owner's explicit consent.** `script/build.sh Debug`
refuses unless `DEBUG_OK=1`, which is there to make the decision deliberate, not to be worked around.

If you think a Debug build would help, **ask the owner and say why.** If they agree:

```bash
DEBUG_OK=1 script/build.sh Debug
```

and delete the bundle when you are done with it.

## When it fails

**Run it again before you diagnose anything.** The first thing `script/release.sh` does is check the notary
credential with `xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"`, and that check has failed
spuriously between two installs ten minutes apart, with

```
no notarytool keychain profile 'wooflab-notary'
```

and then succeeded on the next run with nothing changed. Notarizing itself talks to Apple over the network and
can fail the same way. A step that worked minutes ago is far likelier to be flaky than broken, and going
looking costs the owner's patience and leads into parts of his machine that have nothing to do with this app.
Only a second failure is worth investigating, and then stay inside this project's own files and credentials:
the profile and the Developer ID identity are the owner's to restore, not yours to recreate.

A failed install leaves nothing behind and does not touch `/Applications`, so a retry is free.

## Checking it worked

```bash
/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid status
codesign -dvv /Applications/KoffeeLid.app 2>&1 | grep -E 'Authority=Developer|flags='
```

The authority is `Developer ID Application: Wooflab (85F6AC5QZF)` and the flags include `runtime`. The
version is whatever the tree holds, per `script/version.sh`.

## Two things the install cannot do for itself

- **The sleep lock** needs a sudoers rule and therefore root. The script prints the one-liner when the rule
  is missing. Until it is there, a charger or display change can sleep a closed armed Mac.
- **Restoring the arm** is the script's job for the manual mode only. The auto level re-establishes itself at
  the next launch from the activity journal, so a session that is still working arms the new copy at once.
- **`/usr/local/bin/koffeelid`** is only written when `/usr/local/bin` is writable; otherwise the script
  prints the `sudo` command. Call the binary inside the bundle meanwhile.

## Taking it off again

There is one way, and it is not the Finder. **Settings › General › Uninstall** removes what KoffeeLid put
outside its own bundle, moves the bundle to the Trash and quits. Dragging the bundle to the Trash removes
the app and nothing else, and what is left goes on running against an app that is gone.

The last removals belong to a detached helper that waits for the pid: anything taken away while the app is
still up is written back as it exits. Never suggest removing the pieces by hand instead, and never suggest
`launchctl disable` for the launch agent — it is permanent, and nothing but `launchctl enable` undoes it.
