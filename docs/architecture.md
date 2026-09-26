# Architecture

How the code is organised and who owns what. Product behaviour is in `docs/functional.md`, the macOS
interfaces in `docs/macOS.md`, the traps in `docs/pitfalls.md`.

## Targets

Five targets, dependencies strictly downward. `project.yml` (XcodeGen) defines the three Xcode targets and
links the SwiftPM package; `Package.swift` defines the two libraries and their tests.

| Target | Kind | Depends on | Contents |
|---|---|---|---|
| `KoffeeLidCore` (`Sources/KoffeeLidCore`) | SwiftPM library, Foundation only | — | Every policy, filter and state machine as a value type with injected time, plus the update feature's rules (`ReleaseVersion`, `LatestRelease`, `UpdateCheck`, `UpdateSchedule`, `UpdatePanel`, `UpdateSession`, `StagedUpdateCheck`, `UpdateInstallPlan`/`UpdateInstallScript`/`UpdateResult`, `DetachedProcess`), the Settings window's `SettingsStatus` (which colour a state takes) and the Health page's rules (`Health`, `HealthRules`, `HealthReport`, `CrashReports`). All logic tests live against it. |
| `LidPlaneKit` (`Sources/LidPlaneKit`) | SwiftPM library (AppKit, Metal, ScreenCaptureKit) | Core | The lid effect: `EffectController`, `DesktopCapture`, `PlaneRenderer`, `PlaneShader`, `EffectOverlayPanel`, `CaptureStartGate`, `PlaneRemap`. |
| `KoffeeLid` (`App/Sources`) | app, `LSUIElement` | Core, LidPlaneKit | The coordinator, one adapter per system API, the UI, the update feature (`UpdateController` and what it runs), App Intents, the CLI client. |
| `KoffeeLidWatchdog` (`Watchdog/Sources/main.swift`) | tool embedded in `Contents/MacOS` | Core | LaunchAgent that relaunches the app after an unclean exit. |
| `KoffeeLidHook` (`Hook/Sources/main.swift`) | tool embedded in `Contents/MacOS` | Core | `hook` (Claude Code), `hook codex`, `hook copilot <event>`, `hook opencode` and `job begin\|end`: append one line to the activity journal. |

Rule: what can be expressed without AppKit or IOKit and tested with an injected clock belongs in Core. App
files are thin adapters around one system API with closures back to the coordinator (`onX`, `onLog`).

`main.swift` runs `CommandLineClient.run` first: when `argv[1]` is a verb the process forwards it and exits
before AppKit starts. Otherwise it starts `NSApplication` with the `.accessory` policy. `AppDelegate` exits a
duplicate instance before `start()` (so a second build can never touch the flag under a live session), starts
the coordinator, routes `koffeelid://` URLs, owns the Settings and onboarding windows, and calls `shutdown()`
from `applicationShouldTerminate`.

