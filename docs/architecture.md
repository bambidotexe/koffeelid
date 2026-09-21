# Architecture

How the code is organised and who owns what. Product behaviour is in `docs/functional.md`, the macOS
interfaces in `docs/macOS.md`, the traps in `docs/pitfalls.md`.

## Targets

Five targets, dependencies strictly downward. `project.yml` (XcodeGen) defines the three Xcode targets and
links the SwiftPM package; `Package.swift` defines the two libraries and their tests.

| Target | Kind | Depends on | Contents |
|---|---|---|---|
| `KoffeeLidCore` (`Sources/KoffeeLidCore`) | SwiftPM library, Foundation only | — | Every policy, filter and state machine as a value type with injected time, plus the update feature's rules (`ReleaseVersion`, `LatestRelease`, `UpdateCheck`, `UpdateSchedule`, `UpdatePanel`, `UpdateSession`, `StagedUpdateCheck`, `UpdateInstallPlan`/`UpdateInstallScript`/`UpdateResult`, `DetachedProcess`) and the Settings window's `SettingsStatus` (which colour a state takes). All logic tests live against it. |
| `LidPlaneKit` (`Sources/LidPlaneKit`) | SwiftPM library (AppKit, Metal, ScreenCaptureKit) | Core | The lid effect: `EffectController`, `DesktopCapture`, `PlaneRenderer`, `PlaneShader`, `EffectOverlayPanel`, `CaptureStartGate`, `PlaneRemap`. |
| `KoffeeLid` (`App/Sources`) | app, `LSUIElement` | Core, LidPlaneKit | The coordinator, one adapter per system API, the UI, the update feature (`UpdateController` and what it runs), App Intents, the CLI client. |
| `KoffeeLidWatchdog` (`Watchdog/Sources/main.swift`) | tool embedded in `Contents/MacOS` | Core | LaunchAgent that relaunches the app after an unclean exit. |
| `KoffeeLidHook` (`Hook/Sources/main.swift`) | tool embedded in `Contents/MacOS` | Core | `hook` and `job begin\|end`: append one line to the activity journal. |

Rule: what can be expressed without AppKit or IOKit and tested with an injected clock belongs in Core. App
files are thin adapters around one system API with closures back to the coordinator (`onX`, `onLog`).

`main.swift` runs `CommandLineClient.run` first: when `argv[1]` is a verb the process forwards it and exits
before AppKit starts. Otherwise it starts `NSApplication` with the `.accessory` policy. `AppDelegate` exits a
duplicate instance before `start()` (so a second build can never touch the flag under a live session), starts
the coordinator, routes `koffeelid://` URLs, owns the Settings and onboarding windows, and calls `shutdown()`
from `applicationShouldTerminate`.

The Settings window (`App/Sources/UI/Settings*.swift`) is one `SettingsWindow`: an `NSWindow` with a
`.preference` `NSToolbar` over a single `NSHostingController`, built once by `AppDelegate.showSettings()` and
re-shown. Its seven pages are SwiftUI views built only from the kit in `SettingsKit.swift`; the window's height
follows the shown page. `SettingsModel` is what the pages share: bindings onto `Preferences.shared` that
announce their own changes to SwiftUI (the coordinator stays the one subscriber of `Preferences.onChange`), and
the states a page reports, polled on the main thread and started and stopped by the window (open, close,
miniaturise), never by a view: the grants, the hooks and the login item every 2 s, the lid angle and the
activity counts every 0.25 s, the window being a consumer of `LidAngleObserver` for as long as it is up. The
rules the pages apply are Core's: `SettingsStatus` colours a state and `UpdatePanel` is the Updates group, whose
state is the app's (`UpdateController.shared`) and not the page's. The
onboarding is an AppKit window and reads the same `PermissionCatalog` and `HookCatalog`. It is a normal window
too, at the normal level and with the default collection behaviour, like the other two: `AppDelegate` activates
the app once when it opens, and two things activate it again, both of them grant flows ending:
`PermissionItem.returnsFocus` for a flow that owned a modal dialog and waited for it (the sleep lock alone,
`reclaimFocusIfNeeded`), and `PermissionItem.mayOpen` for a flow that can send the user to another app, which
arms a `FocusReturnWatch` on that app's `didTerminateApplicationNotification` (System Settings, for every
macOS grant). `SettingsModel.grant` uses both the same way. It
comes forward on `NSApplication.didBecomeActiveNotification` only while `othersNeedUsActive()` is false (the
same injected predicate `SettingsWindow` and `UpdateController` use to decide whether to `NSApp.deactivate()`
on close), and it polls its own grants every 2 s between `showWindow` and `windowWillClose`. A page is built
only on a change of step: every row of the two list pages is a `GrantRow` that redraws its own trailing
control when its own grant moves and shows a spinner beside its disabled button while its flow runs, and the
page's primary button takes its title in place. The window's
structure, numbers and wording rules are in `~/.claude/skills/macos-building-settings-pages/SKILL.md`.

