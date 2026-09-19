# Audit — 2026-09-18

Working file of the full-codebase audit. Source of truth: the compiling code. Worker reports (one per slice
and per stitched path) were written outside the repository; their conclusions are consolidated here.
`docs/_coverage.md` records who read what.

## Map

| Area | Files | Verdict |
|---|---|---|
| Entry points, coordinator, CLI, intents | `App/Sources/main.swift`, `AppDelegate.swift`, `KoffeeLidController.swift`, `CommandServer.swift`, `Intents/KoffeeLidIntents.swift` | LIVE; two dead members, stale comments |
| Power, sleep, lid, lock, brightness | `PowerManager`, `SleepLock`, `SleepInterruptionMonitor`, `BatteryMonitor`, `ThermalMonitor`, `InternalDisplayBrightnessController`, `DisplayTopologyMonitor`, `LidObserver`, `LidReopenLockController`, `ScreenLockObserver`, `RelaunchAgentController`; Core `SleepInterruptionPolicy` (+ `SleepOverrideGuard`, `SleepLockSetup`), `ArmingPolicy`, `LowBatteryPolicy`, `LidReopenLockRetryPolicy`, `LidStateTransitionFilter`, `ReopenLockDecision`, `CrashLoopGuard`, `PidFileRecord` (+ `AppSupport`), `RelaunchHistoryStore`, `DiagnosticFileWriter`, `DiagnosticLine` | LIVE; one dead member, one log line that can never print |
| Lid motion and gesture | `LidAngleSensor`, `LidAngleObserver`, `GestureController`, `LidCloseSoundPlayer`, `OutputVolumeOverride`; Core `LidProgressDriver`, `OptionGateFilter`, `AngleSampleFilter`, `AngleSmoother`, `FoldTracker`, `FoldGeometry`, `ReopenCancelWatch`, `GestureArmHold`, `EffectParameters`, `VolumeOverridePolicy` | LIVE; one dead member; **the animation-reset bug** |
| Lid effect | `Sources/LidPlaneKit/*` | LIVE; one dead getter; `PlaneRemap` is tests-only by design |
| Activity / Claude hook | `ActivityMonitor`, `ActivityJournalTailer`, `ActivityProcessWatcher`, `ClaudeProcessRegistry`, `LocalInputMonitor`, `HookInstaller`, `Hook/Sources/main.swift`; Core `Activity*`, `ClaudeRegistryRecord`, `HookConfig`, `HookSettingsFile`, `ShellInit`, `ProcWalk` | LIVE; no second detection mechanism |
| UI, preferences, status item | `Preferences`, `StatusItemController`, `HotKeyController`, `MugShape`, `NotificationsController`, `DiagnosticLog`, `UI/*`; Core `ArmMode`, `DeepLink`, `KoffeeLidCore` | LIVE; two dead preferences, one test-only property, one unused string |
| Watchdog | `Watchdog/Sources/main.swift`, `App/LaunchAgents/*.plist` | LIVE |
| Tests | 27 files in `Tests/KoffeeLidCoreTests`, 2 in `Tests/LidPlaneKitTests` | LIVE; no duplicate, commented-out or assertion-free test; dated narrative in three comments |
| Build, scripts, resources | `project.yml`, `Package.swift`, `script/*`, string catalog, glyphs, licence | LIVE; one vestigial build setting |
| Docs | `README.md`, `CLAUDE.md`, `docs/*.md`, `docs/superpowers/*` | stale in places, history-heavy; rewritten |

No orphan files either way between disk and the project definitions. No `TODO`/`FIXME`. One keep-awake
engine, one activity detector, no abandoned prototype in the tree.

## Behaviour, from code

Recorded in `docs/functional.md` (product), `docs/architecture.md` (ownership and state) and `docs/macOS.md`
(mechanisms). The quality-bar questions and where each is answered:

