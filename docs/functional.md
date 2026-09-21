# What KoffeeLid does

KoffeeLid is a macOS menu-bar app (bundle id `dev.rubens.koffeelid`, no Dock icon) that keeps a MacBook
running with the lid closed. It can be armed by hand, for one close with a lid gesture, or by itself while
Claude Code or a terminal command is working. While armed it darkens the built-in panel when the lid shuts,
plays a sound, shows a closing-only "the desktop stays upright behind the glass" effect, and locks the screen
when the lid reopens. A `koffeelid` command line, `koffeelid://` URLs and App Intents drive the same modes.
English and French; it looks for a newer release on GitHub by itself and installs one on request; no licensing.

This document is the authority on behaviour: what it says is what the app does today. It changes in the same
commit as the code, an outdated rule is replaced rather than annotated, and a request that contradicts a rule
written here is put to the owner before anything is implemented (`CLAUDE.md` § Changing behaviour).

## Modes and arming

Three manual modes (`ArmMode`):

| Mode | Lid closed | Lid open |
|---|---|---|
| **Off** | the Mac sleeps (macOS default) | nothing |
| **Armed** | the Mac keeps running, panel dark | nothing extra |
| **Armed + screen on** (`caffeinate` in code and CLI) | same as Armed | the display never idle-sleeps, no screen saver, no auto-lock |

Independent of the manual mode there is an **auto level** (`ActivityArmPolicy.isOn`): on while Claude Code or a
terminal command works, and through a hold-off afterwards. **The Mac is armed while either the manual mode or
the auto level holds it.** Neither changes the other.

| Way to arm | What it does |
|---|---|
| Menu (left-click the cup) | picks Off / Armed / Armed + screen on; the current one is checked |
| Right-click the cup | Off → Armed → Armed + screen on → Off; an armed mode that has stood 3 s or more goes straight to Off |
| ⌃⌥⌘L | toggles Armed (from Armed + screen on: switches to Armed) |
| ⌃⌥⌘K | toggles Armed + screen on (from Armed: switches to it) |
| `koffeelid arm \| off \| caffeinate \| toggle-armed \| toggle-caffeinate`, `koffeelid://<verb>`, App Intents | same transitions; `disarm` and `toggle` are accepted as aliases of `off` and `toggle-armed` |
| Fn (Globe) + close the lid | arms **one close** (below); Option can replace Fn |
| Claude Code hooks / zsh snippet | raise the auto level (below) |
| An update's Install and Relaunch | the new version goes back to the manual mode that was on at the click (§ Updates) |

Every manual source stays in its mode until changed. Switching Armed ↔ Armed + screen on happens in place;
the kernel flag is not touched. Choosing a manual mode over an auto-only arm makes the arm manual as well.

**Off from the user** (menu, right-click, shortcut, CLI, URL, intent) sets the manual mode to Off. The session
ends unless the auto level is on, in which case the Mac stays armed by the auto level alone.

### Arming can be refused

`ArmingPolicy` refuses, in this order: the display list cannot be read; thermal pressure is serious or
critical; the low-battery option is on, the Mac is on battery and the charge is at or below the threshold. A
failed kernel-flag write refuses too. The user gets a "KoffeeLid did not arm" notification with the reason;
the CLI prints `did not arm: …` and exits 1. An external display does not refuse an arm.

### The lid gesture (one-close arm)

With the lid gesture on (Settings › Arming › Lid gesture) and a lid-angle sensor present:

- Hold the modifier and start closing. After "Arm after closing by" degrees of closing travel (default 4°) the Mac
  arms in Armed mode with source `gesture`. The modifier may be released up to 1 s before that travel is
  reached. The gesture is cancelled if the modifier is released for more than 1 s before the travel is
  reached, if the lid reopens by "Cancel when reopened by" degrees (default 4°), or if a started close stalls
  for 1.5 s.
- Before the lid shuts, the arm is cancelled by reopening the lid by "Cancel when reopened by" degrees from the
  lowest angle reached, or by holding the lid still for the effect's "Flatten again when still for" delay.
  Stillness does not count while the modifier is held.