## The coordinator

`KoffeeLidController` (`@MainActor`, singleton) is the only object that mutates arming state. Every
collaborator reports to it through a closure; none holds a reference to it except the UI, which reads state
and calls `setMode`, `perform`, `resetEverything`, `sleepLockRuleChanged`.

### State

| Property | Meaning |
|---|---|
| `mode: ArmMode` (`off`, `armed`, `caffeinate`) | the manual choice |
| `autoArmed` = `ActivityArmPolicy.isOn` | the auto level |
| `state: ArmState` (`idle`, `armedWaitingClose`, `armedClosed`) | the session and the lid within it; `isArmed` ⇔ `state != .idle` ⇔ manual armed **or** auto level on |
| `armSource: ArmSource?` (`menu`, `rightClick`, `shortcut`, `gesture`, `intent`, `url`, `cli`, `activity`) | who owns the current arm; `gesture` means a one-close arm |
| `externalDisplay`, `standingBy` = `isArmed && externalDisplay` | built-in-screen behaviours wait |
| `reopenWatch: ReopenCancelWatch?` | alive from a gesture arm until the lid shuts |
| `gestureHold: GestureArmHold` | keeps a one-close arm across the lid opening until login |
| `reopenLock: ReopenLockDecision` | a reopen lock skipped for a display that may already be gone |
| `flagClearPending`, `flagRetryTimer` | a failed kernel-flag clear and its 30 s retry |
| `overrideGuard: SleepOverrideGuard` | limits dark-wake holds to 3 per 120 s |

```
                 arm(source:mode:)                      lid closed
   idle ───────────────────────────▶ armedWaitingClose ───────────▶ armedClosed
     ▲                                  │        ▲                        │
     │  disarm(reason:)                 │        └──── lid opened ────────┘
     └──────────────────────────────────┘
        rails · reset · quit · manual Off with the auto level off ·
        auto level falling with the manual mode Off
```

### Entry points

- `setMode(_:source:)` is the single entry point for a manual mode change. `.off` → `releaseManual`. From idle →
  `arm(source:mode:)`. While armed and the target differs, or the arm is auto-only: switch in place (`mode`,
  `armSource = source`, `reopenWatch = nil`, `gestureHold.clear()`, `applyCaffeinate()`); the kernel flag is
  not touched.
- `perform(_:source:)` maps the arming verbs of a `DeepLink` onto `setMode` (`status` does nothing, `settings`
  opens the window) and returns `statusLine()`, or `did not arm: …` for a refused arm.
- `arm(source:mode:)`: `isStarted` → not already armed → `ArmingPolicy.evaluate` → `setLidSleepDisabled(true)` →
  cancel the clear-retry → `acquireAssertions()` → `engageSleepLock()` → fresh `SleepOverrideGuard` → `mode`
  (unless the source is `activity`) → `state` from the lid → `armSource` → `gesture.reset()`,
  `refreshGestureSampling()` → `effect.gateToStartAngle = source != .gesture` → `reopenWatch` for a gesture arm
  → `effect.start()` when the lid is open and not standing by → `applyCaffeinate()`.
- `releaseManual(reason:source:)`: manual Off or the end of a one-close arm. With the auto level off it is
  `disarm`. With it on: `mode = .off`, `armSource = .activity`, the session stays.