| Question | Answer |
|---|---|
| What keeps the Mac awake | `IOPMrootDomain` selector 12 + `PreventUserIdleSystemSleep` + `PreventSystemSleep` + `sudo -n pmset disablesleep 1` when the sudoers rule exists; screen on adds `PreventUserIdleDisplaySleep` + a 30 s `IOPMAssertionDeclareUserActivity`. `architecture.md` § Who watches what, `macOS.md` |
| Lid close/open, AC, display, sleep key, idle, clamshell with a display | `functional.md` § Lid closed, External display, Power and safety rails |
| Armed / disarmed / auto-armed and who flips it | `architecture.md` § The coordinator |
| The Claude hook, what "working" means, when it disarms | `functional.md` § Auto-arm on activity, `architecture.md` § Auto-arm on activity |
| What is requested from the user and what breaks if denied | `functional.md` § Permissions |
| Persistence | `architecture.md` § Persistence, `functional.md` § Settings and defaults |
| UI controls and the code they toggle | `functional.md` § User interface, Settings |
| Safety limits | `functional.md` § Power and safety rails. No maximum arm duration exists |
| Lid effect trigger, reset, who cancels it, what screen-on changes | below, and `architecture.md` § The lid effect |

## Animation-reset bug

**Symptom.** The lid effect stays folded after the lid stops moving; mostly seen in Armed + screen on.

**What starts the effect.** `EffectController.start()` prepares it (`KoffeeLidController.swift:351, 442, 465,
498, 549, 762`). The visible fold begins in `EffectController.feed` when `FoldTracker.update` returns
`.foldBegan` (`EffectController.swift:171-174`), or through `followLidFromHere()` when the gesture fires on an
existing arm (`KoffeeLidController.swift:515`, `EffectController.swift:194-208`).

**What resets it.** No timer. `FoldTracker.update(angle:now:holding:)`, run on every 30 Hz sample
(`LidAngleObserver.swift:72-75` delivers whether or not the value changed; `KoffeeLidController.swift:502`):
once `now − lastMovement ≥ settleDelay` with the lid below the zero angle, the rest angle eases down over
0.6 s, the fold reaches 0, `.foldEnded` fires and `endSession` stops the capture 0.75 s later
(`FoldTracker.swift:55-65`, `EffectController.swift:175-176, 271-291`).

**What starves it.** `FoldTracker.swift:50-52`: `if holding || movement ≥ 1.5° { lastMovement = now }`. While
`holding` is true the settle branch is never reached. `ReopenCancelWatch.swift:19` applies the same rule to
the one-close stall cancel. `holding` is the raw modifier read, on every sample, for every arm source:
`KoffeeLidController.swift:483` `let held = prefs.armWithOption && gesture.readModifier()`. It does not go
through `OptionGateFilter`, whose 20 s limit only protects the arming decision.

**Why `holding` is true with nobody holding Fn.** `GestureController.readModifier()` tests
`CGEventFlags.maskSecondaryFn` and `NSEvent.ModifierFlags.function`. macOS sets that flag on arrow-key events
too. Observed on this Mac with a passive probe next to the installed app:

```
probe    2026-09-18T12:48:33.390Z combined=0xa00100 hid=0xa00100  fn flag 1, numeric-pad flag 1,
         CGEventSource.keyState(63 /* kVK_Function */) = 0, NSEvent .function = 1, 0.02 s after a key-down
app log  [2026-09-18T12:48:33.423Z] gesture: started @123deg (fn via hardware)
         [2026-09-18T12:48:34.759Z] gesture: cancelled (optionLost)
```

`0xa00000` = secondary-Fn + numeric-pad = an arrow key, physical Fn up; the app took it for the gesture
modifier. The arrow key was released about 0.2 s before the next keyboard event, and the flags still read
`0xa00100` until that event: the reading latches after key-up. A real Fn press captured by the same probe
(13:07:25Z and 13:07:29Z) reads `0x800100`, no numeric-pad flag, key state of 63 = 1, and clears on release,
so the fix keeps real Fn holds intact. The installed app's log holds 485 `gesture: started … (fn via hardware)` → `cancelled (optionLost)`
episodes over three days of ordinary work, 12 of them pinned at the 20 s gate limit, and one fold that stayed
up 28 s (2026-09-17T06:33:15Z, manual caffeinate arm, `modifier + close while armed` 17 s into such a
stretch).

