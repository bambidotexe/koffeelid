# macOS mechanisms

What KoffeeLid asks of macOS, through which interface, and how each one behaves on a MacBook with Apple
silicon (developed on Mac16,8, macOS 27). The traps these mechanisms hide are in `docs/pitfalls.md`.

Tools that show the state of each mechanism: `ioreg -r -d1 -c IOPMrootDomain`, `pmset -g`, `pmset -g assertions`,
`pmset -g log`, the unified log (`/usr/bin/log show`, kernel lines start with `PMRD:`), and the app's
`diagnostics.log`.

## Private and undocumented interfaces in use

| Interface | Used by | For | If it disappears |
|---|---|---|---|
| `IOPMrootDomain` user client, external method 12 (`kPMSetClamshellSleepState`, xnu `IOPMLibDefs.h`) | `PowerManager.setLidSleepDisabled` | Disabling lid-close sleep | `arm` fails with `.flagSetFailed`; nothing else keeps a closed Mac awake |
| `DisplayServices.framework`: `DisplayServicesGetBrightness`, `DisplayServicesSetBrightness` (`dlopen`/`dlsym`) | `InternalDisplayBrightnessController` | Darkening the built-in panel behind a closed lid | Falls back to `/usr/bin/pmset displaysleepnow` |
| `login.framework`: `SACLockScreenImmediate` (`dlopen`/`dlsym`) | `LidReopenLockController` | Locking the screen when the lid reopens | Five retries, then a notification asking the user to lock by hand |
| Distributed notifications `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`, and `CGSSessionScreenIsLocked` in `CGSessionCopyCurrentDictionary` | `ScreenLockObserver`, `LidReopenLockController.isScreenLocked` | Knowing when the user logs back in | A one-close arm falls back to ending when the lid opens |
| Lid-angle HID sensor (vendor `0x05AC`, product `0x8104`, usage page `0x20`, usage `0x8A`), feature report 1 | `LidAngleSensor` | The lid gesture and the lid effect | Both are unavailable; every other arming path works |
| `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist` | `KoffeeLidController.resetNotificationGrant` | Advanced › Reset puts the notification grant back to "not determined" | The reset reports nothing for notifications |
| The built-in keyboard's HID device (`Built-In`, usage page 1, usage 6) and its Fn key element on Apple's vendor top-case page `0xFF`, usage 3 | `BuiltInFnKeyReader` | Telling the built-in keyboard's Fn key from an external keyboard's | Any keyboard's Fn key arms the lid gesture |
| Claude Code's hook payloads and `<config>/sessions/<pid>.json` registry records | `ActivityTrim`, `ClaudeRegistryRecord` | Auto-arm on activity | See § Claude Code below |

The app is not sandboxed (`com.apple.security.app-sandbox` = false): an IOKit user client, private
frameworks, `sudo` and `pmset` are incompatible with the sandbox. Hardened Runtime is on.

## Kernel lid-sleep flag

- One scalar input: `1` disables lid-close sleep, `0` restores it. The flag belongs to the kernel, not to the
  process: a process that dies leaves it set until something clears it or the Mac restarts.
- Readable as `AppleClamshellCausesSleep` on the root domain (`No` = lid sleep disabled). `AppleClamshellState`
  is the lid (`Yes` = closed); its changes arrive as `kIOGeneralInterest` notifications on the root domain,
  which is how `LidObserver` learns of a close or an open.
- `AppleClamshellCausesSleep` is refreshed only by the kernel's own clamshell notifications, never by a
  selector-12 write. After a set it can read `Yes` until the next lid or power event, and after a clear it can
  read `No`. `koffeelid status`, the log and `pmset -g assertions` are the reliable views.
- **powerd owns the same bit.** xnu keeps a two-bit mask, `clamshellSleepDisableMask`: `Internal = 0x01` (set
  by the kernel while waking) and `Powerd = 0x02`. Selector 12 sets or clears the powerd bit for every caller;
  there is no per-client bit. powerd recomputes its own policy (desktop mode with AC, or an active
  `UserIsActive` / `DisplayWake` / `PreventSystemSleep` assertion carrying `AppliesOnLidClose`, a property
  that needs a private entitlement) on every power-source change and every raise or release of those
  assertion types, and writes the bit whenever its result flips.
