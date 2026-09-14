# The Fn + close gesture: states, combinations, and the 2026-09-11 softlock

Read this before touching `GestureController`, `LidProgressDriver`, `OptionGateFilter`, `ReopenCancelWatch`,
`KoffeeLidController.handleGesture/handleAngle/refreshGestureSampling` or `EffectController.followLidFromHere`.
The gesture is the only arming path with hidden state; every other source is a single call into `setMode`.

## Pipeline

```
LidAngleSensor (HID feature report; the value changes every ~100 ms)
  → LidAngleObserver (polls 30 Hz at rest, 120 Hz while moving; delivers 30 Hz on main with the change time)
    → KoffeeLidController.handleAngle
        ├─ if gestureWanted → GestureController.feed(angle)
        │     readModifier()  fresh CGEventSource.flagsState + NSEvent.modifierFlags, nothing cached
        │     OptionGateFilter  trusted after 2 down samples, distrusted after 3 up, hold limit 20 s
        │     LidProgressDriver idle → .started → .progress… → .armed (activated) ; .cancelled(optionLost|reversed|timeout)
        │        → handleGesture(event)
        ├─ if state == .armedWaitingClose → ReopenCancelWatch (one-close arms only) → disarm("reopened"/"stalled")
        └─ → EffectController.feed (the plane)
```

## When the detector listens

`gestureWanted = prefs.armWithOption && !externalDisplay && (!isArmed || (state == .armedWaitingClose && armSource != .gesture))`

`refreshGestureSampling()` re-evaluates it on: launch, `arm`, `disarm`, lid close, lid open, display change,
gesture-preference change, reset, and the in-place Armed ↔ Armed + screen on switch in `setMode` (the one
trigger that changes `armSource` without arming or disarming). It adds/removes the `"gesture"` consumer on the sampler and **resets the
detector on every change of that boolean**, so no half gesture or held arm carries across states.

## What Fn + close does in every state