- Once the lid has shut, the arm **survives the lid opening** and ends when the user logs back in. The reopen
  locks the screen; the lock landing starts the hold; the unlock releases it. Closing and reopening the lid in
  between keeps the Mac awake; those closes play the sound but no effect. If no lock ever takes (no login
  password), the arm ends at that reopen instead.
- A one-close arm switched in place to another mode (for example with ⌃⌥⌘K) becomes a manual arm.
- Fn + close while already armed from another source does not arm again: the effect follows the lid from the
  current angle as visual confirmation, and the mode is unchanged.
- The detector is off while an external display is connected, while the lid is closed, and during a one-close
  arm.

Arrow keys, F1–F12 used as function keys and an external keyboard's navigation keys carry the same modifier
flag as Fn; a reading counts as Fn only without the numeric-pad flag and with the physical Fn key (virtual key
63) down. With the Input Monitoring grant KoffeeLid also reads the built-in keyboard's own Fn key, and only that
key counts: an external keyboard's Fn/Globe key never arms. Without the grant any keyboard's Fn key counts.

### Auto-arm on activity

Off by default ("Arm while Claude Code or a terminal command is running", Settings › Auto-Arm). Setting up
either hook from that page or from the onboarding turns it on.

- **Claude Code**: 15 hook events in `~/.claude/settings.json` run the embedded `KoffeeLidHook hook`, which
  appends one trimmed line per event to `~/Library/Application Support/KoffeeLid/activity.jsonl`. A session
  counts as working from a prompt or tool event until its `Stop`. A session blocked on a question, a plan
  approval or a permission does not count. A `Stop` while helpers or background shells are still out keeps the
  turn running until they finish or fall silent (240 s per helper, 90 s grace, 30 min cap).
- **Terminal (zsh)**: a `preexec`/`precmd` snippet in `~/.zshrc` reports each command. A command counts once it
  has run longer than "Ignore commands shorter than" (default 5 s, `KOFFEELID_ARM_AFTER` per shell).
  Interactive programs listed in `KOFFEELID_SKIP` (editors, pagers, `ssh`, `tmux`, `top`, `claude`, …) never count.
- **Without an end event**: a Claude process or shell that exits drops its sessions and jobs at once (kqueue). A
  turn ended with Esc or Ctrl-C fires no hook; Claude Code's own `sessions/<pid>.json` record going `idle`
  ends it within about 35 s, and an `idle_prompt` or `agent_needs_input` notification after 50 s of
  main-agent quiet ends it too. Anything silent for 2 h is dropped.
- **The level rises** the moment something counts and the feature is on: an idle Mac arms (Armed, source
  `activity`); an already armed Mac is unchanged.
- **The level falls** after the longest hold-off among the kinds that ran during the stretch: 30 min after
  Claude Code, 1 min after a command (Settings › Auto-Arm). Work that resumes inside the wait cancels it. Keyboard,
  trackpad or mouse input at the Mac after the work ended drops the level at once: the wait exists for a
  remote user. When the level falls the Mac disarms only if the manual mode is Off.
- **"Disarm once finished"** (menu item, present when a hook is set up): the wait becomes one minute and the
  manual mode is released with it. It stays pending until it fires, is clicked again, or a safety rail fires.
- After a safety rail or a refused auto-arm, the level stays off until the running work stops and something
  starts again.
- `KOFFEELID_DISABLE=1` in a process's environment silences the hook binary; `KOFFEELID_DISABLE_ACTIVITY=1`
  in the app's environment turns the whole feature off.

## Lid closed, lid open

| Event while armed | What happens |
|---|---|
| Lid closes | the effect stops; the built-in panel's brightness goes to zero (previous level saved first; fallback `pmset displaysleepnow`); the lid-close sound plays if enabled, at the forced volume if enabled; Armed + screen on stops declaring user activity |
| Lid opens | brightness restored; the display list is re-read; the screen locks (`SACLockScreenImmediate`, retried after 0.5, 1, 2, 4 and 8 s until macOS reports the session locked, then a notification if it never does); the effect is prepared again; the arm stands |
| Lid opens, not armed | a saved brightness is restored |

The lock on reopen is not a preference.

## External display