- `disarm(reason:source:)`: cancel a pending lock; clear `reopenWatch`, `reopenLock`, `gestureHold`;
  `effect.stop()`; clear the kernel flag (on failure `flagClearPending`, a notification, a 30 s repeating retry);
  `releaseSleepLock()`; `releaseAssertions()`; restore brightness; `mode = .off`; `applyCaffeinate()`;
  `state = .idle`; `gesture.reset()`; `activityPolicy.suspend()`. Nothing returns early between the flag
  attempt and `state = .idle`.
- `applyAuto(_:)`: the auto level changed. `.on` arms only an idle Mac (`arm(source: .activity)`; a refusal
  calls `armFailed()`). `.off(releaseManual:)` disarms only when `mode == .off`.
- `shutdown()`: stops the activity monitor, the screen-lock observer, the built-in Fn reader and the timers; if armed, cancels the lock, stops the effect, releases
  the sleep lock and assertions, restores brightness; clears the flag (three attempts, 0.3 s apart) only if
  `wasArmed || flagClearPending || power.lidSleepDisabled`; removes the pid file.
- `start()`: opens the root domain; clears the flag only when a stale pid file or brightness-recovery file
  proves an unclean exit; releases a marked sleep lock; restores a saved brightness; writes the pid file,
  registers and kickstarts the watchdog; wires every collaborator; starts the activity monitor last, after
  `isStarted`, so a relaunch can re-arm from the replayed journal at once.

### Kernel flag ownership

| Moment | Code | Condition |
|---|---|---|
| Launch | `start()` | only with a stale `koffeelid.pid` or `display-brightness-recovery.json` |
| Arm | `arm()` | always sets |
| Re-apply | `reapplyFlag(reason:)` | armed, and `AppleClamshellCausesSleep` does not read `No` |
| Lid-sleep override | `handleExternalSleep()` | armed; sets again immediately |
| Disarm | `disarm()` | always clears; failure → retry every 30 s |
| Quit | `shutdown()` | three attempts, only if this instance set it or a clear is pending |

The launch and quit clears are conditional because other lid-sleep utilities drive the same flag.

## Who watches what

| Signal | Adapter | Mechanism | Coordinator handler |
|---|---|---|---|
| Lid open/closed | `PowerManager` → `LidObserver` (`LidStateTransitionFilter`) | `kIOGeneralInterest` on `IOPMrootDomain`, `AppleClamshellState` | `handleLid` |
| Flag dropped by macOS | `PowerManager` | root-domain interest, `IOPSNotificationCreateRunLoopSource`, display sleep/wake, system wake, screen parameters | `reapplyFlag` |
| Lid angle | `LidAngleSensor` → `LidAngleObserver` (`AngleSampleFilter`) | HID feature report, polled | `handleAngle` |
| Gesture modifier | `GestureController.readModifier` (`FnKeyReading`) | `CGEventSource.flagsState`, `NSEvent.modifierFlags`, `CGEventSource.keyState(63)`, `BuiltInFnKeyReader.fnDown`, read per sample | inside `handleAngle` |
| Built-in keyboard's Fn key | `BuiltInFnKeyReader` | `IOHIDDeviceOpen` on the keyboard whose `Built-In` property is set (Input Monitoring), input values of the Fn element on the main run loop; reopened on `didBecomeActiveNotification`, `didWakeNotification` and from the permission row | read by `GestureController` |
| Gesture | `GestureController` (`OptionGateFilter`, `LidProgressDriver`) | fed by `handleAngle` while `gestureWanted` | `handleGesture` |
| Displays | `DisplayTopologyMonitor` | `didChangeScreenParametersNotification`, `CGGetOnlineDisplayList` | `handleDisplays` |
| Battery | `BatteryMonitor` | `IOPSNotificationCreateRunLoopSource`, `IOPSCopyPowerSourcesInfo` | `handleBattery` (`LowBatteryPolicy`) |
| Thermal | `ThermalMonitor` | `ProcessInfo.thermalStateDidChangeNotification` | `handleThermal` |
| Sleep behind the arm | `SleepInterruptionMonitor` | `NSWorkspace.willSleepNotification` while armed | `handleExternalSleep` (`SleepInterruptionPolicy`) |
| Screen lock | `ScreenLockObserver` | `com.apple.screenIsLocked` / `…Unlocked`, `CGSessionCopyCurrentDictionary` | `applyGestureHold` |
| Hot keys | `HotKeyController` | Carbon `RegisterEventHotKey` | `setMode` via `ModeCycle.nextOnShortcut` |
| Status item | `StatusItemController` | `NSStatusItem` | `buildMenu`, `ModeCycle.nextOnRightClick` |
| CLI | `CommandServer` | `DistributedNotificationCenter`, `dev.rubens.koffeelid.command` | `perform(_, source: .cli)` |
| Activity | `ActivityMonitor` | journal tail, kqueue, registry reads | `handleActivity` |
| Local input | `LocalInputMonitor` | `CGEventSource.secondsSinceLastEventType`, polled every 2 s during a hold-off | `checkLocalInput` |
| Preferences | `Preferences.onChange` (one subscriber) | UserDefaults setters | `preferenceChanged` |