- When that write brings the mask to 0 with the lid closed, the kernel evaluates the clamshell inside the same
  call and starts a `Clamshell Sleep`. Plugging the charger does it (PowerChime holds a `DisplayWake` assertion
  for about a second and its release flips powerd's result), and so do display hot-plug and leaving desktop
  mode. Signature in the unified log, within one millisecond: powerd `EvaluateClamshell. Disable : 0`, kernel
  `PMRD: setClamShellSleepDisable(2->0)`, `PMRD: sleep reason Clamshell Sleep`.
- That sleep goes full wake → dark wake first, with `kIOMessageSystemWillSleep` (`NSWorkspace.willSleepNotification`)
  sent on that step, then `checkSystemCanSleep`, which honours the CPU assertion bit powerd raises for an
  active `PreventSystemSleep` (on AC power only; powerd disables that assertion type on battery). Holding the
  assertion keeps the Mac in dark wake: processes run, display and audio are off. The kernel re-evaluates the
  clamshell 20 s after every full wake.
- Around real sleep/wake and display changes the root domain drops the bit on its own. While armed,
  `KoffeeLidController.reapplyFlag` sets it again after root-domain notifications, power-source changes
  (`IOPSNotificationCreateRunLoopSource`), display sleep/wake, system wake and screen-parameter changes, but
  only when `AppleClamshellCausesSleep` does not already read `No`.

## Sleep lock (`pmset disablesleep`)

- `pmset disablesleep 1` sets `SleepDisabled` on the root domain (`userDisabledAllSleep` in xnu), checked first
  in `checkSystemSleepAllowed`, before every sleep request, clamshell evaluations included. It is the only
  setting that stops the powerd-induced clamshell sleep from starting. While it is on, idle sleep and the Apple
  menu's Sleep are off too.
- Setting the property directly needs a private entitlement and `pmset` needs root, so `SleepLock` runs
  `/usr/bin/sudo -n /usr/bin/pmset disablesleep 1|0` under a sudoers rule:
  `/etc/sudoers.d/koffeelid`, mode 0440, `<user> ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0`.
- The rule is written as root by `NSAppleScript` `do shell script … with administrator privileges`
  (`SleepLock.installRule`, script text from `SleepLockSetup`). The script names every tool by absolute path,
  stages the rule as a dotted temp file inside `/etc/sudoers.d` (sudo ignores dotted names), validates it with
  `visudo -cf` and renames it into place; a failed validation removes the temp file.
- The setting persists across reboots in `/Library/Preferences/com.apple.PowerManagement.plist`. The app
  records that it engaged the lock in `~/Library/Application Support/KoffeeLid/sleep-lock`; a launch that finds
  the marker releases the lock.
- Availability = the rule file exists **and** `sudo -n -l /usr/bin/pmset disablesleep 1` succeeds.

## Power assertions

| Assertion | Name | Held |
|---|---|---|
| `PreventUserIdleSystemSleep` | `KoffeeLid: keeping Mac awake` | while armed |
| `PreventSystemSleep` | `KoffeeLid: protecting closed-lid power transitions` | while armed |
| `PreventUserIdleDisplaySleep` | `KoffeeLid: keeping the display on` | Armed + screen on, lid open or closed |
| `UserIsActive` via `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` | `KoffeeLid: caffeinate` | Armed + screen on, lid open only, renewed every 30 s |

The display assertion does not reset the user-idle timer, which drives the screen saver and "require password
after"; the 30 s activity declaration does. A declaration wakes a sleeping display, so it stops while the lid
is closed. It is an assertion, not a HID event: `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)`,
which `LocalInputMonitor` reads, does not see it.

## Lid-angle sensor

- `IOHIDManager` match on the ids above; on this Mac an `AppleSPUHIDDevice`. Feature report id 1, degrees =
  `UInt16(report[1]) | UInt16(report[2]) << 8`, valid 0…180, whole degrees.
- The value flickers between neighbouring degrees while the lid rests.
- The value changes at most every ~100 ms (10 Hz), in steps of 1–10° depending on speed; one
  `IOHIDDeviceGetReport` costs about 0.5 ms. `script/lid-sensor-rate.swift` measures both.
- `LidAngleObserver` polls only while a consumer is registered: 30 Hz at rest, 120 Hz while the value has
  changed within the last 0.7 s, and delivers to the main thread at 30 Hz whatever the poll rate.

## Modifier keys

`GestureController.readModifier` reads the gesture modifier fresh on every lid-angle sample from
`CGEventSource.flagsState(.combinedSessionState)` and `NSEvent.modifierFlags`.

- Option is `maskAlternate` / `.option`.
- Fn (Globe) is `maskSecondaryFn` / `.function`. Observed on this Mac: the physical Fn key reads raw flags
  `0x800100` (no numeric-pad flag) with `CGEventSource.keyState(…, 63 /* kVK_Function */)` = 1, and clears on
  release. macOS also sets the Fn flag on every arrow-key event, together with `maskNumericPad` / `.numericPad`
  (raw `0xa00100`, key state of 63 = 0), and **those flags stay in the session state after the arrow key is
  released, until the next keyboard event**. Function keys used as F1–F12 and an external keyboard's navigation
  keys carry the Fn flag without the numeric-pad flag and without key 63. A reading therefore counts as Fn only
  without the numeric-pad flag and with `CGEventSource.keyState(.combinedSessionState, key: 63)` true
  (`FnKeyReading`). Whether an external keyboard's own Fn/Globe key presses key 63 has not been checked on this
  Mac; a third-party keyboard's Fn key is usually handled inside the keyboard and never reaches macOS.
- **Per-keyboard Fn.** An external Apple keyboard's Globe key sets the same flag and, on this Mac, exposes the
  same HID element as the built-in one (both keyboards carry usage page `0xFF`, usage 3). `BuiltInFnKeyReader`
  enumerates the keyboards through `IOHIDManager`, keeps the one whose `Built-In` property is set (the kernel
  does not match on that key: a matching dictionary carrying it matched both keyboards), opens that one device
  (`IOHIDDeviceOpen`), subscribes to the Fn element's input values on the main run loop, and `FnKeyReading`
  requires the reading in addition to the session key state.
  Keyboard HID input is gated by the Input Monitoring grant (`IOHIDCheckAccess` /
  `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`; `IOHIDManagerOpen` fails without it): System Settings ›
  Privacy & Security › Input Monitoring, per bundle path like Screen Recording. The reader retries whenever the
  app becomes active, so a grant made in System Settings is picked up on return.
- macOS runs the Globe key's "Press 🌐 key to" action on release when nothing else was pressed; set it to
  "Do Nothing" if the emoji picker appears after the gesture.

## Displays

- Topology = `CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`; changes arrive as
  `NSApplication.didChangeScreenParametersNotification`.
- macOS posts no screen-parameter change while the lid is shut and no display is left to reconfigure. A display
  that goes away behind a closed lid is reported about 130 ms **after** the lid-open notification.
- The effect's overlay sits at `NSWindow.Level.screenSaver`: above the menu bar and status items, below the
  lock screen and shielding windows.

## Screen capture

ScreenCaptureKit (`SCShareableContent`, `SCScreenshotManager`, `SCStream`), gated by the Screen Recording TCC
grant (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`). Grants are per bundle path: the
DerivedData build and the `/Applications` build are different apps to TCC. A stream takes 150–300 ms to
start. The capture is tagged sRGB and the Metal layer carries the same colour space, so the overlay matches
the desktop at fold 0.

## Login items and the watchdog

- `SMAppService.mainApp` is launch at login. `SMAppService.agent(plistName: "dev.rubens.koffeelid.agent.plist")`
  registers the LaunchAgent embedded at `Contents/Library/LaunchAgents/`: `BundleProgram
  Contents/MacOS/KoffeeLidWatchdog`, `RunAtLoad`, `KeepAlive.SuccessfulExit = false`, `ProcessType Background`.
- Both need the user's approval in System Settings › General › Login Items
  (`SMAppService.Status.requiresApproval` until then). Approval lives in Background Task Management, keyed by
  bundle id **and** team id; there is no per-app reset (`sfltool resetbtm` wipes every app's).
- launchd starts a `BundleProgram` agent with a relative `argv[0]` and `/` as working directory.
- launchd starts the agent before the app at login, so the app runs `launchctl kickstart` on every start.
- An `LSUIElement` app that is **already running** receives `applicationShouldHandleReopen(_:hasVisibleWindows:)`
  when it is opened again (Finder, Spotlight, `open`); no second process starts. A **cold** open receives
  `applicationDidFinishLaunching` only: it never becomes active (`NSApp.isActive` stays false, no
  `applicationDidBecomeActive`), gets no arguments and has the same `XPC_SERVICE_NAME`
  (`application.<bundle id>.…`) as the launch-at-login one — so a cold user open cannot be told apart from
  launchd's. The only difference is LaunchServices' `parentASN` (`Finder` vs `loginwindow`, visible in
  `lsappinfo info -app <bundle id>`), which has no public API. Reopen is therefore the one reliable "the user
  asked for the app" signal.

## Permissions and how each is reset

| Grant | Store | Reset |
|---|---|---|
| Sleep lock | `/etc/sudoers.d/koffeelid` | `SleepLock.removeRule()` (administrator dialog) |
| Login Items | Background Task Management (bundle id + team id) | none per app |
| Screen Recording | TCC | `tccutil reset ScreenCapture dev.rubens.koffeelid` |
| Input Monitoring | TCC | `tccutil reset ListenEvent dev.rubens.koffeelid` |
| Notifications | usernoted's group preferences, `apps[]` entry with `bundle-id` | drop the entry, `killall usernoted` and `killall NotificationCenter` |
| Preferences | UserDefaults domain `dev.rubens.koffeelid` | `defaults delete dev.rubens.koffeelid` |

Apple Development-signed builds are rejected by Gatekeeper on other Macs; distribution needs a Developer ID
Application signature, Hardened Runtime and notarization (`script/release.sh`). The Apple Development identity
injects `com.apple.security.get-task-allow`; `project.yml` sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` for
Release so the installed build is not debuggable.

## Claude Code

Three surfaces the activity feature depends on, none documented upstream:

- **Hook events and payload keys.** The 15 event names in `ActivityEventName.claudeCodeEvents` and the payload
  fields `hook_event_name`, `session_id`, `agent_id`, `tool_name`, `notification_type`, `source`,
  `background_tasks`. `ActivityTrim.event(fromHookPayload:)` reads only these; prompts, tool input and output
  and assistant messages never reach the journal.
- **`<config>/sessions/<pid>.json`.** Claude Code's per-process registry record (`ClaudeRegistryRecord`): `pid`,
  `sessionId`, `status` (`busy` while a turn runs, `idle` at the prompt), `statusUpdatedAt` (epoch
  milliseconds). It is the only signal about a turn that does not travel through hooks.
- **`CLAUDE_CONFIG_DIR`.** Relocates the registry away from `~/.claude`. macOS withholds another process's
  environment from a same-user reader (`ps -E` prints none either), so `ProcWalk.environmentValue` returns
  `nil` and `ClaudeProcessRegistry.read` falls back to `~/.claude/sessions/<pid>.json`.

Hooks are installed in `~/.claude/settings.json` (symlinks resolved), one entry per event:
`{"matcher": "*", "hooks": [{"type": "command", "command": "<bundle>/Contents/MacOS/KoffeeLidHook hook", "timeout": 5}]}`.

## zsh

The snippet printed by `koffeelid shell-init zsh` registers `preexec` and `precmd` hooks. `precmd` must read
`$?` as its first statement to preserve the exit status for other hooks. The snippet lives in `~/.zshrc`
between two `# ---------- KoffeeLid ----------` lines.

## Sounds

Six clips in `App/Resources/Sounds/close-sound-<name>.mp3`, played with `AVAudioPlayer`. The forced volume
writes the default output device's volume and mute through CoreAudio and restores them 0.25 s after the clip
ends; a device without a settable volume plays at its current level.
