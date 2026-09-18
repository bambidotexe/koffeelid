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