Who creates and releases what: `PowerManager` owns the root-domain connection, the kernel flag and the four
assertions (`acquireAssertions`/`releaseAssertions`; `keepDisplayOn` and `tickleUserActivity` are properties
whose setters create and release). `SleepLock` owns `pmset disablesleep` and its marker file.
`InternalDisplayBrightnessController` owns the panel brightness and its recovery file. `BuiltInFnKeyReader`
owns the open HID device of the built-in keyboard.
`LidReopenLockController` owns the lock retry chain. The coordinator decides when; they never decide.

`applyCaffeinate()` runs on arm, disarm, mode switch, `releaseManual` and both lid transitions:
`keepDisplayOn = mode.keepsDisplayOn`, `tickleUserActivity = mode.keepsDisplayOn && lid not closed`.

## The lid gesture

```
LidAngleObserver (30 Hz, main)
  → handleAngle
      held = armWithOption && gesture.readModifier()
      ├─ gestureWanted → GestureController.feed(angle, modifierDown: held)
      │     OptionGateFilter   trusted after 2 down samples, untrusted after 3 up, never beyond a 20 s hold
      │     LidProgressDriver  idle → started → progress → armed | cancelled(optionLost · reversed · timeout)
      │        → handleGesture: idle → arm(source: .gesture); armed → effect.followLidFromHere()
      ├─ state == .armedWaitingClose, reopenWatch alive → ReopenCancelWatch.update(held:)
      │        reopened | stalled → effect.stop(retracting: true), releaseManual
      └─ state == .armedWaitingClose → effect.feed(angle, changedAt:, holding: held)
```

`gestureWanted = armWithOption && !externalDisplay && (!isArmed || (state == .armedWaitingClose && armSource != .gesture))`.
`refreshGestureSampling()` adds or removes the `"gesture"` consumer on the sampler and resets the detector on
every change of that boolean; `arm`, `disarm` and every gesture preference change reset it too, and
`LidProgressDriver` resets itself when the modifier is released after `.armed`. The detector never stays
latched across states.

`GestureArmHold` phases: `off → awaitingLock` when the lid opens on a gesture arm (`.keepArmed`);
`awaitingLock → holding` when the screen locks (`.held`); `holding → off` on unlock (`.release(.unlocked)`);
`awaitingLock → off` when `LidReopenLockController.onGaveUp` fires (`.release(.neverLocked)`). `clear()` on
`disarm`, a fresh manual mode and `releaseManual`. While holding, `handleLid(.opened)` does not start the
effect.

## The lid effect

`EffectController` (`@MainActor`) owns the overlay panel, the renderer, the capture, the `FoldTracker`, the
`FoldGeometry` and the `AngleSmoother`. The coordinator calls `start()`, `stop(retracting:)`,
`feed(angleDegrees:changedAt:holding:)`, `followLidFromHere()`, sets `gateToStartAngle`,
`foldThresholdDegrees` (kept equal to `gestureActivationDegrees`: the effect has no threshold of its own) and
`parameters`.

- `start()` prepares only: an invisible `EffectOverlayPanel` at `.screenSaver` level, a paused `PlaneRenderer`,
  a `DesktopCapture` whose shareable content is fetched ahead, and the `"effect"` consumer on the sampler
  (`onNeedsAngleSampling`). Nothing is captured.