**Sequence.** Arrow key held (or its flag the last thing the session saw) → `held` true → a lid adjustment of
`gestureActivationDegrees` fires the detector (`LidProgressDriver.swift:78-79`): idle → a one-close arm; armed
from another source → `followLidFromHere()`, an ungated fold at the working angle → the plane cannot settle and
a one-close arm cannot stall-cancel while the flag reads set.

**Why screen-on correlates.** Nothing on the effect path reads `ArmMode` (`EffectController`, `FoldTracker`,
`FoldGeometry`, `AngleSmoother` have no such input). Armed + screen on is the mode that stands for hours with
the lid open, which is when `gestureWanted` keeps the detector listening during a standing arm
(`KoffeeLidController.swift:778-780`), and its display assertion keeps a stuck plane on screen. The 30 s
user-activity declaration is an assertion, not a HID event; it does not touch modifier flags.

**Refuted suspects.** Sensor flicker restarting the clock (1.5° band, converges to 0); the 0.75 s session timer
returning without rescheduling (the next `.foldEnded` reschedules); a reset gated on a display-sleep, lock or
lid notification (none on this path); consumers removed while a fold shows (only `stop()` removes `"effect"`,
and it tears the panel down).

**Open, unproven.** A sensor read that starts failing stops sample delivery (`LidAngleObserver.swift:62-66`)
and would freeze a fold; no `lid-angle sensor reads failing` line exists in the logs. The three effect timers
run in the default run-loop mode and wait while a menu is tracking; they do not keep a plane visible. Function
keys pressed as F1–F12 and navigation keys on an external keyboard also carry the Fn flag without the
numeric-pad flag.

**Fix.** `FnKeyReading.isFnDown(secondaryFn:numericPad:)` (Core, tested) and `GestureController.readModifier()`
using it: a reading with the numeric-pad flag is not Fn. No timing, threshold or effect change; a physical Fn
hold still suspends the reset, as designed.

## Deletions (all confirmed with a repo-wide search, all applied)

| Item | Where | Why |
|---|---|---|
| `onStateChange` and its call | `KoffeeLidController.swift:15,20` | never assigned |
| `sleepLockEngaged` | `KoffeeLidController.swift:667` | never read |
| `isSampling` | `LidAngleObserver.swift:31` | never read |
| `isFollowingLid` | `EffectController.swift:51` | never read |
| `isAvailable` | `InternalDisplayBrightnessController.swift:12` | never read |
| `playCloseAnimation`, `suppressDisplayPausePopup` | `Preferences.swift:16,18,57,62` | registered and declared, no reader, no control |
| `ArmMode.isArmed` | `ArmMode.swift:8` + 3 assertions in `ArmModeTests` | production uses `KoffeeLidController.isArmed` |
| baseline log in `LidObserver.init` | `LidObserver.swift:14` | `onLog` cannot be set before `init` returns |
| `"Sensor"` | `Localizable.xcstrings` | no literal uses it |
| `SWIFT_OBJC_BRIDGING_HEADER: ""` | `project.yml:87` | no bridging header exists |
| `// Part 3b`, dated narrative, references to removed docs | comments in 14 source and test files | history, not invariants |
| `docs/superpowers/` (plan 2,540 lines, spec 267) | | design written before the code, partly superseded; the state table, the rationale and the traps move to the main docs |
| `docs/platform-notes.md`, `docs/gesture.md` | | replaced by `docs/macOS.md`, `docs/architecture.md`, `docs/pitfalls.md` |

