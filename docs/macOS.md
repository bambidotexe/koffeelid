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
| `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist` | `KoffeeLidController.resetNotificationGrant` | The Settings reset puts the notification grant back to "not determined" | The reset reports nothing for notifications |
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

## Updates: disk images, signatures, the helper

- GitHub's anonymous `GET /repos/<owner>/<repo>/releases/latest` lists each asset with `size` and
  `digest: "sha256:<hex>"`, and `browser_download_url` answers 302 to a 200 that carries `content-length`. A
  repository that is private, or has no release, answers 404.
- A file this app fetches itself is not quarantined (the bundle does not set `LSFileQuarantineEnabled`), so the
  copy taken out of its disk image opens without a Gatekeeper prompt regardless of notarization.
- `hdiutil attach <dmg> -nobrowse -readonly -noautoopen -mountpoint <folder>` mounts a release's one volume on a
  folder of our choosing, so nothing of its output is parsed. On macOS 27 it still works and prints a deprecation
  notice naming `diskutil image attach --readOnly --nobrowse --mountPoint <folder>`, which the stager falls back
  on. `hdiutil detach <folder> -force` unmounts; `diskutil eject` is the fallback.
- `FileManager.copyItem` out of the mounted image keeps the bundle's signature valid (measured against
  `codesign --verify --deep --strict`).
- `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate`
  is that same check. The requirement `anchor apple generic and certificate leaf[subject.OU] = "<team>"` holds
  for an Apple Development and for a Developer ID certificate of one team alike; a copy from another signer
  fails with `errSecCSReqFailed`, a tampered one with `errSecCSBadResource`. `SecCodeCopySigningInformation`
  gives the running app's team, and none for an ad-hoc build.
- When a launchd job's main process exits, launchd kills whatever is left in the job's process group (measured:
  a plain `posix_spawn` child of a job that exits is gone before it runs; a child spawned with
  `POSIX_SPAWN_SETPGROUP` and group 0 runs on). Apps opened through LaunchServices are launchd jobs too.
- `ps -axo comm=` prints each process's full executable path, which `grep -Fx` matches exactly: that is how the
  helper sees the new version running without matching by name.
- Moving a bundle is one `rename(2)` when source and destination are on the same volume, which is why the
  update is unpacked under Application Support and refused when the app lives on another volume.
- A notification's action button belongs to its `UNNotificationCategory`; with `.foreground` the click brings
  the app forward. Both the button and a click on the notification reach
  `userNotificationCenter(_:didReceive:withCompletionHandler:)`, the second as
  `UNNotificationDefaultActionIdentifier`. A centre with no delegate shows nothing while its app is frontmost;
  with one, `willPresent` decides per notification.

## Permissions and how each is reset

| Grant | Store | Reset |
|---|---|---|
| Sleep lock | `/etc/sudoers.d/koffeelid` | `SleepLock.removeRule()` (administrator dialog) |
| Login Items | Background Task Management (bundle id + team id). The switch the user flips is KoffeeLid under “Background App Activity” in System Settings › General › Login Items; the pane is `Login Items` (`LoginItems.appex`), and both names are quoted from its own `Localizable.loctable` | none per app: `sfltool` resets every app's approval at once, and an approval survives an uninstall, so a reinstalled bundle re-registers silently |
| Screen Recording | TCC | `tccutil reset ScreenCapture dev.rubens.koffeelid` |
| Input Monitoring | TCC | `tccutil reset ListenEvent dev.rubens.koffeelid` |
| Notifications | usernoted's group preferences, `apps[]` entry with `bundle-id` | drop the entry, `killall usernoted` and `killall NotificationCenter` |
| Preferences | UserDefaults domain `dev.rubens.koffeelid` | `defaults delete dev.rubens.koffeelid` |

An accessory app is left out of macOS's activation stack. When an app quits, macOS gives the front back to
whatever was in front before it, but it skips `LSUIElement` apps doing so, so a window that sent the user to
System Settings is not brought back when they close it: the front goes to whatever else was open. There is no
flag for this. Either the app becomes `.regular` for as long as the window is up, which gives it a Dock icon
and needs a main menu it does not have, or it watches for that app to quit and brings its own window back,
which is what `FocusReturnWatch` does. System Settings quits when its window is closed, so its
`NSWorkspace.didTerminateApplicationNotification` is the signal.

**A grant is called, in the app, exactly what System Settings calls it.** The user has to find the switch in a
list, so a name of our own is a dead end however accurate it reads. macOS 27 shows these, and the app quotes
them from the system's own tables rather than from memory:

| The app asks for | System Settings shows | French | Quoted from |
|---|---|---|---|
| the login item / watchdog agent | Background App Activity, in General › Login Items | Activité des apps en arrière-plan | `LoginItems.appex/Contents/Resources/Localizable.loctable` |
| `CGRequestScreenCaptureAccess` | Screen Recording | Enregistrement de l’écran | `SecurityPrivacyExtension.appex`, key `SCREEN_CAPTURE` |
| `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` | Input Monitoring | Surveillance de l’entrée | the same, key `LISTEN_EVENT` |

Two traps in that table. The Login Items **pane** is not the name of the switch: the pane lists "Open at Login"
above and "Background App Activity" below, KoffeeLid appears in both, and only the second is the one to turn
on. And screen capture is **two** grants in Privacy & Security, listed separately: `SCREEN_CAPTURE`
("Screen Recording") for the screen, `SCREENANDAUDIOCAPTURE` ("Screen & System Audio Recording") for the
screen with the system's audio. The app calls `CGRequestScreenCaptureAccess`, which is the first, and never
asks for audio, so the first is the one to name. The sleep lock has no system name at all, being a sudoers
rule of ours, and keeps its own.

Asking for a grant and pointing at System Settings are two different things, and the app only ever does the
first. `CGRequestScreenCaptureAccess()` (Screen Recording) and `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`
(Input Monitoring) show the system's dialog, whose own button opens the right pane; both return **the state at
the moment of the call**, which is still not-granted while the user is looking at the dialog, so their result
says nothing about an answer. `UNUserNotificationCenter.requestAuthorization` is the same for notifications, and
once a grant is explicitly denied macOS shows no dialog at all and the call returns the denial. Login Items has
no dialog: `SMAppService.openSystemSettingsLoginItems()` is the only flow there is.

The app signs with the Wooflab team's Developer ID Application identity (`85F6AC5QZF`, `project.yml`'s
`DEVELOPMENT_TEAM` with `CODE_SIGN_STYLE: Automatic`; `script/signing.env` looks the identity up in the
keychain by team id). `script/release.sh` notarizes and staples both the app and the disk image, so a release
passes Gatekeeper on any Mac without a warning. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` keeps
`com.apple.security.get-task-allow` out of the build so it stays debuggable only through Xcode's own attach,
not through a blanket entitlement.

Finder does not scale a disk image's background image to the window: it draws the image at its natural size
from the top-left corner of the icon view's content area, and Finder's own chrome (the title bar, an open tab
bar, the status/path bar) can cover up to about 120 points at the bottom of that window. A background meant to
fill a 660×480 DMG window therefore has to keep every mark inside the top 340 points and leave the rest a
plain field; `script/dmg-background.swift` renders to that constraint and refuses to render a layout that
reaches below the line. The Finder/AppleScript way of setting a disk image's icon layout needs an Automation
grant and fails silently without one, which is why `script/make-dmg.sh` writes the layout straight into the
image's `.DS_Store` with `dmgbuild` instead.

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