| Mode / state | Arm source | Lid | External display | Fn + close |
|---|---|---|---|---|
| Off / idle | — | open | no | `gesture: started @…` → after `gestureActivationDegrees` `gesture: armed via tilt` → `arm(source: .gesture)`, one close only. Plane from the gesture's start angle, 95° by default (`FoldGeometry`). |
| Off / idle | — | open | yes | Detector off; no `gesture:` lines. Menu/shortcut/CLI arms still work (standing by). |
| Off / idle | — | closed | — | Nothing: the driver ignores angles ≤ 5° (`angleClosed`). |
| Armed or Armed + screen on / waiting close | menu, rightClick, shortcut, intent, url, cli | open | no | `gesture: modifier + close while armed (source) @…; effect follows the lid (plane from 90°)` (the gesture's start angle): gate dropped, fold zero at the current angle (catch-up if below it). **Mode unchanged; not a second arm.** If the start-below gate already started the fold: `…; effect already folding; fold kept`. Effect off/no Screen Recording: `…; effect not running …; nothing to show`. The driver stays silent until Fn is released, then listens again. |
| same | same | open | yes | Detector off; effect stands by. |
| Armed / waiting close | gesture | open | no | Detector off: the effect already follows the lid from the gesture arm. Reopening by `gestureReverseCancelDegrees`, or standing still for `effect.settleDelay` before the lid shuts **while Fn is not held**, disarms (`ReopenCancelWatch`). Fn held = no stall cancel, no return to flat. Caveat: an in-place mode switch rewrites `armSource` to the new source, so from then on the detector listens again and the one-close cancels end with the gesture arm (`reopenWatch = nil`). |
| Armed / closed | any | closed | — | Detector off (no samples wanted). On reopen: non-gesture arms `gesture.reset()` and listen again (`lid opened; arm stands`); gesture arms are **held** until the user logs back in (`GestureArmHold`, below) — unless the gesture arm was upgraded in place to another mode, which makes it that source's arm: it stands. |
| Armed, any | any | open | — | Low battery, thermal, external sleep → `disarm` → detector reset → listening again if wanted. |

Every arm that the detector produces calls `arm()`, which resets it. Every disarm resets it. Every
listening transition resets it. The driver also resets **itself** once the modifier is released after
`.armed`. Those four are the invariants; the softlock below existed because only the first one did.

## Post-mortem: Fn dead after "gesture while armed" (2026-09-11)

**Symptom.** Fn + close does nothing: no `gesture:` line at all, no arm. It came back after arming with
the shortcut or the menu once, which made it look tied to "arming/disarming with the keyboard shortcut".

**Evidence** (`diagnostics.log`, UTC):

```
15:44:00.109 gesture: started @130deg (fn via hardware)
15:44:00.259 gesture: modifier + close while armed (shortcut) @124deg; effect follows the lid
15:44:07.162 effect: gesture fold ended; waiting below 75° again
15:44:17.817 disarmed (menu)
             … 7 minutes of use, not one `gesture:` line …
15:51:44.363 armed (shortcut, caffeinate)          ← arm() → gesture.reset(): Fn works again
```

Same shape at 15:29:01 → 15:32:22 (healed by the relaunch that followed).

**Root cause.** `LidProgressDriver` sets `activated = true` when it emits `.armed` and, until this fix,
returned `nil` forever after that until someone called `reset()`. The idle path was fine: `arm()` resets.
The "already armed" path (`handleGesture(.armed)` with `isArmed`) only called `effect.followLidFromHere()`,
and `disarm()` never reset either. So: arm from shortcut/menu/CLI → Fn + close as feedback → `activated`
latched → disarm → idle with a dead detector, until the next `arm()` from any other source.

**Fixes.**
1. `LidProgressDriver.feed`: while `activated`, `!optionTrusted` → `reset()`. One hold = one arm; the next
   hold works. Tests `testArmedStaysSilentWhileHeldAndResetsWhenTheModifierIsReleased`,
   `testSoftlockReplay_gestureWhileArmedThenDisarmWithoutReset`.
2. `KoffeeLidController.disarm()` resets the detector; `refreshGestureSampling()` resets it on every
   change of `gestureWanted`; `arm()` sets `armSource` before refreshing so `gestureWanted` reads the
   right source.
3. `GestureController` lost its cached global `flagsChanged` monitor (second hazard, below).
4. `EffectController.followLidFromHere()` keeps a fold that the start-below gate already started
   (rebasing snapped the plane flat under the hand) and reports what it did (`FollowResult`) for the log.
5. `LidAngleObserver`: the 120 Hz/30 Hz reschedule reads the timer from the handler's own capture, not the
   main-thread property (race introduced earlier the same day).

**Second hazard, fixed pre-emptively (not seen in the logs).** The old `NSEvent.addGlobalMonitorForEvents(.flagsChanged)`
cached `isModifierDown`. Global monitors never receive the active application's own events, so Fn pressed
elsewhere and released while KoffeeLid's Settings window was active left the flag stuck down: every close
would arm, and after `OptionGateFilter`'s 20 s hold limit `expired` could never clear (it clears only on a
"key up" sample) — a second way to a dead detector. The modifier is now read fresh every sample
(`gesture: started @… (fn via hardware|events)`), nothing cached.

**Holding the modifier pauses the stillness rules (added the same evening).** A gesture arm is cancelled when
the lid stands still for `effect.settleDelay` before it shuts (`gesture: lid still for …s after arming without
closing; cancelling`), the same value as Advanced › "Return to flat when still for" (0.5 s by default), and
the plane eases back to flat on the same clock. Both now ignore stillness while Fn (or Option) is down:
`KoffeeLidController.handleAngle` reads the modifier once per sample (`gesture.readModifier()`) and passes it
as `held:` to `ReopenCancelWatch.update` and `holding:` to `EffectController.feed` → `FoldTracker.update`.
Release restarts the stall clock from that moment; a settle already in progress stops where it is when the
key goes down again. Holding Fn with the lid half closed therefore keeps the arm and the fold indefinitely.

## Log lines to grep