Kept on purpose: `PlaneRemap` (tested reference for the runtime-compiled shader), `AngleSmoother.estimate(at:)`
(test seam), `ShellInit.zshrcMarker` (removes blocks written by earlier installs from the user's `~/.zshrc`),
the `EffectParameters` decoding fallback, `NSAppleEventsUsageDescription` (cannot be proven unused by the
in-process `NSAppleScript` privileged call), the `hotKey*` preference keys (read by `HotKeyController`).

## Disparities between docs and code

None large enough to question the product. All were stale docs:

- `docs/architecture.md` said `isArmed ⇔ mode != .off` and drew a one-close arm ending on lid open; the code
  ORs the auto level and holds the arm until login.
- `docs/architecture.md` said the modifier is watched through a global flags monitor; it is read per sample.
- `docs/development.md` said there is no `gh` CLI; `CLAUDE.md` said releases are made with it.
- `docs/manual-checks.md` numbered the onboarding's last page 3 (it is 4) and kept a check for a master switch
  that does not exist.
- The activity spec described an edge-triggered arm policy owning the manual mode; the code has an independent
  level ORed with it.

## Inconsistencies found and left as they are

Behaviour-preserving mission; none of these is a defect the user reported. Recorded for the next pass.

- `shutdown()` sets `state = .idle` before the flag clear loop; `disarm()` does it after (`KoffeeLidController.swift:195` vs `:393`). Both attempt the clear.
- A failed sleep-lock release is logged and notified but not retried, unlike a failed flag clear (`:673-680` vs `:375-386`).
- After a rail, the auto level stays suppressed until the running work stops and new work starts, not until the rail condition clears (`ActivityArmPolicy.swift:82-86`). Documented behaviour.
- When `SleepOverrideGuard` gives up the dark-wake hold, the user sees the "another app put your Mac to sleep" text (`:590-593`).
- An external display connecting while a one-close arm is already closed locks but does not release the arm; only the not-yet-closed case releases it (`:541`).
- A reopen inside `ReopenLockDecision`'s 2 s window can call `requestLock()` twice (`:445`, `:554`); the second call restarts the same chain.
- The activity journal keeps one rotated generation.

## Questions for the owner

1. Is `NSAppleEventsUsageDescription` ("Not used.") wanted? Nothing sends Apple events to another app.
2. Function keys used as F1–F12 and an external keyboard's navigation keys still read as "Fn held" (Fn flag
   without the numeric-pad flag). `CGEventSource.keyState(…, 63)` read 1 for a real Fn press and 0 for an arrow
   key on this Mac; requiring it as well would close that gap, at the cost of depending on one more reading
   that has not been checked with an external keyboard. Wanted?

## 2026-09-19 pass

Same mission, run again one day later on `f3b447c` as an independent verification of the pass above: every
in-scope file re-read by a fresh reader (`docs/_coverage.md` § 2026-09-19 verification pass), the docs treated as
untrusted and checked claim by claim against the code by two Sonnet workers, the quality-bar questions answered
from code only by a third worker that was forbidden to open any doc, and a fourth worker reading the UI, the
renderer, the tests, the scripts and the resources for residue. The map, the behaviour and the verdicts above
stand; the code-only answers to the quality-bar questions agree with `docs/functional.md`, `docs/architecture.md`
and `docs/macOS.md` on every mechanism, timing and default.

### Deletions (proven with a repo-wide grep, applied)

| Item | Where | Why |
|---|---|---|
| `SleepLockSetup.installCommand(user:)` and `testInstallCommandValidatesBeforeTheRuleIsLive` | `SleepInterruptionPolicy.swift:66-72`, `SmallPoliciesTests.swift:93-98` | a production function whose only caller was its test; `script/install.sh` prints its own literal one-liner, so the test protected nothing |
| `otherStart` slider handle and `_ = otherStart` | `AdvancedViewController.swift:33,44` | never used; `labelledSlider` is `@discardableResult`. The push between the two "Start below" sliders runs through the gesture slider's handle only |

Kept on purpose, in addition to the list above: `PlaneRemap.blurRadius` (test-only by design, mirrors
`PlaneShader` line `radius = u.blurStrength * gap * 65.0`); `MTKViewDelegate.mtkView(_:drawableSizeWillChange:)`
(protocol requirement).

### Doc corrections