- `feed` runs `FoldTracker.update(angle:now:holding:)` on the delivery time and feeds `AngleSmoother` with
  `FoldGeometry.fold(angle:zeroAngle:)` stamped with the time the sensor value first appeared.
  `.foldBegan` → `beginSession()` (a still from `SCScreenshotManager`, then the 60 fps `SCStream`; the start
  goes ahead only while the session still owns its capture). `.foldEnded` → `endSession(immediately: false)`.
- The renderer pulls `currentFoldRadians()` every display frame (up to 120 Hz) from the smoother; the panel's
  alpha follows `isCapturing && hasContent && fold > 0`.

**Who owns the reset.** `FoldTracker` does; there is no reset timer. On each sample: movement of 1.5° or more,
or `holding`, restarts the stillness clock (`lastMovement`). Once the lid has been below the zero angle and
still for `settleDelay`, the rest angle eases to `angle + threshold` over `settleDuration` (0.6 s, smoothstep),
so the fold reaches 0 and `.foldEnded` fires. `AngleSmoother` honours a value that changes without a new
sensor time by collapsing its buffer. Three timers exist around it, all on the main run loop:
`sessionEndTimer` (0.75 s linger before the capture stops; skipped if a fold is running again, the next
`.foldEnded` schedules a new one), the retraction tick (120 Hz for 0.3 s, fade-out from 60 %), and the
simulation tick (60 Hz).

The reset therefore depends on two inputs only: samples keep arriving (they do at 30 Hz while the `"effect"`
consumer is registered, changed value or not) and `holding` being true only while the modifier key is
physically down. Nothing on this path reads `ArmMode`.

`FoldTracker` is closing-only: the rest angle follows the lid whenever it opens; the zero angle is
`min(rest − threshold, startBelowAngle)`, the second term present only for gated (non-gesture) arms.
`followLidFromHere()` drops the gate and rebases the zero to the current angle unless a fold is already
running; when that fold ends the gate returns.

`PlaneShader.source` (MSL, compiled at runtime) draws the inner screen: a display row at height `h` samples
the desktop at `h·cos(a)^zoom`; the top is `1 + 2(1 − cos a)·perspective` times narrower with straight edges;
blur radius `strength·h·|sin a|·65` blended over four Gaussian levels; sides and top melt over
`0.35·edgeSoftness·h·sin a` and `0.08·edgeSoftness·sin a`; the picture is multiplied by
`1 − 0.55·shading·h·sin a`. `PlaneRemap` is the same maths in Swift: the tested reference for the shader, not
called at runtime. Change one, change the other, and update `PlaneRemapTests`.

`DesktopCapture` excludes the overlay's own window, caps the long side at 2560 px, and guards start/stop races
with `CaptureStartGate` (a stop landing during an in-flight start wins; the token is taken before the first
`await`).

## Auto-arm on activity

```
Claude Code hook ─┐
zsh preexec/precmd ┴▶ KoffeeLidHook ─▶ activity.jsonl ─▶ ActivityJournalTailer ─▶ ActivityMonitor
                                                           ActivitySessionStore + ActivityJobStore
                                                           ActivityProcessWatcher (kqueue exit)
                                                           ClaudeProcessRegistry (sessions/<pid>.json)
   ActivitySnapshot ─▶ KoffeeLidController.handleActivity ─▶ ActivityArmPolicy ─▶ applyAuto
```

A file, not a socket: hooks fire while the app is down or being relaunched, and the journal is replayed at
launch (this boot's events only, from `activity.1.jsonl` then `activity.jsonl`; dead or recycled pids pruned;
the tailer starts at the byte offset the replay consumed). A separate tiny binary, not the app: it runs inside
every Claude Code turn and every shell command, so it must start fast, never launch the app and never block.

`ActivityTrim` reduces a hook payload to event name, session id, agent id, tool name, notification type,
source and background task ids, caps every field and the line (4 KB), and turns anything unparseable, or any
name outside `ActivityEventName.claudeCodeEvents`, into a `ParseError` line. `ActivityJournalWriter.append` is
one `write` on an `O_APPEND` descriptor. The journal rotates to `activity.1.jsonl` above 20 MB, or above 5 MB
while idle.

`ActivitySessionStore` (pure, replay and live events share one path), per session:

