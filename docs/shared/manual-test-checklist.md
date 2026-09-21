# What only a person can see, in every app

The walks every app of the family repeats, because the app target has no automated tests. An app's own
`docs/manual-test-checklist.md` holds the feature's walks and points here for these. Work down the relevant
section after any change to that surface, and note anything that surprises you in the app's `pitfalls.md`
(or, if any app could hit it, in the shared one).

```sh
swift run axprobe elements <App>     # the front window's element tree, with every frame
swift run axprobe hit <x> <y>        # what a real hit test finds at a point
/usr/bin/log stream --predicate 'subsystem == "<bundle id>"' --level debug
```

---

## 1. The onboarding wizard

**What it looks like**

- [ ] **First launch.** The pages in order, each stepped by the one button at the bottom right: the pitch
      with the icon, the accent on one word and the capsules; each list page; **All set**. Nothing is cut
      off, nothing is truncated, every sentence wraps.
- [ ] The height follows the page around its **top-left** corner: the title bar does not move, the bottom
      edge does. No page is stretched or crowded.
- [ ] The button reads **Skip** on a list page until its rule is met (every required grant; or any one row
      of an optional page). It turns to **Continue** without the page being redrawn: the header and the
      other rows do not move.
- [ ] **Press it after a row has changed.** On a list page, press **Skip** before granting or turning
      anything on: it advances. Come back, change a row, and press **Continue** **without closing the
      window**: it advances on the **first** click. A button that does nothing here is the shared pitfalls'
      O9, whatever it looks like: `swift run axprobe hit <x> <y>` over it answers the window rather than the
      button, and the `onboarding` log category at `--level debug` says `DOES NOT CONTAIN`.
- [ ] Return presses the button on every page.
- [ ] The whole wizard in **French** and in **English**, and every quoted name word for word against System
      Settings: *Open at Login* in Login Items & Extensions, and each permission's title in its pane.

**The permission** (an app that has one)

- [ ] **No prompt appears by itself, ever.** Launch with the permission missing and leave the wizard open
      for a minute: no dialog. Reach *All set* having granted nothing, Finish, quit, and launch twice more:
      still none. Every prompt in the whole walk followed a click of yours.
- [ ] Press **Allow…**: **only** the system's dialog, never System Settings alongside it. Refuse it, then
      press again: nothing new opens, and the button does not change its name.
- [ ] Grant it in System Settings **without touching the app**: within about two seconds the row reads
      *Granted*, the button turns to *Continue*, **the wizard stays open**, and the app starts working.
      **No relaunch.**