```
gesture: started @NNdeg (fn via hardware|events)          detector saw the modifier and a lid above 5°
gesture: armed via tilt @NNdeg (start NNdeg, closed Ndeg)  idle → arm(source: .gesture)
gesture: modifier + close while armed (SRC) @NNdeg; …      feedback while armed; the suffix says what the effect did
gesture: cancelled (optionLost|reversed|timeout)           released > 1 s before travel, lid reopened ≥ 4°, stalled > 1.5 s
gesture: lid reopened by Ndeg after arming … cancelling    ReopenCancelWatch → disarmed (reopened)
gesture: lid still for Ns after arming … cancelling        ReopenCancelWatch → disarmed (stalled)
effect: following the lid from NN°                         followLidFromHere rebased the fold zero
effect: gesture while already folding; keeping the fold    followLidFromHere on a running fold
effect: gesture fold ended; waiting below NN° again        the gesture fold is over; the start-below gate is back
one-close session held on lid open; waiting …             the lid opened on a one-close arm; it is not over
one-close arm held; it ends when you log back in           the reopen lock landed; the hold is real
one-close session ended on unlock                          the user logged back in; the arm is over
one-close session ended on lid open; the screen never …    no lock ever landed; fell back to the old behaviour
```

A dead detector shows as *no* `gesture: started` line while Fn is held and the lid moves above 5°. First
check `koffeelid status` (external display → detector off by design), then that `Fn (Globe) + close` is on in
Settings, then this file.

## Merge notes (for the branch being merged after 2026-09-11)

Files: `Sources/KoffeeLidCore/LidProgressDriver.swift`, `App/Sources/GestureController.swift` (rewritten, no
monitor, `readModifier()`, `modifierSource`), `App/Sources/KoffeeLidController.swift` (`arm`, `disarm`,
`handleGesture`, `refreshGestureSampling`, `shutdown`, `preferenceChanged`), `Sources/LidPlaneKit/EffectController.swift`
(`followLidFromHere() -> FollowResult`, `isFollowingLid`, `isFolding`), `App/Sources/LidAngleObserver.swift`,
`Tests/KoffeeLidCoreTests/LidProgressDriverTests.swift`. If a conflict makes you choose, keep: the
`activated → reset on release` branch in the driver; `gesture.reset()` in `disarm()`; the transition reset in
`refreshGestureSampling()`; `armSource = source` before `refreshGestureSampling()` in `arm()`; no
`startMonitoringModifier/stopMonitoringModifier` anywhere; `followLidFromHere` not rebasing a running fold.

Merged 2026-09-11, every keep item honoured; the branch's only gesture-path change is `setMode`'s in-place
branch (`armSource`, `reopenWatch = nil`, `refreshGestureSampling()`). Re-listening mid-hold can log a second
`gesture: started` in the same physical close — harmless, the `.keptCurrentFold` branch protects the plane.

## The one-close hold (`GestureArmHold`, 2026-09-14)

A one-close arm used to end the moment the lid opened. That left a hole: anyone who lifted the lid and
shut it again stopped the Mac dead, because the second close met a disarmed app and the Mac slept. The
arm now survives the lid opening and ends when the user **logs back in**; the lid can be opened and
closed any number of times in between and the Mac stays awake.

The hold is keyed off the reopen lock the app already requests, so there is no new timer:

| Event | Phase | What the coordinator does |
|---|---|---|
| Lid opens on a gesture arm | off → awaitingLock | `.keepArmed` — no release; the lock is requested as always |
| Screen locks (edge, or a live read when the lid reopens already locked) | awaitingLock → holding | `.held` — the hold is real |
| Screen unlocks | holding → off | `.release(.unlocked)` → `releaseManual(reason: "unlock")` |
| `lock.onGaveUp` (no login password, or the lock failed) | awaitingLock → off | `.release(.neverLocked)` — the old "ends on lid open" behaviour, because holding an arm over a visible desktop is worse than sleeping |
| `disarm`, a fresh arm, an in-place mode switch, `releaseManual` | any → off | `clear()` |

While held, the closes the arm still covers **play the lid sound but run no effect**
(`!gestureHold.isHolding` gates `effect.start()` at lid open): the arm belongs to someone who is away,
and nothing should open a capture session against a locked desktop. The release restarts the effect if
the session continues underneath (the activity auto-arm).

The detector itself stays off for the whole hold — `gestureWanted` already excludes
`state == .armedWaitingClose && armSource == .gesture` — so the angle sampler is idle until the user is
back. Rails are unchanged: thermal, low battery and external sleep still end a held arm, and on battery
`lowBatteryDisarm` (on at 10 % by default) bounds a Mac left open and locked forever.