| Event | State |
|---|---|
| `SessionStart` | `idle` (`working` when `source == "compact"`); helpers and background ids cleared otherwise |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `PreCompact`, `PostCompact` | `working` |
| `PreToolUse` | `working`; `waiting` for `AskUserQuestion` and `ExitPlanMode` |
| `PermissionRequest`, `StopFailure`; `Notification` of type `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` | `waiting` |
| `Stop` | `done` if no live helper and no background id; otherwise held `working` (`pendingDone`) |
| `Notification` `idle_prompt` / `agent_needs_input`, state `working`, 50 s of main-agent quiet | treated as a lost `Stop` |
| helper event (`agent_id` set) | refreshes the helper's last-seen time; `SubagentStop` removes it; a helper permission request blocks the turn (`waiting`), and the next helper event ends that wait; a helper active after `done` reopens it |
| `SessionEnd`, process exit | session removed |

Time rules (`tick`): a helper counts as live for 240 s after its last event; a held `Stop` becomes `done` 90 s
after everything cleared, or 30 min after the last event; `done` becomes `idle` after 20 min; a session silent
for 2 h is removed. Registry rescues (`ActivityMonitor.checkRegistry`): a `working` session quiet for 20 s
with nothing out is checked every 15 s; registry `idle` stamped after the last main event → `turnOver`;
registry `busy` → `noteBusy` (and one warning after 5 min without a hook); a `waiting` session whose registry
says `busy` stamped 2 s after the wait began → `dialogAnswered`. Only `working` counts as running.

`ActivityJobStore`: one slot per job id (`zsh-<shell pid>`), counted once `armAfter` has elapsed, dropped on
`job end`, on the owner shell's exit, or after 2 h.

`ActivityArmPolicy` is a level. `update(running:enabled:now:)` turns it on with the first running kind and
accumulates the kinds seen (`involved`); when nothing runs, `offAt = idleSince + currentHoldOff` (the longest
`holdOffs[kind]` over `involved`, or 60 s while `disarmOnce` is pending). `tick` returns
`.off(releaseManual:)` when it passes; `userActive` drops it at once during a countdown; `suspend()` and
`armFailed()` zero it and suppress it until the running set empties. The coordinator schedules one timer at
`nextDeadline` and a 2 s local-input poll while a countdown runs.