- [ ] **Take the grant away** while the app runs: the app stops and says so; the wizard comes back if the
      app cannot work without it, and **its row reads the grant as missing from that moment**, whatever
      macOS's cached answer still claims. Grant it again: it starts again. With the wizard already up, it is
      not replaced. **In an app that holds an event tap this step is the owner's, behind a dead-man's
      switch** (`macOS.md`, *Working on the owner's Mac*), and never an agent's.
- [ ] Settings › System while all of that happens: the row follows within two seconds, and the button and
      the warning appear and disappear with it.

**Where it lives**

- [ ] **Turn On** beside *Open at Login*: the row reads *Enabled* and offers *Turn Off*, and the app is in
      System Settings › General › Login Items under *Open at Login*. Turn it off again: both agree.
- [ ] **Show in menu bar**: *Turn Off* takes the icon away and the row offers *Turn On*; Settings › General
      agrees with it.

**Who is in front**

- [ ] The wizard opens in front. Click another app's window: it goes behind and **stays** there. Switch to
      another Space and back: still in front of what it was in front of.
- [ ] Press a grant button, then use the system dialog's own button to open System Settings: the pane comes
      forward and **stays**. Grant it with the pane still open: the row ticks over with the wizard still
      behind.
- [ ] **Close the System Settings window**: the wizard comes back in front of what it was in front of. Leave
      it open and click another app instead: the wizard does not move.
- [ ] An administrator dialog of the app's own opens over the wizard and stays until answered; accept
      **and** cancel both bring the wizard back.
- [ ] `open -b <bundle id>` brings the wizard forward, not Settings. Open Settings as well (⌘, from the
      menu-bar item), then activate the app: **Settings** comes forward, not the wizard.
- [ ] Closing the wizard gives the front back to whoever had it, and keystrokes go to that app. Closing it
      with Settings still open leaves the app active.

**When it opens**

- [ ] Finish it once, quit, launch again by hand: **no wizard**, the Settings window instead. Open the app
      again while it runs: the Settings window, not the wizard.
- [ ] Close it with the × **before** *All set*, quit, launch again: the wizard is back, at page one. Close
      it again and open the app from the Applications folder while it still runs: the wizard, not Settings.
- [ ] **Settings › System › Start over**: a fresh wizard at page one, with every row re-read.
- [ ] **Launch at login** on, wizard never finished, log out and in: the app starts and **opens no window**.
- [ ] `make install` over a running copy: no window, wizard included.

## 2. The Settings window

- [ ] Open Settings and click through every toolbar item: **General** first, the feature pages, **System**,
      **Tip** last, each a symbol above its title, the shown one highlighted, and the window's title
      following it. The window opens on General already at its size and centred, with no jump; on every
      switch its bottom edge moves, animated, and its top-left corner does not. A page taller than the screen
      allows scrolls, the window stopping short of the display's height.
- [ ] Read any page: every group is a bold title, a card of rows, and *under* the card a grey hint, then
      orange warnings, then blue notes, never text inside a card (the Tip page's two cards excepted).
      **Nothing is smaller than the body text**, there is no radio button anywhere, keys read **⌥ Option**
      and **⌘ Command**, and no sentence carries a long dash.
- [ ] General: the app icon alone at the top, centred, 144 pt. No hint under Updates or under Quit; one
      blue note under Startup naming the Applications folder and Spotlight.
- [ ] **Launch at login** on, log out and in: the app starts and **opens no window**. Turn it off in System
      Settings without opening the app: the switch reads off within two seconds of the window opening.
- [ ] **Show in menu bar** off: the icon goes and the app keeps working. Open the app again from the
      Applications folder: the Settings window comes back.
- [ ] A permission group on System (if any): the row, and while it is denied a button to the pane and a
      warning naming the switch word for word; once granted both go and the row stays.
- [ ] Every setting survives a quit and relaunch. A silent revert to a default means the setting is missing
      from `Settings.init(from:)`.
- [ ] **Settings › Tip**: the toolbar's mug, the app icon beside the sentence, the Ko-fi cup on its red wash,
      and *Tip €5*. The button opens `ko-fi.com/bambidotexe` in the browser and the window stays put.
- [ ] Turn **Show in menu bar** off, then press **Quit <App>**, the last group but one of General: the app
      is gone, `pgrep -x <App>` finds nothing. Reopen it and it comes back with Settings.
- [ ] `make install` over a running copy: the app is replaced and **opens no window**, and every grant
      survives.
- [ ] The whole window in **French** and in **English** (System Settings › General › Language & Region, the
      per-app list).

## 3. Updates

Walk the whole thing offline, with a stand-in for GitHub. The helper's own account is
`~/Library/Application Support/<App>/updates/install.log`.

```sh
# a release JSON and a disk image on this Mac (make-dmg.sh with a higher VERSION in a scratch copy)
cat > /tmp/latest.json <<JSON
{"tag_name": "9.9.9",
 "assets": [{"name": "<App>-9.9.9.dmg",
             "browser_download_url": "file:///tmp/<App>-9.9.9.dmg",
             "size": 0}]}
JSON
<APP>_UPDATE_FEED=file:///tmp/latest.json /Applications/<App>.app/Contents/MacOS/<App>
```

- [ ] Settings › General › Updates, *Check for Updates*: a spinner and **Checking**, then the row reads
      **Version 9.9.9 is available** and the button becomes **Update**, prominent and blue. Log (`update`):
      one `check (asked)` line.
- [ ] The automatic check, twenty seconds after launch, posts **one notification** (macOS asks to allow
      notifications once, on that first announcement). Clicking it, or its **Update** button, opens the
      update window; pressing **Update** in Settings brings the same window forward, not a second one.
- [ ] The window: **Downloading: … of …** with the bar moving, then *Preparing the update*, then *Ready to
      install. <App> will quit and reopen.*, and **Install and Relaunch** turns blue only then. Log:
      `downloaded`, `staged`, `ready to install`.
- [ ] **Cancel**, and the window's close button, mid-fetch: the window goes, `cancelled` in the log, and
      `updates/` holds no `.dmg` and no `staged`.
- [ ] A wrong `digest` in `latest.json`: **Update failed: The download is damaged.** and **Try Again**.
- [ ] An image built with `SIGN_IDENTITY=-`: **Update failed: The update is not signed by the same
      developer.**
- [ ] An image whose version is not higher: **Update failed: The disk image does not hold a newer version.**
- [ ] **Install and Relaunch**: the app quits, the new version starts, and the window that opens says *The
      update is installed. <App> is running the new version.* with **Done**, and **nothing else opens
      behind it**; every grant still holds; `install.log` ends with `version … is running`;
      `updates/previous` is gone.
- [ ] Quit the new version within two seconds of its relaunch: it stays quit and stays updated.
- [ ] An image whose executable has been replaced by `exit 1` before signing: the previous version comes
      back by itself, its window says *Version … was not installed. The new version did not start, so the
      previous one was put back.* with **Close**, and Settings › General carries the same reason as an
      orange mark.
- [ ] The app run from a read-only folder: after the fetch the window offers **Open Disk Image**.
- [ ] Turn Wi-Fi off and press **Check for Updates**: an orange **Could not check: …** with a reason, within
      15 s, wrapped and aligned right; the button is enabled again.
- [ ] With no feed set and no release published: the row says **No release published yet** on a press, and
      an automatic check says nothing at all.

## 4. Uninstall

- [ ] Settings › General › **Uninstall**: a grey hint, and under it an orange warning that always stands
      there.
- [ ] Press it, confirm: an alert says what could not be done, or that the app is in the Trash, and the app
      exits.
- [ ] About 5 s later: `/Applications/<App>.app` is in the Trash; `defaults read <bundle id>` fails and
      `~/Library/Preferences/<bundle id>.plist` does not exist at all (not an empty one);
      `~/Library/Application Support/<App>`, `~/Library/Caches/<bundle id>` and
      `~/Library/HTTPStorages/<bundle id>` are gone; System Settings › General › Login Items shows no
      <App>; each pane the app had a grant in shows no <App>.

## 5. Language

- [ ] With the Mac in French: every window, the menu, the notification and the update window in French.
- [ ] `defaults write <bundle id> AppleLanguages '("en")'`, relaunch: everything in English; `defaults
      delete <bundle id> AppleLanguages`, relaunch: French again.
- [ ] The app is listed in System Settings › General › Language & Region › Applications.