An arm is allowed and the kernel flag stays set, but darkening, the sound, the effect, the lock on reopen and
the gesture **stand by** while any external display is online; the menu header and the tooltip say "Standing
by: external display". Connecting a display while the lid is closed locks the screen at once. Connecting one
ends a one-close arm that has not closed yet. Disconnecting restores the lid behaviours. A display that went
away behind a closed lid still locks the reopen (the list is re-read at lid open, and a lock skipped for a
display that disappears within 2 s is issued after all).

## Power and safety rails

| Condition | Effect |
|---|---|
| Low-battery option on, on battery, charge ≤ threshold (default 10 %, 5–50 %) | nothing arms; an armed session disarms with a notification. On AC everything is allowed; unplugging below the threshold disarms at once. A missing battery reading with the option on disarms too |
| Thermal pressure serious or critical | nothing arms; an armed session disarms with a notification |
| Another app or the user sleeps the Mac (`pmset sleepnow`, Apple menu) | the session disarms with a notification |
| macOS starts a lid sleep behind the arm (charger plugged, display change) | with the sleep lock set up this never starts. Without it the session is held in dark wake, the flag is re-applied and a notification explains; more than 3 such holds in 120 s disarms |
| Kernel flag cannot be cleared on disarm | the cup turns orange, a notification is posted, the clear is retried every 30 s |
| Crash or kill | the watchdog relaunches the app (at most 3 times in 10 min); the launch clears the flag, restores brightness and releases the sleep lock |
| Quit | everything is released; the flag clear is attempted three times |

There is no maximum arm duration. The rails end the manual mode and the auto level together.

## The lid effect

Available with a lid-angle sensor, the Screen Recording grant and the effect switched on (Settings › Lid
Effect). It plays only while the
lid closes, only on the built-in display, and captures nothing while the lid rests.

- **Start.** While armed with the lid open, the effect is prepared (invisible overlay, paused renderer). A fold
  begins when the lid has closed "Arm after closing by" degrees past its rest angle; for arms that did not come
  from the gesture it also waits until the lid is below "Otherwise, start below" (default 75°), so
  adjusting the screen while working starts nothing. A still image appears at once, then a 60 fps capture.
- **Shape.** The desktop behaves like an inner screen standing upright at "With the lid gesture, start below"
  (default 95°): the fold shown is that angle minus the lid angle, capped at 80°. A fold that begins lower
  catches up with that curve over at most 30° of travel. Reopening plays it backward.
- **Reset.** A lid left part-way closed and still (less than 1.5° of movement) for "Flatten again when still
  for" (default 0.5 s) eases back to flat over 0.6 s; its position becomes the new rest angle, and the capture
  stops 0.75 s later. The reset is evaluated on every lid-angle sample (30 Hz), in every mode. While the
  gesture modifier is physically held, stillness does not count: the fold stays until the key is released.
- **End.** The lid shutting, a disarm or switching the effect off stops it at once. An external display
  connecting and a cancelled one-close arm retract the plane over 0.3 s (at once if no fold is showing).
- Settings › Lid Effect › Preview › "Simulate a Fold" previews a 35° fold over 2 s, armed or not
  (`EffectController.previewFoldDegrees`, `previewFoldSeconds`).

## User interface

- **Menu-bar cup.** Four glyphs: empty (Off), closed eyes (auto-armed only), sleepy eyes (Armed), round eyes
  (Armed + screen on). A manual mode always wins over the auto glyph. Orange = the kernel flag could not be
  cleared. Optional lid angle next to it. "Show in menu bar" off hides the cup and nothing else: every arming
  path that does not go through it (the gesture, the two shortcuts, auto-arm, the CLI, URLs, App Intents) and
  every armed behaviour work exactly as before; right-clicking to arm and the lid angle simply have no icon
  left to use.
