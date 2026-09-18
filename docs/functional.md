# What KoffeeLid does

KoffeeLid is a macOS menu-bar app (bundle id `dev.rubens.koffeelid`, no Dock icon) that keeps a MacBook
running with the lid closed. It can be armed by hand, for one close with a lid gesture, or by itself while
Claude Code or a terminal command is working. While armed it darkens the built-in panel when the lid shuts,
plays a sound, shows a closing-only "the desktop stays upright behind the glass" effect, and locks the screen
when the lid reopens. A `koffeelid` command line, `koffeelid://` URLs and App Intents drive the same modes.
English and French; no updater, no licensing.

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

With "Fn + close lid" on (Settings › Arm with) and a lid-angle sensor present:

- Hold the modifier and start closing. After `Activation after` degrees of closing travel (default 4°) the Mac
  arms in Armed mode with source `gesture`. The modifier may be released up to 1 s before that travel is
  reached. The gesture is cancelled if the modifier is released for more than 1 s before the travel is
  reached, if the lid reopens by `Cancel if reopened by` degrees (default 4°), or if a started close stalls
  for 1.5 s.
- Before the lid shuts, the arm is cancelled by reopening the lid by `Cancel if reopened by` degrees from the
  lowest angle reached, or by holding the lid still for the effect's "Return to flat when still for" delay.
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

Arrow keys carry the same modifier flag as Fn; a reading with the numeric-pad flag is not treated as Fn.

### Auto-arm on activity

Off by default ("While Claude Code or a terminal command is running", Settings › Arm with). Setting up either
hook from Settings › Hooks or onboarding turns it on.

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
  ends it within about 35 s. Anything silent for 2 h is dropped.
- **The level rises** the moment something counts and the feature is on: an idle Mac arms (Armed, source
  `activity`); an already armed Mac is unchanged.
- **The level falls** after the longest hold-off among the kinds that ran during the stretch: 30 min after
  Claude Code, 1 min after a command (Advanced). Work that resumes inside the wait cancels it. Keyboard,
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

Available with a lid-angle sensor, the Screen Recording grant and "Lid effect" on. It plays only while the
lid closes, only on the built-in display, and captures nothing while the lid rests.

- **Start.** While armed with the lid open, the effect is prepared (invisible overlay, paused renderer). A fold
  begins when the lid has closed `Activation after` degrees past its rest angle; for arms that did not come from
  the gesture it also waits until the lid is below "Start below (except the lid gesture)" (default 75°), so
  adjusting the screen while working starts nothing. A still image appears at once, then a 60 fps capture.
- **Shape.** The desktop behaves like an inner screen standing upright at "Start below (with the lid gesture)"
  (default 95°): the fold shown is that angle minus the lid angle, capped at 80°. A fold that begins lower
  catches up with that curve over at most 30° of travel. Reopening plays it backward.
- **Reset.** A lid left part-way closed and still (less than 1.5° of movement) for "Return to flat when still
  for" (default 0.5 s) eases back to flat over 0.6 s; its position becomes the new rest angle, and the capture
  stops 0.75 s later. The reset is evaluated on every lid-angle sample (30 Hz), in every mode. While the
  gesture modifier is physically held, stillness does not count: the fold stays until the key is released.
- **End.** The lid shutting, a disarm, an external display or switching the effect off stops it at once. A
  cancelled one-close arm retracts the plane over 0.3 s.
- Advanced › Lid effect › "Simulate a fold" previews a 35° fold over 2 s, armed or not.

## User interface

- **Menu-bar cup.** Four glyphs: empty (Off), closed eyes (auto-armed only), sleepy eyes (Armed), round eyes
  (Armed + screen on). A manual mode always wins over the auto glyph. Orange = the kernel flag could not be
  cleared. Optional lid angle next to it.