The Settings window (`App/Sources/UI/Settings*.swift`) is one `SettingsWindow`: an `NSWindow` with a
`.preference` `NSToolbar` over a single `NSHostingController`, built once by `AppDelegate.showSettings()` and
re-shown. Its eight pages are SwiftUI views built only from the kit in `SettingsKit.swift`; the window's height
follows the shown page. `SettingsModel` is what the pages share: bindings onto `Preferences.shared` that
announce their own changes to SwiftUI (the coordinator stays the one subscriber of `Preferences.onChange`), and
the states a page reports, polled on the main thread and started and stopped by the window (open, close,
miniaturise), never by a view: the grants, the hooks and the login item every 2 s, the lid angle and the
activity counts every 0.25 s, the window being a consumer of `LidAngleObserver` for as long as it is up. The
rules the pages apply are Core's: `SettingsStatus` colours a state (a missing grant is red when
`SettingsGrant.isRequired`, orange otherwise, through `HealthRules.grant`; `PermissionItem.required`, the
onboarding's mark, is the same property) and `UpdatePanel` is the Updates group, whose state is the app's
(`UpdateController.shared`) and not the page's. The Health page (`SettingsHealthPage`) is built the same way:
two tables and nothing else. `HealthReport.checks(for:)` and `HealthReport.readings(for:)` (Core, tested in
`HealthTests`, which holds them to `HealthLimits`: thirteen checks, eight readings) turn a `HealthFacts` of plain
values into `HealthItem`s (a level, a `HealthWord`, a `HealthDetail`, a `HealthFix`) and `HealthReading`s (a
`HealthValue`, a `HealthDetail`), still out of any language; `HealthWords` (`HealthWords.swift`) puts them in the
catalog's words as `HealthRow`s and `InfoRow`s. The facts come from three places: the model's poll (the grants,
the sensor, the lid angle), the coordinator's read-only state as the page draws (`mode`, `isArmed`, `armSource`,
`statusLine()`, `lidSleepFlagSet`, `lidSleepRestorePending`, `sleepLockEngaged`, `builtInFnReaderState`,
`lastSafetyStop`, and `ActivityMonitor.lastClaudeEvent` / `lastCodexEvent` / `lastEvent(for: .copilot)` /
`lastEvent(for: .opencode)` / `lastTerminalEventAt`), and `HealthCheck`, which the window asks to read when it
opens on Health, when Health is picked and on Check Again, never on a timer, all off the main thread: the crash
reports (`CrashReports`), whether the watchdog runs (`ProcWalk.isRunning`, by file identity),
`~/.claude/settings.json`'s hook count and whether any event in it carries KoffeeLid's marker at all, Codex's
trusted hook count (`HookInstaller.codexInstalledCount`) and the same any-marker test against
`~/.codex/hooks.json` whatever its trust, how many of Copilot's hooks point at this copy, whether
`disableAllHooks` is set and whether `~/.copilot/hooks/koffeelid.json` exists at all, and whether the OpenCode
plugin is current or stale and whether `~/.config/opencode/plugins/koffeelid.js` exists at all. Each of the
five hooks is a line on Health only while its presence fact holds (`HealthFacts.claudeHooksPresent` /
`codexHooksPresent` / `copilotHooksPresent` / `opencodeHooksPresent`, and `held.contains(.zshHook)` for the
zsh line, which has no broken state of its own): nothing of KoffeeLid's set up is no line and no warning, not
an install the user may never make. Check Again shows a spinner until they land, and at least
`HealthConstants.minimumBusy`. The
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
| `closedLidReminder: ClosedLidReminder` | the last sound, the last lid close and the last power source, for the closed-lid reminders |
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
- `shutdown()`: stops the activity monitor, the screen-lock observer, the built-in Fn reader and the timers; puts
  back any volume the lid-close sound forced (`LidCloseSoundPlayer.stop`); if armed, cancels the lock and stops
  the effect; restores brightness; clears the flag (three attempts, 0.3 s apart) only if
  `wasArmed || flagClearPending || power.lidSleepDisabled`, **while the sleep lock still holds**, as `disarm`
  does; then releases the sleep lock and the assertions; removes the pid file. The order matters: clearing the
  flag with the lid shut makes the kernel evaluate the clamshell at once, and only the lock stops that
  evaluation from starting a sleep (`docs/pitfalls.md` § Sleep and the kernel flag).
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
| Disarm | `disarm()` | always clears, before the sleep lock is released; failure → retry every 30 s |
| Quit | `shutdown()` | three attempts, only if this instance set it or a clear is pending; before the sleep lock is released |

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
| Displays | `DisplayTopologyMonitor` | `didChangeScreenParametersNotification`, `CGGetOnlineDisplayList` | `remindIfClosed(.displaysChanged)`, then `handleDisplays` |
| Battery | `BatteryMonitor` | `IOPSNotificationCreateRunLoopSource`, `IOPSCopyPowerSourcesInfo` | `handleBattery` (`LowBatteryPolicy`), then `remindIfClosed(.chargerUnplugged)` on the switch to battery |
| Thermal | `ThermalMonitor` | `ProcessInfo.thermalStateDidChangeNotification` | `handleThermal` |
| Sleep behind the arm | `SleepInterruptionMonitor` | `NSWorkspace.willSleepNotification` while armed | `handleExternalSleep` (`SleepInterruptionPolicy`) |
| Screen lock | `ScreenLockObserver` | `com.apple.screenIsLocked` / `…Unlocked`, `CGSessionCopyCurrentDictionary` | `applyGestureHold` |
| Hot keys | `HotKeyController` | Carbon `RegisterEventHotKey` | `setMode` via `ModeCycle.nextOnShortcut` |
| Status item | `StatusItemController` (`MugShape`; the auto-armed cup's badges from `ActivityIcons`) | `NSStatusItem` | `buildMenu`, `ModeCycle.nextOnRightClick` |
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
Claude Code hook ──┐
Codex hook ────────┤
Copilot hook ──────┤
OpenCode plugin ───┤
zsh preexec/precmd ┴▶ KoffeeLidHook ─▶ activity.jsonl ─▶ ActivityJournalTailer ─▶ ActivityMonitor
                                                           ActivitySessionStore + ActivityJobStore
                                                           ActivityProcessWatcher (kqueue exit)
                                                           ClaudeProcessRegistry (sessions/<pid>.json)
                                                           CodexDaemonClient (control socket: thread/read, thread/loaded/list)
                                                           CodexRollout (rollout-…-<session>.jsonl, last 64 KB)
                                                           CopilotTranscript (session-state/<session>/events.jsonl, last 64 KB)
   ActivitySnapshot ─▶ KoffeeLidController.handleActivity ─▶ ActivityArmPolicy ─▶ applyAuto
```

A file, not a socket: hooks fire while the app is down or being relaunched, and the journal is replayed at
launch. The launch order: replay (this boot's events only, from `activity.1.jsonl` then `activity.jsonl`, the
app's own verdict lines among them) → the time rules (`tick`), so a stale session is dropped → the prune with
the registry (`pruneDead`: dead or recycled pids, a Claude Code pid whose registry record names another
session among them; a session on a shared Codex host kept) → the jobs' shell probe (`probeJobs`) →
`checkRegistry(quietSeconds: 0)`, the registry rescue on every working Claude Code session whatever its quiet → `checkCodex(atLaunch: true)`, after
`thread/loaded/list` has ended each working session on the managed daemon whose thread the daemon does not
hold (asked only when the managed daemon hosts one and its socket exists) → `checkCopilot(atLaunch: true)`, the
`events.jsonl` check of every working Copilot session whatever its quiet → the first `sync()`. All of it comes before the first
publish (`launched` holds `sync` back until the daemon's answer, at most 1 s; a 2 s fallback,
`launchAnswerFallbackSeconds`, runs `finishLaunch` once should the answer never arrive, and a later answer is
dropped) and only ends turns, but for a
dialog the registry says was answered; the tailer starts at the byte offset the replay consumed. A separate
tiny binary, not the app: it runs inside every Claude Code, Codex and Copilot turn, for every OpenCode event
a plugin forwards to it (OpenCode has no command hooks) and around every shell command, so it must start fast, never launch the app and
never block. The hook's arguments say which agent sent the payload (`HookCall`: `hook` is Claude Code, `hook
codex` Codex, `hook copilot <event>` Copilot, `hook opencode` OpenCode), never the payload: Claude Code and
Codex send the same event names, Copilot's camelCase payloads name none, and OpenCode's are its own. Every
`hook …` form reads its stdin to the end before anything else, so the agent writing the payload never meets a
closed pipe; any other arguments after `hook`, or `KOFFEELID_DISABLE=1`, then write nothing, and every `hook …`
form exits 0 (Copilot denies a tool whose hook fails); only a malformed `job` line, or no known verb, exits 2.

`ActivityTrim` reduces a hook payload to event name, session id, agent id, tool name, turn id (Codex's
`turn_id`, else Claude Code's `prompt_id`), notification type, source, background task ids and, on
`SessionStart`, `UserPromptSubmit`, `Stop` and `Interrupt` only, the transcript path (up to 1024 characters),
stamps it with the agent, caps every field and the line (4 KB), and turns
anything unparseable, or any name outside that agent's events (`ActivityEventName.hookEvents(for:)`), into a
`ParseError` line; an OpenCode event the mapping below leaves out, or one of no session, writes no line at all.
Each agent's payload is read its own way:

- **Claude Code and Codex** (`event(fromHookPayload:agent:loggedAt:)`): `hook_event_name` names the event,
  which must be one of `claudeCodeEvents` or `codexEvents`.
- **Copilot** (`copilotEvent(fromHookPayload:named:loggedAt:)`): the event is the hook's third argument, one of
  Copilot's seven words in `ActivityEventName.copilotHookEvents` (`sessionStart`, `userPromptSubmitted`,
  `postToolUse`, `postToolUseFailure`, `notification`, `agentStop`, `sessionEnd`), mapped to `SessionStart`,
  `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop`, `SessionEnd`; the body gives
  `sessionId` (else `session_id`), `toolName`, `notification_type`, `source` and `transcriptPath`. Copilot
  names no turn. The hook then passes the line through `CopilotSessionState.line`: a line whose session id has
  no folder under the session-state root (`$COPILOT_HOME/session-state`, else `~/.copilot/session-state`), when
  that root exists, is a subagent's and is dropped; a `SessionStart`, `UserPromptSubmit` or `Stop` that names
  no transcript gets `<root>/<session id>/events.jsonl` when the root exists.
- **OpenCode** (`opencodeEvent(fromHookPayload:loggedAt:)`): `hook_event_name` is OpenCode's own event type,
  mapped below; nil writes nothing. A session with a `parent_id` is a subagent, whose events become helper
  events of the parent (`sessionId` the parent, `agentId` the child). An event of no session (`session_id`
  null, or `global` for a form outside any session) writes nothing. OpenCode names no turn. `opencode_pid`
  becomes the claimed `agentPid`.

  | OpenCode event | top-level session | subagent |
  |---|---|---|
  | `session.created`, `session.forked` | `SessionStart` | `SubagentStart` |
  | `session.inbox.enqueued`, `session.execution.started` | `UserPromptSubmit` | `UserPromptSubmit` |
  | `session.tool.called` / `.success` / `.failed` | `PreToolUse` / `PostToolUse` / `PostToolUseFailure` | the same |
  | `permission.asked` (its action as the tool name) | `PermissionRequest` | `PermissionRequest` |
  | `permission.replied`, `status` `once` or `always` | `PostToolUse` | `PostToolUse` |
  | `permission.replied`, `status` `reject` | `PermissionDenied` | `PostToolUse` |
  | `form.created` with `question: true` | `Notification` `elicitation_dialog` | `PermissionRequest` |
  | `form.created` otherwise | nothing | nothing |
  | `form.replied`, `form.cancelled` | `PostToolUse` | `PostToolUse` |
  | `session.compaction.started` / `.ended`, `.failed` | `PreCompact` / `PostCompact` | the same |
  | `session.execution.succeeded` / `.failed` / `.interrupted` | `Stop` / `StopFailure` / `Interrupt` | `SubagentStop` |
  | `session.deleted` | `SessionEnd` | `SubagentStop` |
  | anything else | nothing | nothing |

Each line carries the pid of the nearest ancestor running its agent (`ProcWalk.pid(of:inChainFrom:claimed:)`;
a Codex started from a Claude Code tool call has both in its chain). A claimed pid, OpenCode's server as its
payload names it, wins only when it is one of those ancestors running OpenCode. A Copilot line's pid is the
`copilot` process, the hook's parent; an OpenCode line's is the server, which hosts every session of every
client. For a
Codex TUI session that ancestor is Codex's managed daemon, shared by every TUI session and outliving them; for
a desktop-app session, the app's own `codex app-server`, shared the same way. The monitor reads each Codex
pid's path and arguments once and marks its sessions `hostedBySharedCodex` (`ProcWalk.isSharedCodexHost`: any
`codex` with an `app-server` argument) and `hostedByManagedDaemon` (`ProcWalk.isManagedCodexDaemon`: the
`--managed-daemon` flag or the `/app-server-daemon/` path).
`ActivityJournalWriter.append` is one `write` on an `O_APPEND` descriptor. The journal rotates to
`activity.1.jsonl` above 20 MB, or above 5 MB while idle.

`ActivitySessionStore` (pure, replay and live events share one path), per session, whichever agent hosts it:

| Event | State |
|---|---|
| `SessionStart` | `idle`, helpers and background ids cleared; unchanged when `source == "compact"` (helpers and background ids kept too) |
| `SessionStart` of a Copilot session | unchanged: records its pid and transcript path only (Copilot starts a session with its first prompt, after the prompt's line) |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | `working` |
| `PreCompact` | `working`, remembering the state it found (`stateBeforeCompaction`) unless an earlier `PreCompact` since the last turn boundary already did; a prompt, `Stop`, `Interrupt` or non-`compact` `SessionStart` forgets it |
| `PostCompact` | restores `stateBeforeCompaction` (`working` if none was recorded) |
| `PreToolUse` | `working`; `waiting` for `AskUserQuestion`, `ExitPlanMode` (Claude Code) and `request_user_input` (Codex) |
| `PermissionRequest`, `StopFailure`; `Notification` of type `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` | `waiting` |
| `Stop` | `done` if no live helper and no background id; otherwise held `working` (`pendingDone`) |
| `Interrupt` (Codex; OpenCode's `session.execution.interrupted`) | `done`, helpers and background ids cleared: Esc ended everything |
| `Notification` `idle_prompt` / `agent_needs_input`, state `working`, 50 s of main-agent quiet | treated as a lost `Stop` |
| any event of a turn an `Interrupt` or a verdict closed (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied`, `Stop`, …; a helper's too), but a prompt, a `SessionStart`, or a main-agent `PreToolUse` of a turn a verdict closed | unchanged (liveness only) |
| main-agent `PreToolUse` of a turn a verdict closed (not in `interruptedTurnIds`) | the turn opens again (its id leaves `closedTurnIds`), then as `PreToolUse` above |
| helper event (`agent_id` set) | refreshes the helper's last-seen time; `SubagentStop` removes it; a helper permission request blocks the turn (`waiting`), and the next helper event ends that wait; a helper active after `done` reopens it |
| `SessionEnd`, process exit | session removed |

Turns: every main-agent event that carries a turn id, a prompt included, records it as `lastMainTurnId`. An
`Interrupt` and `turnOver` close that turn (`closeTurn`: the id joins `closedTurnIds`, the last 8, and an
`Interrupt`'s id joins `interruptedTurnIds` too; `interruptedAt` records an `Interrupt`'s close). A main-agent
`UserPromptSubmit` opens its turn whatever id it carries: it removes that id from `closedTurnIds` and
`interruptedTurnIds` and clears `interruptedAt`. A main-agent `PreToolUse` of a turn `turnOver` closed opens it
the same way: a new tool call is never an aborted tool's straggler, and the registry can close a turn waiting on
a dialog whose hook lines were lost. A `Stop` and the lost-`Stop`
notification end the turn without closing it: a Stop hook that blocks the Stop keeps the same turn running.
Before the table applies, `changesNothing` sets aside, after refreshing `lastEventAt` and before
`lastMainEventAt`: every main-agent event of a closed turn but a `SessionStart`, a prompt, or a `PreToolUse`
of a turn not in `interruptedTurnIds` (`SessionEnd` removes the session before); every helper event of a closed turn; and, for 120 s after an `Interrupt`
(`abortQuarantineSeconds`), a main-agent tool or permission event with no turn id. A line without a turn id
otherwise meets the table as it is.

Verdict lines: each rescue that decides a session (`turnOver` from the registry, a rollout, the daemon or a
Copilot `events.jsonl`,
`dialogAnswered` from the registry) applies it live, then appends one `KoffeeLidVerdict` line through
`ActivityJournalWriter.append`, carrying `session_id`, `verdict` (`ActivityVerdict`: `turn-over`,
`dialog-answered`) and `logged_at`, nothing else. A rescued turn is ended at
`ActivitySessionStore.rescueStamp(endedAt:lastMainEventAt:now:)`, the source's own stamp (the registry's
`statusUpdatedAt`, the end marker's of a rollout or an `events.jsonl`; now for the daemon) clamped between the
last main-agent event and now,
and the line carries that stamp, so the replay gives the same `stateSince`. `apply` hands the line to
`applyVerdict`: a session it does not hold, a stamp before the session's `lastMainEventAt` or an unknown
verdict changes nothing; otherwise `turnOver` or `dialogAnswered` runs at the line's stamp. A verdict never
creates a session and never refreshes `lastEventAt`, and the tailer's redelivery of the app's own line meets
a session already decided and changes nothing. A reader that does not know the name skips the line
(`ActivityCodec.decodeLine` returns nil for an unknown event). The Health page's "last event seen" ignores it.

Time rules (`tick`): a helper counts as live for 240 s after its last event; a held `Stop` becomes `done` 90 s
after everything cleared, or 30 min after the last event; `done` becomes `idle` after 20 min; a session silent
for 2 h is removed. Registry rescues (`ActivityMonitor.checkRegistry`), for Claude Code sessions
(`abandonCandidates`, no quiet gate at launch), reading `<config>/sessions/<pid>.json` where `<config>` is the
session's `transcriptPath`'s config directory (`ClaudeRegistryRecord.configDir(fromTranscriptPath:)`), else
`~/.claude`: a `working` session quiet for 20 s with nothing out is checked every 15 s; registry
`idle` stamped after the last main event → `turnOver`; registry `busy` → `noteBusy` (and one warning after
5 min without a hook); a `waiting` session whose registry says `busy` stamped 2 s after the wait began →
`dialogAnswered`. Codex checks (`ActivityMonitor.checkCodex`), for Codex sessions (`codexCandidates`, the
same gate and cadence, no pid needed, and no gate at launch). A `hostedByManagedDaemon` session is asked about at the
daemon first while its socket exists (`CodexDaemonClient.readThread`, not at launch, one question out per
session): the answer arrives on main and applies only if the session is still `working` with the same
`lastMainEventAt` as when it was asked; an answer whose `thread.id` is not the thread asked about is nil
(`CodexThreadRecord.parse(_:expecting:)`); `CodexThreadRecord.verdict` maps `notLoaded` and `idle` to
`turnOver`, `active` to `noteBusy` (the same 5 min warning), anything else to the rollout, as is a nil answer;
after one of those two the daemon is not asked about that session again for 15 s, and the rollout decides
meanwhile. The rollout check (every other session, and those): the session's `transcriptPath` when it sits
under `~/.codex/sessions/<y>/<m>/<d>/` and names the session's own rollout (`CodexRolloutTail.isInSessions`,
`isRollout`), else the daemon's `path` under the same rule, else the newest `~/.codex/sessions/*/*/*/rollout-*-<session id>.jsonl` (`CodexRollout.locate`);
`CodexRollout.read` hands the last 64 KB of that regular file, and its modification date, to `CodexRolloutTail.verdict`, which reads only
the `event_msg` turn markers' type, stamp and turn id, and `CodexRolloutTail.decision` weighs it against the
session: `task_complete` or `turn_aborted` stamped after the last main event, or naming `lastMainTurnId` →
`turnOver`; `task_started` with no end, the file written less than 2 h before (`staleSeconds`) → `noteBusy`
(the same 5 min warning), written earlier → nothing, so staleness ends the session; an earlier turn's end, or
unreadable → nothing, unreadable logged once per session. A rollout read with no event since is read again 15 s
later at the earliest (`rolloutCheckedAt`), however often `sync()` runs. Copilot checks
(`ActivityMonitor.checkCopilot`), for Copilot sessions (`copilotCandidates`, the same gate and cadence, no pid
needed, and no gate at launch), read the session's `events.jsonl`: its `transcriptPath` when it is exactly
`<session-state>/<session id>/events.jsonl` (`CopilotTranscriptTail.isTranscript`, the root being
`CopilotTranscript.sessionStateDirectory`: `$COPILOT_HOME/session-state` from the app's own environment, else
`~/.copilot/session-state`), else that path built from the session id under the same rule.
`CopilotTranscript.read` hands the last 64 KB of that regular file, and its modification date, to
`CopilotTranscriptTail.verdict`, which reads only each line's type, stamp, `data.hookType` and the session id
inside `data.input`, and returns the last turn marker: `abort` (aborted), `session.error` (failed),
`session.shutdown` (ended), a `hook.start` of an `agentStop` whose input names this session (complete; a
subagent's names the subagent and is skipped), or a step of a turn (`user.message`, `assistant.turn_start`,
`assistant.message`, `tool.execution_start`, `tool.execution_complete`, `permission.requested`,
`permission.completed`: running). `CopilotTranscriptTail.decision` weighs it against the session: an end
stamped after the last main event → `turnOver` (reason `finished`, `aborted`, `failed` or `ended`; Copilot names
no turn, so the stamp alone decides); running, the file written less than 2 h before → `noteBusy`, written
earlier → nothing; an earlier end, or unreadable → nothing, unreadable logged once per session. A file read with
no event since is read again 15 s later at the earliest (`transcriptCheckedAt`). `nextDeadline` schedules all
three; an OpenCode session is not asked about when quiet (its hooks, its server's exit and staleness end it),
so it adds only its staleness deadline. `pruneDead` keeps a
`hostedBySharedCodex` session without asking about its pid; the kqueue on the host still drops them all when
it exits. For a Claude Code session with a live pid, `pruneDead` asks `registrySession` for the session the pid's
record names (read from the same directory as the rescues) and drops the session when it is another. Only `working` counts as running, and the snapshot counts every agent's sessions in one dictionary keyed by
`ActivityAgent` (`ActivitySnapshot.workingByAgent`, built from `ActivitySessionStore.workingCount(of:)` over
`ActivityAgent.allCases`); `kinds`, `badges` and `summary` read it per agent, so a new agent needs no new
stored property. `ActivityMonitor.lastEventByAgent` is the same shape for the last hook event of each agent;
`lastClaudeEvent` and `lastCodexEvent` are read-only conveniences over it for the Health page.

`ActivityJobStore`: one slot per job id (`zsh-<shell pid>`), counted once `armAfter` has elapsed, dropped on
`job end`, on the owner shell's exit (kqueue), when its shell answers that it runs nothing, or, for a job
without a shell pid only, after 2 h. `ActivityMonitor.probeJobs` runs at every `sync()` and once at replay,
after the prune: for each job with a shell pid, `ShellJobLiveness.probe` turns `ProcWalk.info` (process group,
the terminal's foreground group, `p_comm`, fork time) and `ProcWalk.childStartTimes` (only a child forked
after the job began counts) into a probe, and
`ActivityJobStore.probe` applies `ShellJobLiveness.judge` with the job's own `promptSeenAt`, logging `activity:
job <id> ended without a hook (<reason>)` for a drop. `nextDeadline` asks again `jobProbeSeconds` (15 s) later
while a job has a shell, and when a first sighting at the prompt has settled (`jobPromptSettleSeconds`, 5 s).

The snapshot also carries the badges of the work (`ActivityBadge`: a kind and the app that stands for it):
Claude Code's and Codex's are fixed bundle identifiers, as are `ActivityBadge.copilot` (GitHub Copilot.app,
`com.github.githubapp`) and `ActivityBadge.opencode` (OpenCode.app, `ai.opencode.desktop`), which sort after
them in `ActivityKind`'s order (Claude Code, Codex, Copilot, OpenCode, terminal); a command's is the app hosting its shell, read from
the shell pid's process chain (`ProcWalk.hostApplicationPath`) at every publish, Terminal when none.
`AutoArmBadges` in the coordinator shows the running ones, keeps the last running set through the hold-off
and clears them when the level drops
(`currentAutoBadges`, refreshed with the status item and read again when the menu is built); `ActivityIcons`
turns each app into its icon once and keeps it.

`ActivityArmPolicy` is a level. `update(running:enabled:now:)` turns it on with the first running kind and
accumulates the kinds seen (`involved`); when nothing runs, `offAt = idleSince + currentHoldOff` (the longest
`holdOffs[kind]` over `involved`, or 60 s while `disarmOnce` is pending). `tick` returns
`.off(releaseManual:)` when it passes; `userActive` drops it at once during a countdown; `suspend()` and
`armFailed()` zero it and suppress it until the running set empties. The coordinator schedules one timer at
`nextDeadline` and a 2 s local-input poll while a countdown runs.

`HookInstaller` is stateless and has no link to the coordinator; the CLI verbs
`install-hooks [claude|codex|copilot|opencode]`, `uninstall-hooks [claude|codex|copilot|opencode]` and
`shell-init zsh` run it in-process without contacting the app.
`HookConfig` is one spec per agent whose hooks live in a `hooks` object (`HookConfig.claude`,
`HookConfig.codex`: the events, the marker that recognises our entries whatever bundle path they were
installed from, the matcher, the timeouts; `HookConfig.of` answers nil for Copilot and OpenCode) and
transforms the `hooks` object of `~/.claude/settings.json` or `~/.codex/hooks.json` (entries recognised by
the suffix `/Contents/MacOS/KoffeeLidHook hook`, or `… hook codex`, other tools' entries untouched, ours
appended after them so their indices stand). `HookSettingsFile` loads either JSON file strictly and backs it
up to `<file>.backup-koffeelid` before writing. `CodexHookTrust` is what Codex wants on top: per hook the
key `<hooks.json path>:<event label>:<group index>:<handler index>` and the hash Codex computes from the
entry's identity (SHA-256, `SHA256.swift`, of its canonical JSON), written as `[hooks.state."<key>"]` tables
with a `trusted_hash` at the end of `~/.codex/config.toml` (backed up to `config.toml.backup-koffeelid`),
the one shape Codex itself writes; it reads that shape back for the row's state, recognises a stale table of
ours by its hash, and refuses to write beside a state kept in another TOML form. `ShellInit` builds the
snippet and edits `~/.zshrc` (it removes only what sits between its two header lines, its marker comment,
and uncommented `shell-init zsh` lines that name KoffeeLid).

Copilot's and OpenCode's files hold no `hooks` object of `HookConfig`'s shape, so each gets its own pure Core
type and a whole-file write instead of a merge — no backup, since there is nothing of a stranger's to lose,
only a refusal (unchanged) when a file already at that path does not look like one of ours. `CopilotHookFile`
builds `~/.copilot/hooks/koffeelid.json` from `ActivityEventName.copilotHookEvents`: one `command` entry per
event, `exec` the hook binary's absolute path, `args` `["hook","copilot",<event>]`; `isOurs` recognises an
entry by that shape whatever bundle path it names, `installedCount` counts only entries that name THIS
bundle's path, and `disabled` reads `disableAllHooks` from `~/.copilot/settings.json` and
`~/.copilot/config.json` (whole-line `//` comments stripped first). `OpencodePlugin.source(hookPath:)` renders
the whole plugin file for that path: the v2 shape (`export default { id, setup(ctx) }` over
`ctx.event.subscribe()` — a v1-style plugin fails to load) forwarding OpenCode's own session lifecycle events,
with `location.shutdown` dropped and every `directory` field removed so no path leaves OpenCode; a subagent's
events attach to the top-level session by walking the plugin's own `state.parents` map to its root, capped at
16 hops against a cycle; `isOurs` looks for the hook binary's marker and the plugin's id, `isCurrent` compares
byte for byte.
`HookInstaller.installCopilot`/`installOpencode` write these whole files to `~/.copilot/hooks/koffeelid.json`
and `~/.config/opencode/plugins/koffeelid.js` (creating the `hooks/`/`plugins/` directory); `uninstallCopilot`/
`uninstallOpencode` refuse the same way install does, reporting a file that cannot even be parsed as a failure
rather than skipping it, and remove that same `hooks/`/`plugins/` directory afterward, but only once it is
empty (`removeIfEmpty`): never a folder with anything else left in it, and never `~/.copilot` or
`~/.config/opencode` itself. `copilotInstalledCount` and `opencodeInstalled` (each with an off-main variant told
its paths, for the Health page and the menu's "Disarm once finished" gate) read them back byte-exact to this
bundle's own path; `copilotHooksPresent`/`opencodePluginPresent` (plain existence) are what Reset and Uninstall
gate their removal on instead, so a file from an older or another copy of KoffeeLid — ours, but not
byte-identical — is still taken off rather than silently left behind.

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
`~/.codex/hooks.json` and `~/.codex/config.toml` (each + `.backup-koffeelid`),
`~/.copilot/hooks/koffeelid.json`, `~/.config/opencode/plugins/koffeelid.js`, `~/.zshrc`,
`/usr/local/bin/koffeelid` (a zsh `exec` wrapper written by `script/install.sh`; a symlink would break
`Bundle.main`).

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
  sources fire on main. `CodexDaemonClient` does its socket I/O on a global utility queue, non-blocking with
  `poll`, 1 s per call from the moment it is asked, and completes on the main actor.
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