`HookInstaller` is stateless and has no link to the coordinator; the CLI verbs `install-hooks`,
`uninstall-hooks` and `shell-init zsh` run it in-process without contacting the app. `HookConfig` transforms
the `hooks` object of `~/.claude/settings.json` (entries recognised by the suffix
`/Contents/MacOS/KoffeeLidHook hook`, other tools' entries untouched), `HookSettingsFile` loads strictly and
backs up to `settings.json.backup-koffeelid` before writing, `ShellInit` builds the snippet and edits
`~/.zshrc` (it removes only what sits between its two header lines, its marker comment, and uncommented
`shell-init zsh` lines that name KoffeeLid).

## Updates

`UpdateController` (main actor, `shared`) owns the feature; `AppDelegate.startUpdates()` wires it after the
coordinator has started. The decisions are Core's and tested; the app layer runs requests and words answers.

| Piece | Where | What it is |
|---|---|---|
| `UpdateSchedule` | Core | when an unasked check is due: fresh at launch, a week after an answer, an hour or more after a failure. The controller asks it 10 s after launch, on a 30-minute timer and at `NSWorkspace.didWakeNotification` |
| `UpdatePanel` | Core | the Updates group: `press()` is `.check` or `.update(release)`; `checked` answers a press, `autoChecked` a check nobody asked for, `installFailed` what the last install ended with |
| `UpdateSession` | Core | the update window: downloading → preparing → ready or manual → installing, failed from anywhere, `retry`, `installStalled` |
| `UpdateChecker`, `UpdateDownload` | app | the latest-release request (`KOFFEELID_UPDATE_FEED` replaces its URL, `docs/development.md`) and one fetch with progress, held against the asset's stated length and SHA-256 before it is reported |
| `UpdateStager` | app, off the main thread | mounts the image (`hdiutil`, then `diskutil image`), copies the app carrying our bundle identifier to `updates/staged/`, applies `StagedUpdateCheck` (same app, strictly newer, this macOS is enough) and `CodeSignature.verify` (valid; same team as the running app when it has one), detaches |
| `UpdateInstaller` | app | `obstacle` (not an `.app`, translocated, not writable, another volume) and `start`, which writes `UpdateInstallScript.text` to `updates/install.sh` and starts it through `DetachedProcess` |
| `UpdateInstallScript` | Core | the helper's text, a `/bin/sh` script told everything as arguments (`UpdateInstallPlan`): wait for the pid, two renames, the outcome (`UpdateResult`), `open`, watch for the executable in `ps`, roll back |
| `UpdateWindowController`, `UpdateView` | app | the window, sized to what it says around its top-left corner |
| `NotificationsController` | app | the `update` category with its one action; as the centre's delegate it turns the action and a click into `UpdateController.presentUpdate()`, and shows that one notification even while the app is frontmost |

The order of an install is what keeps a failure harmless. Everything that can refuse (the network, the file,
the image, the version, the signature, the folder's permissions) runs while the app is up and can say so; the
helper is started before the quit and only acts once the pid is gone, so the app's own `shutdown()` has
already disarmed, cleared the kernel flag and released the sleep lock, and the watchdog has seen a clean exit
and stood down; an app that has not quit after `UpdateInstallPlan.stallNotice` stops the helper
(`UpdateInstaller.stop`) before it says so, so no helper is ever left waiting for a quit that comes later;
after the quit there are two renames on one volume and a launch, each with its way back. A
fetch or an unpacking that ends after the session it belonged to is dropped by a generation counter.

## Persistence

`~/Library/Application Support/KoffeeLid/` (`AppSupport`):

| File | Writer | Content |
|---|---|---|
| `koffeelid.pid` | app | pid line, executable path line; removed on clean quit |
| `relaunch-history.json` | watchdog | relaunch timestamps for `CrashLoopGuard` |
| `display-brightness-recovery.json` | app | display id and brightness before darkening; removed on restore |
| `sleep-lock` | app | pid of the instance that engaged `pmset disablesleep 1` |
| `activity.jsonl`, `activity.1.jsonl` | hook binary; rotated by the app | one JSON event per line, snake_case keys |
| `diagnostics.log`, `diagnostics.1.log`, `diagnostics.lock` | app and watchdog (`DiagnosticFileWriter`, `flock`) | timestamped lines, rotated at 256 KB |
| `update-resume` | app, at the quit an Install and Relaunch asked for | `<mode> <seconds since 1970>`; read once and removed at the next launch (`UpdateResume`) |
| `updates/` | app, and the install helper once the app has quit | `KoffeeLid-<version>.dmg`, `staged/KoffeeLid.app`, `install.sh`, all three removed when a fetch starts, is cancelled, and at launch; `previous/KoffeeLid.app`, the helper's alone, which it deletes once the new version is seen running; `install.log`; `result`, one line (`UpdateResult`), which the launch that reads it renames to `result.read` for the helper to see, the next launch or the helper removing that |

UserDefaults domain `dev.rubens.koffeelid`: the keys and defaults in `docs/functional.md` § Settings and
defaults, registered in `Preferences.init`. `effectParameters` is a JSON `EffectParameters`; a stored value
that does not decode falls back to `EffectParameters.default`, and every read and write is `clamped()`.

Outside the app's own folder: `/etc/sudoers.d/koffeelid`, `~/.claude/settings.json` (+ `.backup-koffeelid`),
`~/.zshrc`, `/usr/local/bin/koffeelid` (a zsh `exec` wrapper written by `script/install.sh`; a symlink would
break `Bundle.main`).

## Privilege boundary

Everything runs as the user except two things. The sudoers rule is installed and removed as root through the
administrator dialog (`NSAppleScript`, `do shell script … with administrator privileges`); the script text is
built in Core (`SleepLockSetup`), validated user name, absolute tool paths, staged inside `/etc/sudoers.d`,
checked with `visudo -cf`. After that, `sudo -n` runs exactly `/usr/bin/pmset disablesleep 1` and
`… disablesleep 0`, nothing else. There is no privileged helper, no XPC service, no `SMJobBless`.

Process commands are scoped to the bundle: the one `pkill` in the tree (`script/install.sh`) matches the full
`KoffeeLid.app/Contents/MacOS/` path, and the watchdog uses the pid from the pid file and checks `proc_pidpath`
against the recorded executable. The Settings reset restarts `usernoted` and `NotificationCenter` by name; those
are Apple's daemons, not KoffeeLid processes.

## Threading

- The coordinator, the UI, `ActivityMonitor` and `EffectController` are `@MainActor`. IOKit callbacks are
  routed to main (`IONotificationPortSetDispatchQueue(.main)`, run-loop sources on the main loop, observers
  with `queue: .main`).
- `LidAngleObserver` ticks on its own serial queue (`DispatchSourceTimer`) and hops to main before `onSample`.
  `addConsumer`/`removeConsumer` are main-thread only; the 30/120 Hz reschedule uses the timer captured by the
  handler, not the main-thread property.
- `PlaneRenderer.draw(in:)` runs on the main thread; `submit(pixelBuffer:)` is called from the capture queue
  and hands the latest buffer over under a lock; at most two command buffers are in flight.
- `ActivityJournalTailer` reads on its own queue and delivers parsed events to main. `ActivityProcessWatcher`
  sources fire on main.
- `DiagnosticLog` appends on a serial queue; `flush()` before `exit()`.
- Timers that must fire during menu tracking are added in `.common` mode (the user-activity declaration, the
  activity deadline, the local-input poll, the activity monitor's deadline).

## Watchdog contract

The watchdog resolves its bundle from `proc_pidpath` of itself and stands down (exit 0, launchd does not
restart a successful exit) when it is not inside an `.app`, when there is no pid file, or when the pid file
predates this boot. Otherwise it polls the recorded pid every second (alive **and** still the recorded
executable). After death: pid file gone → clean exit, stand down; pid changed → follow the new instance;
otherwise `CrashLoopGuard` (3 relaunches per 10 min, the attempt recorded before `open` runs) → `/usr/bin/open
<bundle>` → wait up to 30 s for a fresh pid. `RelaunchAgentController.kickstartIfEnabled()` runs on every app
start so a live watchdog observes the current pid.

## Build, signing, entitlements

- `script/bootstrap.sh` runs XcodeGen; `KoffeeLid.xcodeproj` is generated and git-ignored. Sources are
  included by directory, so adding or removing a file means regenerating.
- Swift 5 language mode, `SWIFT_STRICT_CONCURRENCY: minimal`, macOS 15 deployment target, Hardened Runtime,
  automatic signing with the Wooflab team, Developer ID (`DEVELOPMENT_TEAM: 85F6AC5QZF`,
  `CODE_SIGN_STYLE: Automatic` in `project.yml`). `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` keeps
  `get-task-allow` out of every build. The signing identity, `Developer ID Application: Wooflab
  (85F6AC5QZF)`, is not written into any script: `script/signing.env` looks it up in the keychain by team
  identifier.
- Entitlements: `com.apple.security.app-sandbox = false`, nothing else.
- `Info.plist`: `LSUIElement`, the `koffeelid` URL scheme, automatic and sudden termination disabled (a quit
  must run `shutdown()`), `en` + `fr`.
- A post-build script copies `App/LaunchAgents/dev.rubens.koffeelid.agent.plist` to
  `Contents/Library/LaunchAgents/`; the two tools are embedded in `Contents/MacOS`.
- The version lives in `App/Info.plist`, `KoffeeLidCore.version` and its assertion in `SmokeTests`.
- `script/build.sh`, `install.sh` (refuses only while quitting would sleep the Mac at once — armed, lid shut,
  no external display; `KoffeeLidController.quitWouldSleepTheMac`, no override), `run.sh`,
  `release.sh` (archive → Developer ID export → verify → notarize and staple the app → `script/make-dmg.sh`
  builds the signed disk image → notarize and staple the image → assert Gatekeeper accepts both → print the
  image's path; it publishes nothing). `script/signing.env` holds the team id, the `wooflab-notary` notarytool
  profile name, the app name, bundle id, GitHub repo and DMG accent colour that every signing/build/publish
  script sources.
- The app icon is `App/Resources/AppIcon.icon`, an Icon Composer document compiled by `actool`. `project.yml`
  adds it as a single `type: file` source and excludes it from the recursive `App/Resources` entry, so Xcode
  receives the document whole rather than its four layer files.