| Doc | Was | Now |
|---|---|---|
| `functional.md` § The lid effect, End | an external display "stops it at once" | connecting one retracts the plane over 0.3 s like a cancelled one-close arm (`handleDisplays` → `effect.stop(retracting: true)`) |
| `functional.md` § What KoffeeLid does not do | "never signals processes by name" | never signals its own by name; Advanced › Reset runs `killall usernoted` and `killall NotificationCenter` |
| `functional.md` § What KoffeeLid does not do | the hook binary "always exits 0" | always 0 from the `hook` verb; a malformed `job` line exits 2 |
| `functional.md` § Auto-arm, Without an end event | registry rescue only | adds the `idle_prompt` / `agent_needs_input` lost-`Stop` rule (50 s of main-agent quiet) |
| `macOS.md` § Permissions and how each is reset | `killall usernoted` | both daemons |
| `macOS.md`, `development.md` | macOS 26, Xcode 26, Swift 6.3 | macOS 27, Xcode 27, Swift 6.4 (`sw_vers`, `xcodebuild -version`, `swift --version`) |
| `architecture.md` § Entry points | `perform` "maps a verb onto `setMode`" | arming verbs only; `status` no-op, `settings` opens the window; returns `did not arm: …` when refused |
| `architecture.md` § Entry points, `shutdown()` | | also stops the screen-lock observer |
| `architecture.md` § Auto-arm, helper row | | a helper event ends a wait that a helper's permission request opened |
| `architecture.md` § Privilege boundary | "`pgrep`/`pkill` patterns" | the one `pkill` (`install.sh`) and the two `killall`s by name |
| `pitfalls.md` § The lock can silently fail | "retries until locked" | five retries, 0.5 to 8 s apart |
| `pitfalls.md` § A hook payload is untrusted input | "every field … at 4 KB" | identifiers 200 chars, labels 60, raw prefix 300, line 4 KB |
| `pitfalls.md` § Working on this Mac | | the `appintentsmetadataprocessor` warning: the Debug build that printed it wrote no `Metadata.appintents`; the next build, which relinked the app, wrote it; the installed Release build has it |
| `development.md` § A user-visible string | `rg` one-liner | `grep -rhoE` (rg is not installed here) |
| `development.md` § A settings control | "as the two Start below sliders do" | only the gesture slider keeps its handle |
| `development.md` § Daily loop, `CLAUDE.md`, `manual-checks.md` Shortcuts check | | the same Debug-build note |
| `README.md` badge, `CLAUDE.md` | 248 tests | 247 |

### Left as they are (recorded, not defects)

- The inconsistencies listed in the 2026-09-18 pass, unchanged.
- A Debug build that prints the `appintentsmetadataprocessor` warning registers no App Intents metadata until
  it is rebuilt (above). The installed Release build is unaffected.

### Owner decisions, same day

1. `NSAppleEventsUsageDescription` ("Not used.") removed from `App/Info.plist`: nothing sends Apple events to
   another app, and the administrator dialog (`do shell script … with administrator privileges`) runs in
   process.
2. The Fn read now also requires virtual key 63 to be physically down
   (`FnKeyReading.isFnDown(secondaryFn:numericPad:keyDown:)`, fed by
   `CGEventSource.keyState(.combinedSessionState, key: kVK_Function)`; test first, `FnKeyReadingTests`). Function
   keys used as F1–F12 and an external keyboard's navigation keys no longer read as Fn.
3. Nothing installed or released.
4. Only the built-in keyboard's Fn key arms: `BuiltInFnKeyReader` (new App file) opens the `Built-In` keyboard
   through `IOHIDManager` under the Input Monitoring grant and reads its Fn element (page `0xFF`, usage 3;
   `ioreg` shows the external Magic Keyboard carries the same element); `FnKeyReading` gained an optional
   `builtInKeyDown` (test first, four cases); a fifth `PermissionCatalog` row, `tccutil reset ListenEvent` in the
   reset, two strings with `fr`. Without the grant the previous rule stands. Two probes on this Mac (scratchpad,
   not in the tree): a matching dictionary carrying `Built-In: true` matched both keyboards, so the filter moved
   to user space; the reader's open → element subscription → schedule → close sequence on the built-in device
   succeeds under the grant. Key presses themselves are not yet exercised (`docs/manual-checks.md` § Gesture).

### Questions for the owner

- Resolved above. Remaining unconfirmed: whether the Input Monitoring grant applies without a relaunch.

- (Superseded) The owner wants only the built-in keyboard's Fn key to arm. `CGEventSource.keyState` is session-wide: an
  external Apple keyboard's Fn/Globe key, if it presses key 63, still counts. Telling keyboards apart needs
  per-device HID input (an `IOHIDManager` on the internal keyboard), which macOS gates behind the Input
  Monitoring grant: a new permission row, a new denied-state fallback. Decision pending.