- **Menu.** Header with the mode; a greyed line while the auto level holds ("Auto-armed while Claude Code
  works", "… while a command runs", "… and a command run", or "Auto-armed, off in N min"); the three modes;
  "Disarm once finished"; Settings…; Quit.
- **Settings.** App (launch at login); Arm with (gesture, right-click, the two shortcuts, activity); While
  KoffeeLid is armed (lid effect, sound and its switch, forced volume, low-battery disarm); Permissions; Hooks;
  link to Advanced.
- **Advanced.** Lid gesture (modifier, activation, cancel, live angle); Lid effect (every tunable, preview,
  reset to defaults); Auto-arm on activity (two hold-offs, minimum command length, live activity); App
  (watchdog status, diagnostics switch); links: open the log, show onboarding, reset everything.
- **Onboarding.** Four pages in a floating window: pitch, Permissions, "Arm while you work" (hooks), All set.
  Shown at first launch and from Advanced.
- **Notifications.** Arm refused; disarmed by battery, thermal or external sleep; held awake after a charger
  or display change; lock failed; lid sleep restoration pending or failed; sleep could not be re-enabled.
- **CLI.** `koffeelid arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings |
  install-hooks | uninstall-hooks | shell-init zsh`. The arming verbs launch the app if needed and print the
  status line. `status` with the app not running prints `mode: off (KoffeeLid is not running)`. Exit codes:
  0, 1 (`did not …`, no answer), 2 (usage). The status line reads, for example,
  `mode: armed + screen on · auto-armed (activity) · lid: open · sleep lock: on · activity: 1 session working, 0 commands`.
- **App Intents.** Arm, Arm + screen on, Turn Off, Toggle, Toggle screen on, Status.

## Settings and defaults

| Setting | Key | Default | Range |
|---|---|---|---|
| Launch at login | `launchAtLogin` (mirror of `SMAppService.mainApp`) | on | |
| Fn + close lid | `armWithOption` | on | |
| Hold while closing | `gestureModifier` | `fn` | `fn`, `option` |
| Right-click menu bar icon | `armWithRightClick` | on | |
| Armed shortcut / Armed + screen on shortcut | `armWithShortcut` / `armWithCaffeinateShortcut` | on / on | combos fixed: `hotKeyCode`, `hotKeyModifiers`, `caffeinateHotKeyCode`, `caffeinateHotKeyModifiers` have no UI |
| While Claude Code or a terminal command is running | `armOnActivity` | off | |
| Lid-close sound | `lidCloseSoundEnabled`, `lidCloseSoundName` | on, `blip-pop` | six clips; an unknown name falls back to the first |
| Force volume for lid-close sound | `forceVolumeEnabled`, `forceVolumeLevel` | on, 60 % | 0–100 % |
| Low-battery disarm | `lowBatteryDisarm`, `lowBatteryDisarmPercent` | on, 10 % | 5–50 % |
| Activation after / Cancel if reopened by | `gestureActivationDegrees` / `gestureReverseCancelDegrees` | 4° / 4° | 2–20° / 2–15° |
| Auto-disarm after Claude Code / a command finishes | `activityHoldOff.claude` / `activityHoldOff.terminal` | 30 min / 60 s | 1–120 min / 10–600 s |
| Ignore commands shorter than | `activityJobArmAfterSeconds` | 5 s | 0–30 s |
| Diagnostics log | `diagnosticsEnabled` | on | |
| Lid effect and its tunables | `effectParameters` (JSON) | enabled; start 95° / 75°; return to flat 0.5 s; zoom 80 %; perspective 40 %; blur 0.15×; edge softness 100 %; shading 100 %; responsiveness 70 %; angle in menu bar off | 30–120° / 30–90° (the second never above the first); 0.25–10 s; 0–200 %; 0–2×; 0–100 % |
| (internal) | `gestureAngleOpen`, `onboardingCompleted` | 120°, false | |

## Permissions and what breaks without them

| Grant | Needed for | Without it |
|---|---|---|
| Sleep lock (administrator password once, a sudoers rule for `pmset disablesleep`) | a closed armed Mac surviving a charger or display change | every arm logs `sleep lock unavailable`; only the dark-wake hold protects the session |
| Login Items approval | the crash-recovery watchdog and launch at login | no relaunch after a crash; a crashed armed app leaves the flag set until the next launch |
| Screen Recording | the lid effect | `effect: screen recording not granted; effect stays off`; arming works |
| Notifications | every message above | silent failures; the log still has them |
| Lid-angle sensor (hardware) | the gesture and the effect | both unavailable; other arming paths work |

Advanced › "Reset permissions and undo every change…" disarms, removes the sudoers rule, unregisters the
login items, resets Screen Recording and notifications, removes the hooks and the zsh block, clears the
preferences and reopens onboarding.

## What KoffeeLid does not do

- It does not arm twice: a second instance exits at launch without touching shared state.
- It does not clear a kernel flag it has no evidence of having set (another lid-sleep utility may own it).
- It never signals processes by name; it only uses pids from its own pid file.
- The hook binary never launches the app, never blocks a Claude Code turn and always exits 0.
- It does not record prompts, tool input or output: the activity journal holds event names and identifiers only.

## Unconfirmed — ask the owner

- Whether macOS's purple screen-recording indicator is hidden by the effect's overlay.
- The dark-wake hold and the one-close hold have been exercised through logs on this Mac; the manual
  checklist (`docs/manual-checks.md`) is the record of what has been verified on hardware.