- **Menu.** Header with the mode; a greyed line while the auto level holds ("Auto-armed while Claude Code
  works", "… while a command runs", "… and a command run", or "Auto-armed, off in N min"); the three modes;
  "Disarm once finished"; Settings…; Quit.
- **Opening the app.** KoffeeLid has no Dock icon. Opening it again from Finder, Spotlight, the Applications
  folder or `open -b dev.rubens.koffeelid` while it runs opens Settings — the way back in when the menu-bar
  cup is hidden, alongside `koffeelid settings`. A launch that starts the app (at login, from the watchdog,
  from the CLI) opens nothing, and neither does an open request that arrives while an install's outcome is
  still unread: that one is the update helper's, not a person's (§ Updates).
- **Settings.** One window with seven pages, picked from a toolbar that draws each page's symbol above its
  title; the window's title is the shown page's. It is 640 pt wide and as tall as the shown page: it resizes
  around its top-left corner, animated, on a page switch and whenever a page gains or loses a line, never past
  the display's visible height less 140 pt (beyond that the page scrolls). It opens on General, sized then
  centred, and is built once and re-shown. Every change is written as it is made; there is no Apply.

  | Page | Groups |
  |---|---|
  | General | the app icon; Startup (launch at login, show in menu bar, and a note naming the way back to this window once the icon is hidden); Updates; Quit ("Quit KoffeeLid" is the menu's Quit: disarms, clears the kernel flag, releases the sleep lock, then exits); Uninstall (see below) |
  | Arming | Lid gesture (the switch, the key to hold, the two travels); Menu bar and shortcuts (right-click, the two shortcuts); Low battery (the switch and its level) |
  | Auto-Arm | While you work (the switch, what counts as running right now); Claude Code and Terminal (each hook's state, the button that sets it up or removes it, its waits) |
  | Lid Effect | Effect (the switch, and the Screen Recording grant while it is on); Lid angle (the live angle, the angle in the menu bar); When it starts; Look; Preview (reset to defaults, simulate a fold) |
  | Sound | Lid-close sound (the switch, and the clip as a pop-up menu: picking one plays it); Volume (the forced volume and its level) |
  | System | Staying awake safely (sleep lock, Login Items approval); Permissions (Screen Recording, Input Monitoring, Notifications); Compatibility (lid-angle sensor); Diagnostics (the log's switch, open the log); Start over (show the onboarding again, reset everything) |
  | Tip | a card with no title: the app icon beside the sentence saying every feature is free and stays free, and that a coffee is how the project is supported; One-time tip (the Ko-fi cup on its own red wash, "A cup of coffee" and what it is, and a button naming the smallest tip the page takes, `SupportLink.smallestTip`, 5 €). The button opens https://ko-fi.com/bambidotexe in the browser; the app sets nothing and reads nothing back, and nothing is paid inside it |

  A group is a title, a card of rows, and under the card a grey hint, then orange warnings, present only while
  something is to be fixed, then blue notes. A row is a control and its label and nothing else, and nothing
  explanatory goes inside a card. **The Tip page is the one exception, and the owner asked for it**: its first
  card has no title and holds a picture and a sentence, and its second holds a picture, two sentences and a
  button. A control that
  depends on a switch that is off is disabled and its label dims with it: the gesture's key and travels under the
  gesture switch, the battery level under its switch, the three auto-arm waits under the auto-arm switch, the
  effect's start and look under the effect switch, the clip and the volume under the sound switch. The gesture
  and effect switches are disabled on a Mac without a lid-angle sensor; right-click arming and the angle in the
  menu bar are disabled while the menu-bar cup is hidden. A number is a slider with its value beside it.
- **States in Settings.** A state is one row: what is reported on the left, and on the right a symbol and a word
  in the state's colour. Green: as it should be. Blue: worth knowing. Orange: to be fixed, or did not work. Red:
  refused. A spinner: still happening. The colour follows whether the state is what it should be
  (`SettingsStatus`): the sleep lock (Available / Missing) and the Login Items approval (Enabled / Disabled) are
  orange whenever missing; a permission that is not granted reads Denied, red only while something switched on
  needs it (Screen Recording while the effect is on, Input Monitoring while the gesture is on with Fn,
  Notifications always) and blue otherwise; a hook that is not set up reads Disabled, orange only while auto-arm
  is on with neither hook set up, which also puts a warning under the auto-arm switch, and blue otherwise. A
  state the user can fix has a button under it only while it is wrong; once it is right the button goes and the
  row stays. While the window is open it re-reads the grants, the hooks and the login item every 2 s and the lid
  angle and the activity counts four times a second, and it is a consumer of the lid-angle sensor.
- **Onboarding.** Four pages in an ordinary window: pitch, Permissions, "Arm while you work" (hooks), All set.
  Shown at first launch and from Settings › System › "Show Onboarding Again". It opens in front because it is
  the last window to open, and from then on it behaves like any other window: a permission dialog, the
  administrator dialog and System Settings all open over it and stay there until the user leaves them, and the
  wizard keeps its place underneath. The one exception is a dialog of KoffeeLid's own that it waits on, which
  today is the administrator-password dialog behind the sleep lock: the app takes the front back when that
  dialog is answered, because the user never left KoffeeLid. It belongs to the Space it opened in and keeps
  its place in it across a Space switch. It comes forward again when the app is activated and it is the app's only
  window, and opening KoffeeLid again (Finder, Spotlight, `open -b`) brings it back rather than Settings. The
  two list pages re-read the grants and the hooks every 2 s while the window is up, so a grant made in System
  Settings ticks the row over to "Granted" on its own. Only that row changes, never the page: while a grant is
  being set up its row keeps the button that started it, disabled, with a spinner beside it, and the page is
  built again only when the user moves to another page.
  Closing the window gives the frontmost app back to whoever had it, unless another KoffeeLid window is up.
- **Notifications.** Arm refused; disarmed by battery, thermal or external sleep; held awake after a charger
  or display change; lock failed; lid sleep restoration pending or failed; sleep could not be re-enabled; a
  newer release found by an automatic check, the only one with a button (§ Updates).
- **CLI.** `koffeelid arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings |
  install-hooks | uninstall-hooks | shell-init zsh`. The arming verbs launch the app if needed and print the
  status line. `status` with the app not running prints `mode: off (KoffeeLid is not running)`. Exit codes:
  0, 1 (`did not …`, no answer), 2 (usage). The status line reads, for example,
  `mode: armed + screen on · auto-armed (activity) · lid: open · sleep lock: on · activity: 1 session working, 0 commands`.
- **App Intents.** Arm, Arm + screen on, Turn Off, Toggle, Toggle screen on, Status.

## Settings and defaults

| Page › group | Control | Key | Default | Range |
|---|---|---|---|---|
| General › Startup | Launch at login | `launchAtLogin` (mirror of `SMAppService.mainApp`) | on | |
| General › Startup | Show in menu bar | `showInMenuBar` | on | |
| Arming › Lid gesture | Hold 🌐 Fn and close the lid to arm for one close | `armWithOption` | on | |
| Arming › Lid gesture | Key to hold | `gestureModifier` | `fn` | `fn`, `option` |
| Arming › Lid gesture | Arm after closing by / Cancel when reopened by | `gestureActivationDegrees` / `gestureReverseCancelDegrees` | 4° / 4° | 2–20° / 2–15° |
| Arming › Menu bar and shortcuts | Right-click the menu bar icon to arm | `armWithRightClick` | on | |
| Arming › Menu bar and shortcuts | Press ⌃⌥⌘L to arm, or to turn off / Press ⌃⌥⌘K to arm with the screen on, or to turn off | `armWithShortcut` / `armWithCaffeinateShortcut` | on / on | combos fixed: `hotKeyCode`, `hotKeyModifiers`, `caffeinateHotKeyCode`, `caffeinateHotKeyModifiers` have no UI |
| Arming › Low battery | Turn off when the battery runs low, Battery level | `lowBatteryDisarm`, `lowBatteryDisarmPercent` | on, 10 % | 5–50 % |
| Auto-Arm › While you work | Arm while Claude Code or a terminal command is running | `armOnActivity` | off | |
| Auto-Arm › Claude Code / Terminal | Stay armed after Claude Code finishes / Stay armed after a command finishes | `activityHoldOff.claude` / `activityHoldOff.terminal` | 30 min / 60 s | 1–120 min / 10–600 s |
| Auto-Arm › Terminal | Ignore commands shorter than | `activityJobArmAfterSeconds` | 5 s | 0–30 s |
| Lid Effect | Show the desktop folding away as the lid closes, every slider of When it starts and Look, Show the lid angle in the menu bar | `effectParameters` (JSON) | enabled; start below 95° with the gesture / 75° otherwise; flatten again 0.5 s; zoom 80 %; perspective 40 %; blur 0.15×; soft edges 100 %; shading 100 %; responsiveness 70 %; angle in menu bar off | 30–120° / 30–90° (the second never above the first); 0.25–10 s; 0–200 %; 0–2×; 0–100 % |
| Sound › Lid-close sound | Play a sound when the lid closes, Sound | `lidCloseSoundEnabled`, `lidCloseSoundName` | on, `blip-pop` | six clips; an unknown name falls back to the first |
| Sound › Volume | Play it at a set volume, Volume | `forceVolumeEnabled`, `forceVolumeLevel` | on, 60 % | 0–100 % |
| System › Diagnostics | Keep a diagnostics log | `diagnosticsEnabled` | on | |
| (internal) | | `gestureAngleOpen`, `onboardingCompleted` | 120°, false | |

## Permissions and what breaks without them

| Grant | Needed for | Without it |
|---|---|---|
| Sleep lock (administrator password once, a sudoers rule for `pmset disablesleep`) | a closed armed Mac surviving a charger or display change | every arm logs `sleep lock unavailable`; only the dark-wake hold protects the session |
| Background App Activity (KoffeeLid on under that heading in System Settings › General › Login Items) | the crash-recovery watchdog and launch at login | no relaunch after a crash; a crashed armed app leaves the flag set until the next launch |
| Screen Recording | the lid effect | `effect: screen recording not granted; effect stays off`; arming works |
| Input Monitoring | reading the built-in keyboard's Fn key, so only it arms the lid gesture | `built-in Fn reader: Input Monitoring not granted`; any keyboard's Fn/Globe key counts |
| Notifications | every message above | silent failures; the log still has them |
| Lid-angle sensor (hardware) | the gesture and the effect | both unavailable; other arming paths work |

**Every grant is named as System Settings names it**, because the user has to find it in a list there: Background
App Activity, Screen Recording, Input Monitoring, Notifications. The names are quoted from the
system's own tables (`macOS.md` § Permissions), never invented and never a remembered older name. The sleep
lock is the one row with a name of its own, having no system switch behind it.

**A grant button asks macOS, and does nothing else.** Screen Recording, Input Monitoring and Notifications each
show the system's own dialog, which carries its own button to the right pane of System Settings; the app never
opens a pane beside that dialog, and never instead of it once the grant has been refused. Login Items is the
one exception, and the button says so ("Open Login Items"): macOS offers no dialog for it, so the pane is that
grant's whole flow. The sleep lock's button shows the administrator-password dialog.

Settings › System › "Reset KoffeeLid…" asks for confirmation, then disarms, removes the sudoers rule, unregisters the
login items, resets Screen Recording, Input Monitoring and notifications, removes the hooks and the zsh block, clears the
preferences and whatever an update left in Application Support, and reopens onboarding.

## Uninstall

Settings › General › Uninstall takes KoffeeLid off the Mac. The group always shows a warning, because what it warns
about is not a state that can be put right but the hazard of the other way out: **dragging the bundle to the Trash is
not an uninstall.** It removes the app and nothing else, and what is left goes on running against an app that is gone,
the Claude Code hooks calling a binary that is not there once per event for ever.

"Uninstall KoffeeLid" asks for confirmation, then, in this order:

1. disarms, so the kernel lid-sleep flag is clear, the assertions are released and the brightness is back
   before anything else moves;
2. releases the sleep lock, while the sudoers rule that releases it still exists, and whether or not this
   instance is the one that engaged it: `pmset disablesleep 1` survives the process that set it and a
   reboot, so a lock left behind by a crashed instance goes here or not at all. A kernel flag that could
   not be cleared is reported, with the one thing that always puts it back, which is a restart;
3. resets the Screen Recording, Input Monitoring and notification grants, while the bundle they name is still where
   they name it (`tccutil reset` against a bundle identifier with no bundle behind it fails, and nothing puts that
   right afterwards);
4. unregisters the watchdog agent and launch at login, and registers neither back;
5. removes the Claude Code hooks, the zsh block and the settings backup the hooks left;
6. removes `/etc/sudoers.d/koffeelid` and `/usr/local/bin/koffeelid` in one administrator-password dialog, and only
   if one of them is there (`UninstallPlan`);
7. clears the preferences;
8. removes `~/Library/Application Support/KoffeeLid/`, once the diagnostics log has been silenced so that nothing
   writes the folder back;
9. moves the bundle to the Trash, not to a delete: what was just removed is still there to put back.

**Steps 7 and 8 are done twice, and the second time is the one that holds.** Removing either while the app is
still running is not enough: the way out through `shutdown()` recreates the activity journal, and so the
Application Support folder with it, and `cfprefsd` writes the preferences domain out again as the process
exits, leaving an empty plist where a Mac that never had KoffeeLid has no file at all. Both were seen on a
real uninstall. So a detached helper waits for the pid to go, for at most a minute, then deletes the domain,
removes the folder, and removes the preferences file, the ByHost preferences, the caches, the HTTP storage
and the saved window state, all of which are named after the bundle identifier and belong to nothing else.

It then says what it could not remove, if anything, and quits. Reset, in Settings › System, is the other thing:
it puts the app back to a first launch and keeps it installed.

## Updates

KoffeeLid looks for a newer release on GitHub on its own: once 10 s after launch, then a week after the last
check that got an answer, whoever asked (`UpdateSchedule`). The question is put on a 30-minute tick and at every
wake rather than on one week-long timer, so a Mac asleep on the date is asked as soon as it is awake. A check
that could not reach GitHub is silent and tried again at the first tick an hour or more later, so 60 to 90
minutes on. Nothing is fetched or installed without a click.

An automatic check that finds a strictly newer release shows it in Settings and posts one notification,
"Version `<version>` is available", with an **Update** button; a later check's notification replaces it. The
button, and a click on the notification itself, do what Update does in Settings. A notification left by an
earlier run asks GitHub first, then opens the update window on the answer, or Settings when nothing is newer.

Settings › General › Updates is two rows: the running version ("KoffeeLid `<version>`"), which carries the
last answer as its mark, and one button (`UpdatePanel`).

| The moment | The version row's mark | The button |
|---|---|---|
| before the first answer | none | Check for Updates |
| asking GitHub's anonymous API because the button was pressed | a spinner, "Checking" | disabled |
| nothing newer, whoever asked | green, "Up to date" | Check for Updates |
| a strictly newer release, whoever asked | blue, "Version `<version>` is available" | **Update**, prominent and blue |
| a press could not ask | orange, "Could not check: `<reason>`" | Check for Updates |
| the last Install and Relaunch did not end with the new version running | orange, "Update failed: `<reason>`" | Check for Updates, and Update again once a check has found the release |

An automatic check shows no spinner and its failure changes nothing here. A press while an automatic check is
in flight adopts that check's answer instead of starting a second request.

**The update window.** Update opens one small window titled "Software Update" and starts fetching at once: the
app icon, "KoffeeLid `<version>`", one status line, a bar, Cancel and **Install and Relaunch**, which stays
disabled until the update is ready. Pressing Update again, anywhere, shows that same window (`UpdateSession`).

| Phase | The status line | The bar | The buttons |
|---|---|---|---|
| fetching | "Downloading: `<received>` of `<total>`"; "Downloading" when no total is known | follows the bytes | Cancel · Install and Relaunch, disabled |
| making it ready | "Preparing the update" | indeterminate | the same |
| ready | "Ready to install. KoffeeLid will quit and reopen." | full | Cancel · **Install and Relaunch** |
| it cannot replace itself | "KoffeeLid cannot replace itself where it is installed. Open the disk image and drag KoffeeLid to Applications, then quit and reopen it." | none | Cancel · **Open Disk Image** |
| installing | "Installing" | indeterminate | both disabled; the window does not close |
| failed | "Update failed: `<reason>`" | none | Close · **Try Again**, which fetches again |

Everything that can refuse an update happens while making it ready, with the app still running: the fetched
file is held against the length and the SHA-256 GitHub states for the asset; the disk image is mounted
read-only and hidden; the app in it that carries KoffeeLid's bundle identifier is copied to
`<Application Support>/KoffeeLid/updates/staged/`; that copy must be strictly newer than the running version,
ask for no newer macOS than this one, and carry a valid signature from the same team as the running app (a
running app with no team, an ad-hoc build, only asks for a valid signature). KoffeeLid cannot replace itself
when it does not run from an `.app`, runs translocated, cannot write to its folder or its bundle, or sits on
another volume than its Application Support folder; the window then offers the disk image, which macOS mounts
and shows with its Applications link. Cancel and the window's close button stop the fetch and delete what was
fetched.

**Install and Relaunch.** It is refused, with an orange line in the window, while KoffeeLid is armed with the
lid closed and no external display: "Open the lid first. With the lid closed, the Mac goes to sleep when
KoffeeLid quits." Otherwise KoffeeLid starts a helper (`UpdateInstallScript`, a shell script in a process group
of its own) and quits the way the menu's Quit does: it disarms, clears the kernel flag and releases the sleep
lock. The helper touches nothing until the app is gone. If the app is still there 20 s after the click, it
stops the helper, so that a quit that comes later is only ever a quit, and the window says "KoffeeLid did not
quit. Close its open dialogs, then try again." with the update still ready; the helper's own limit, 30 s, only
serves an app too hung to do that. Once the app is gone the helper moves the installed bundle to
`updates/previous/`, moves the new one into its place (a failed move puts the previous one back), writes the
outcome, opens the app, and looks for the new executable among the running processes for 15 s, by the path it
was installed at or by the one the system knows that folder by. Seen, it looks once more 2 s later: still
there, or gone after having read the outcome (the user quit it, which is their business), the previous copy is
deleted. Gone without that mark it is looked for again, for as long as the first look lasted, because an app
that hands itself to launchd quits so that the job's own copy can take its place and nothing runs in between.
Never seen, not openable, or still gone at the end of that second look (it crashed on its way up), the new
copy is moved out, the previous one moved back and opened. Nothing is ever deleted to make room: when the
previous copy cannot be moved back it stays in `updates/previous/`, and the outcome says so.

The next launch reads the outcome, leaves `result.read` in its place for the helper, and says how it ended in
the update window, which is the whole news: after an install, "KoffeeLid 1.0.0" and "The update is installed.
KoffeeLid is running the new version." with one button, Done; after a failure, the version that is still
running and "Version 1.0.0 was not installed." followed by the reason, with one button, Close, and the Updates
group of Settings carries the same reason as its orange mark. **Nothing else opens**: Settings is not shown
behind it, and the launch is otherwise the launch it would have been. The three reasons are "The new version
could not be put in place.", "The new version did not start, so the previous one was put back." and "The new
version did not start and the previous one could not be put back. Download KoffeeLid again." An outcome older
than 10 min was left behind by an install nobody is waiting on any more: it is logged and opens nothing. Quitting
disarms, as every quit does, so the quit leaves a note of the manual mode that was on (`UpdateResume`; never a
one-close gesture arm) and the new version goes back to that mode as it starts, through the same entry point
and the same rails as an arm from the menu. The note is read once and removed; one older than 2 min (the Mac
slept in between, the helper was held up) arms nothing. The auto level needs no note: it arms again by its own
rule if work is running.

## What KoffeeLid does not do

- It does not arm twice: a second instance exits at launch without touching shared state.
- It does not clear a kernel flag it has no evidence of having set (another lid-sleep utility may own it).
- It never signals its own processes by name; it only uses pids from its own pid file. The only processes it
  signals by name are `usernoted` and `NotificationCenter`, restarted by the Settings reset to drop the
  notification grant.
- The hook binary never launches the app, never blocks a Claude Code turn and always exits 0 from the `hook`
  verb (only a malformed `job` command line, which the snippet never produces, exits 2).
- It does not record prompts, tool input or output: the activity journal holds event names and identifiers only.
- It does not fetch or install an update by itself: an automatic check only announces a release.

## Unconfirmed — ask the owner

- Whether macOS's purple screen-recording indicator is hidden by the effect's overlay.
- Whether the Input Monitoring grant takes effect without relaunching the app (the reader retries when the app
  becomes active; `built-in Fn reader: open FAILED` in the log means it did not).
- The dark-wake hold and the one-close hold have been exercised through logs on this Mac; the manual
  checklist (`docs/manual-checks.md`) is the record of what has been verified on hardware.
