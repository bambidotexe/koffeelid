# Architecture

Read `CLAUDE.md` first. This document explains what needs several files to understand: the arming
state machine, who owns the kernel flag, how the effect is wired in, threading, and the watchdog contract.

## Module map

```
KoffeeLidCore (Foundation only, tested)        LidPlaneKit (AppKit + Metal + ScreenCaptureKit)
  policies, filters, state machines              DesktopCapture ─▶ PlaneRenderer ◀─ PlaneShader
  FoldTracker, AngleSmoother            EffectOverlayPanel   PlaneRemap (CPU twin of the shader)
           ▲                    ▲                EffectController (start/stop/feed/simulateFold)
           │                    │                          ▲
           │                    └──────────────────────────┤
KoffeeLid app (App/Sources)                                │
  KoffeeLidController ── coordinator, owns arming state ───┘
    PowerManager, LidObserver, LidAngleSensor/Observer, GestureController,
    InternalDisplayBrightnessController, LidReopenLockController,
    DisplayTopologyMonitor, BatteryMonitor, ThermalMonitor, SleepInterruptionMonitor, SleepLock,
    OutputVolumeOverride + LidCloseSoundPlayer, HotKeyController (⌃⌥⌘L / ⌃⌥⌘K), StatusItemController
    (mug glyph from `MugShape`, path data from `App/Resources/Glyphs/*.svg`: empty cup / closed eyes (auto) / sleepy eyes / round eyes), CommandServer (CLI over distributed notifications),
    NotificationsController, RelaunchAgentController, DiagnosticLog, Preferences
    ActivityMonitor (the one activity source: journal + watchers → ActivitySnapshot, onChange to the coordinator),
    ActivityJournalTailer (vnode DispatchSource on the journal, replay then live appends),
    ActivityProcessWatcher (kqueue EVFILT_PROC: a watched pid exiting drops its session or job),
    ClaudeProcessRegistry (reads `<config>/sessions/<pid>.json`, CLAUDE_CONFIG_DIR per process),
    HookInstaller (stateless: ~/.claude/settings.json through HookConfig, and the ~/.zshrc line)
  UI/  SettingsWindow (standard title bar, no title text, adaptive material) hosting SettingsViewController
       (one page) or AdvancedViewController, both built with SettingsForm; Permissions (PermissionCatalog,
       shared by Settings and onboarding); Hooks (HookCatalog, the same for the two activity hooks);
       SleepLockSetupAction (sudoers rule through the admin dialog);
       OnboardingWindowController (four pages)
  Intents/ Arm / Caffeinate / Off / Toggle / Toggle Caffeinate / Status + AppShortcutsProvider
  main.swift ── `CommandLineClient.run` first: `koffeelid <verb>` forwards and exits before AppKit starts

KoffeeLidHook (Hook/Sources/main.swift) ── the `hook` / `job begin|end` writer, Core only
KoffeeLidWatchdog (Watchdog/Sources/main.swift) ── LaunchAgent, Core only
```

Rule of thumb: if it can be expressed without AppKit/IOKit and tested with an injected clock, it belongs in
`KoffeeLidCore`. App files are thin adapters around a system API plus a closure back to the coordinator.

## Arming state machine (`KoffeeLidController`)

Two layers. `mode: ArmMode` (Off / Armed / Armed + screen on) is what the user selected; `state: ArmState`
(idle / armedWaitingClose / armedClosed) tracks the lid within an armed mode. `isArmed` ⇔ `mode != .off`.

`setMode(_:source:)` is the single entry point: `.off` → `disarm`; from Off → `arm(source:mode:)`; Armed ↔
Caffeinate switches in place (`applyCaffeinate()` only; the kernel flag is untouched) and now also records
`armSource = source` on that in-place switch, so it can change who owns the arm (see "Auto-arm on activity"
below). `ArmSource` is `menu | rightClick | shortcut | gesture | intent | url | cli | activity`.
`perform(_:source:)` maps CLI/URL verbs (`DeepLink`) onto it and returns the `statusLine()` text the
`koffeelid` command prints.
Transitions come from `ModeCycle` (Core, tested): right-click `nextOnRightClick(current, sinceLastChange)` —
Off → Armed → Caffeinate → Off, but an armed mode older than 3 s (`lastModeChange`) goes straight to Off;
shortcuts `nextOnShortcut(target, current)` — ⌃⌥⌘L targets Armed, ⌃⌥⌘K Caffeinate; `HotKeyController.register()`
registers only the combos whose preference is on and is re-run on every related preference change. The gesture only ever
calls `arm(source: .gesture)` from Off; while a manual mode is on it is feedback (`effect.followLidFromHere()`). The
detector's states, when it listens, and the 2026-09-11 softlock are in `docs/gesture.md`.

Caffeinate = `power.keepDisplayOn` (PreventUserIdleDisplaySleep, whole session) + `power.tickleUserActivity`
(`IOPMAssertionDeclareUserActivity` every 30 s, lid open only — it would wake a closed lid's panel; it is what
defeats the screen saver and "require password after"). `applyCaffeinate()` runs on arm, disarm, mode switch
and both lid transitions.

```
idle ──arm(source)──▶ armedWaitingClose ──lid closed──▶ armedClosed
  ▲                        │  ▲                             │
  │  disarm / rail fired   │  │ lid open, armSource ≠ gesture│ lid open
  └────────────────────────┘  └─────────────────────────────┤
                                                            ▼
                             armSource == .gesture: disarm(reason: "lid opened") → requestLock() → idle
```

`arm(source:mode:)` in order: `isStarted` guard → `guard !isArmed`
→ `ArmingPolicy.evaluate(displays, thermal, battery)` (display verification, thermal ≥ serious, low battery on
battery power; an external display no longer blocks) → `power.setLidSleepDisabled(true)` (on failure
return `.blocked(.flagSetFailed)`, retry timer untouched) → invalidate `flagRetryTimer`, clear
`flagClearPending` → `acquireAssertions()` → `mode`, `lastModeChange`, `state` → `gesture.reset()` →
`refreshGestureSampling()` → `effect.start()` only when the lid is open and not suspended → `applyCaffeinate()`.

`disarm(reason:)`: cancel pending lock → `effect.stop()` → clear flag (on failure: `flagClearPending = true`,
warning badge, 30 s repeating retry) → `releaseAssertions()` → `brightness.restoreIfNeeded` → `state = .idle`
→ `refreshGestureSampling()`.

After a lid-gesture arm (Fn + close by default), `reopenWatch` (`ReopenCancelWatch`) lives until the lid closes: reopening by
`gestureReverseCancelDegrees` from the lowest angle reached, or standing still for the effect's `settleDelay`, calls `effect.stop(retracting: true)` (plane eases
flat over 0.3 s, then tears down) and `disarm(reason: "reopened")`. Menu/shortcut arms are not watched. `GestureController` watches the key chosen by `gestureModifier` (`.function` /
`maskSecondaryFn` for Fn, `.option` / `maskAlternate` for Option) through a global flags monitor plus
`CGEventSource.flagsState`, debounced by `OptionGateFilter`; `LidProgressDriver` needs the key trusted at the
start and tolerates its release for 1 s.

`handleLid(.closed)` while armed: `effect.stop()`, `applyCaffeinate()` (tickle off), then unless suspended
`brightness.darken()` (fallback `pmset displaysleepnow`) and the sound. `handleLid(.opened)`: restore
brightness, then lid-gesture arms (`armSource == .gesture`) end with `disarm`, every other source goes back to
`armedWaitingClose` and (unless suspended) `effect.start()`; **then** `lock.requestLock()` (after disarm, so
`disarm`'s `lock.cancel()` cannot kill the retry chain) — skipped only while suspended, because opening the
lid at a desk with a monitor must not lock. The lock on reopen is not a preference.

**External display = standing by, not a rail.** `externalDisplay` mirrors `DisplayTopology.standsBy`
(any non-built-in display online); `standingBy = isArmed && externalDisplay`. While suspended the mode
and the kernel flag stay (so unplugging with the lid shut keeps the Mac awake seamlessly, and Caffeinate keeps
its display assertion), but darken / sound / effect / lock-on-reopen and the gesture detector stand by.
`handleDisplays`: on connect → `effect.stop(retracting: true)`, a one-close gesture arm still waiting is
disarmed, and if the lid is closed `lock.requestLock()` (the unlocked session just became visible); on
disconnect → `effect.start()` if the lid is open. Icon unchanged; tooltip and menu header say "Standing by".

**A display that vanishes behind a closed lid** (charger-fed monitor unplugged in clamshell) is reported
*late*: macOS posts no `didChangeScreenParameters` while the lid is shut and nothing is left to reconfigure,
so the disconnect lands ~130 ms **after** the lid-open notification (measured twice on 2026-09-14, 126 and
128 ms). The reopen decision would then be taken on a topology one event out of date and skip the lock on a
session that had been sitting behind a closed lid with no display at all. Two layers close that:
`handleLid(.opened)` refreshes the topology live (`CGGetOnlineDisplayList` through `displays.current`, kept
only when `verified`) before anything reads `standingBy`, and `ReopenLockDecision` keeps a skipped lock
pending for 2 s — a disconnect inside that window, lid open, locks after all
(`the external display was already gone when the lid opened; locking after all`). Unplugging a monitor on a
lid that has been open longer than the grace window is an ordinary act and never locks. `clear()` on lid
close and on `disarm`.

Rails that call `disarm`: thermal ≥ serious, low battery (`LowBatteryPolicy`: option on, on battery,
≤ threshold; on AC nothing fires, unplugging below the threshold fires immediately), external software sleep
(`NSWorkspace.willSleepNotification` while armed **and** the root domain's "Last Sleep Reason" is not a
clamshell evaluation with the lid closed — see "Lid-sleep overrides" below).
Blocked arms notify via `notifyBlocked`; the CLI gets the reason as text.

`statusItem.mode/warning/standingBy` are set only in `refreshStatusItem()` (from `mode`, `flagClearPending`,
`standingBy`); never assign them elsewhere. The menu lists the three modes with a checkmark.

## Kernel flag ownership

The flag is `IOPMrootDomain` external method 12 (`kPMSetClamshellSleepState`): `1` disables lid-close
sleep, `0` restores it. It is process-independent: a crashed app leaves it set until something clears it.
Observable as `AppleClamshellCausesSleep` on the root domain (`No` = someone disabled lid sleep).

Who touches it and when:

| Moment | Code | Condition |
|---|---|---|
| Launch | `start()` | only if a stale `koffeelid.pid` or `display-brightness-recovery.json` exists (unclean previous exit) |
| Arm | `arm()` | always sets `1` |
| Re-apply | `reapplyFlag(reason:)` | only while armed and only if `readLidCausesSleep() != false` (idempotent; avoids a feedback loop with the root-domain notification it reacts to). Triggers: root-domain interest notification, power-source change, display sleep/wake, system wake, screen-parameter change |
| Disarm | `disarm()` | always clears; failure → `flagClearPending` + 30 s retry timer |
| Quit | `shutdown()` | 3 synchronous attempts, only if `wasArmed \|\| flagClearPending \|\| power.lidSleepDisabled`; on total failure a "restart the Mac" notification |

The conditional launch/quit clears exist because other lid-sleep utilities drive the same flag.
If you make them unconditional you will silently disarm whatever else the user is running.

## Lid-sleep overrides and the sleep lock

powerd owns the very bit selector 12 sets (`docs/platform-notes.md` § Kernel lid-sleep flag) and rewrites
it whenever its own clamshell policy flips — the charger chime does that on every plug-in. The kernel then
evaluates the closed lid inside that write and starts a `Clamshell Sleep`; no re-apply can beat it.

Two answers, layered in `KoffeeLidController`:

| Layer | Code | What it does |
|---|---|---|
| Hold | `handleExternalSleep` + `SleepInterruptionPolicy` (Core) | On `willSleep`, `power.readLastSleepReason()` == "Clamshell Sleep" with the lid closed means an override, not a request. The coordinator keeps mode, state and assertions and re-applies the flag: the held `PreventSystemSleep` assertion vetoes the kernel's dark wake → sleep step, so the Mac idles in dark wake (processes run, display and audio off) until the lid opens or HID input tickles a full wake. `SleepOverrideGuard` (3 per 120 s) stops the hold from cycling; past it, and for every other reason, the old path runs (`disarm(reason: "external sleep")`). Log: `holding the session in dark wake`. |
| Lock | `SleepLock` (`engageSleepLock` on arm, `releaseSleepLock` on disarm/quit, `releaseIfMarkerPresent` at launch) | `sudo -n /usr/bin/pmset disablesleep 1` sets `SleepDisabled` on the root domain, which the kernel checks before *every* sleep request, so the override sleep never starts. Needs the sudoers rule from `SleepLockSetup` (Core), installed by `SleepLockSetupAction` (Settings › Permissions › Sleep lock › Set up…, onboarding step) through the administrator-password dialog, or by the one-liner `script/install.sh` prints; without it the arm logs `sleep lock unavailable` and only the hold protects the session. An armed session engages the lock as soon as the rule lands (`sleepLockRuleChanged`). The setting survives reboots, so `sleep-lock` (marker file next to the pid file) records that this app set it, and launch recovery releases a stale one unconditionally — it is evidence we created. `koffeelid status` shows `sleep lock: on/off`. |

## Command line and URLs

`DeepLink` (Core) is the shared vocabulary: `arm | off | caffeinate | toggle-armed | toggle-caffeinate |
status | settings` (aliases `disarm` → off, `toggle` → toggle-armed) for `koffeelid://<verb>` URLs, the
`koffeelid` command and the coordinator's `perform`. `CommandLineClient` (in `CommandServer.swift`) runs from
`main.swift` when argv[1] is a verb: launches the app if it is not running (`NSWorkspace.openApplication` on
`Bundle.main.bundleURL`), posts `dev.rubens.koffeelid.command` with `{command, replyTo}` on the
`DistributedNotificationCenter`, waits ≤ 1 s for the reply text on `replyTo` (12 attempts, since the server
registers at the end of `start()`), prints it and exits (0, or 1 when the reply starts with "did not").
`CommandServer` in the app answers with `perform(link, source: .cli)`. The `/usr/local/bin/koffeelid` wrapper is
a zsh `exec` of the bundle binary (a symlink would break `Bundle.main`).

## Auto-arm on activity

KoffeeLid can arm itself while a Claude Code session or a terminal command is running, and disarm itself
once nothing is, using its own Claude Code hooks and its own zsh hooks — no socket, journal or hook shared
with any other tool. Full design and the session/job state-machine tables:
`docs/superpowers/specs/2026-09-11-activity-auto-arm-design.md` §4–§6; not reproduced here.

Modules: Core `ActivityConstants` (every timing, with its evidence), `ActivityEvent`/`ActivityCodec` (the
journal line type, snake_case keys), `ActivityTrim` (hook payload → capped `ActivityEvent`),
`ActivityJournalWriter` (one `O_APPEND` write, `readAll`), `ActivitySessionStore` (per-session state
machine), `ActivityJobStore` (per-shell job slots), `ActivityArmPolicy` (the auto level with its hold-off),
`ClaudeRegistryRecord` (parses `<config>/sessions/<pid>.json`), `HookConfig`/`HookSettingsFile` (pure
transform + strict IO for `~/.claude/settings.json`), `ShellInit` (the zsh snippet template), `ProcWalk`
(sysctl ancestor chain, Claude-process identification, best-effort environment read) — all Foundation-only
and tested. The `KoffeeLidHook` tool target (`Hook/Sources/main.swift`, Core only, embedded next to the
watchdog) is the `hook` and `job begin|end` verbs: never launches the app, always exits 0. In the app:
`ActivityMonitor` (owns both stores, replay, tailing, ticks, rotation, registry checks, one `onChange`
closure), `ActivityJournalTailer` (vnode `DispatchSource` on `activity.jsonl`, follows rotation),
`ActivityProcessWatcher` (kqueue `EVFILT_PROC`), `ClaudeProcessRegistry` (reads the registry file for a
pid), `HookInstaller` (install/uninstall, hook binary path, snippet). `KoffeeLidController` gains
`ArmSource.activity`. The three new verbs — `install-hooks | uninstall-hooks | shell-init zsh` — are not
`DeepLink` cases and never reach `CommandServer` or `KoffeeLidController.perform`: `CommandLineClient.run()`
(the CLI's client side, in `CommandServer.swift`) intercepts them before the `DeepLink` parse and calls
`HookInstaller` — a stateless helper with no link back to the coordinator — directly, in-process, printing
its result and exiting without launching or contacting the app.

Data flow: `KoffeeLidHook → activity.jsonl → ActivityJournalTailer → ActivityMonitor (ActivitySessionStore +
ActivityJobStore) → onChange → KoffeeLidController.handleActivity → ActivityArmPolicy → applyAuto(.on | .off)
→ arm(source: .activity) / disarm(reason: "activity ended")` (only when the manual mode does not hold the arm). Every hook event and every zsh job appends one JSON line to
`~/Library/Application Support/KoffeeLid/activity.jsonl`; the app never talks back to the hook.

`ActivityMonitor.start()` replays `activity.1.jsonl` then `activity.jsonl` from this boot only, prunes
sessions whose pid is dead or no longer looks like Claude (`ProcWalk.isAlive`/`looksLikeClaude`) and jobs
whose owner shell is dead, then arms the live tailer. `ActivityJournalTailer.start(fromOffset:)` seeks to
the byte offset the replay already consumed (clamped to the file's current size), so nothing already
replayed is applied twice and a rotation racing the launch is safe. `ActivityMonitor.start()` itself runs at
the very end of `KoffeeLidController.start()`, after `isStarted = true`: a relaunch (watchdog or manual)
picks the replayed running level straight back up and can call `arm(source: .activity)` immediately, rather
than waiting for the next hook.

Two independent arms (2026-09-12, evening; supersedes spec §6). `ActivityArmPolicy` is a *level*: `isOn`
goes on with the first `update(running:enabled:now:)` that carries work and returns `.on`; when the work stops
it stays on through the hold-off and `tick` returns `.off(releaseManual:)` when that passes. It knows nothing
about the manual mode. `KoffeeLidController.applyAuto` ORs the two: `.on` arms only if the Mac is idle
(`arm(source: .activity)`, which leaves `mode` at `.off`) and otherwise just logs and redraws the glyph;
`.off` disarms only if `mode == .off` (`disarm(reason: "activity ended")`) and otherwise leaves the manual arm
standing. Manual Off goes through `releaseManual`: `mode = .off`, and when the level is on the session stays,
`armSource` becomes `.activity`, caffeinate is dropped (it is manual-only). A one-close gesture arm ends the
same way (lid reopened, reverse cancel, stall, external display), so it never kills an auto-arm underneath.
The rails, a reset and a quit call `disarm`, which ends everything and `suspend`s the level until the running
work stops and something starts again; a blocked arm (`armFailed`) waits the same way, so nothing hammers the
notification centre once per tick.

The glyph shows manual first: `refreshStatusItem` draws the armed / screen-on cup for a manual mode and the
`auto` cup only while an auto-only arm holds the Mac; the menu checks `mode` and adds the greyed line under the
header while the level holds ("Auto-armed while Claude Code works" / "… while a command runs" / "… while
Claude Code and a command run", or "Auto-armed, off in 12 min" once idle; `autoArmHint()`). Choosing Armed or
Armed + screen on over an auto-only arm makes it manual in place (`armSource = source`); turning it Off again
drops back to the auto-only arm while the level holds.

Hold-offs (2026-09-12). `update` takes the set of `ActivityKind`s running (`.claude` when a session is
working, `.terminal` when a job counts; `ActivitySnapshot.kinds`) and accumulates every kind seen during the
arm in `involved`. When nothing runs any more, the disarm is scheduled `currentHoldOff` after the falling
edge: the longest `holdOffs[kind]` over `involved` (`Preferences.activityHoldOffs`, defaults in
`ActivityConstants.holdOffDefaults`: 30 min after Claude Code — its user is usually remote and about to
prompt again, and a sleeping Mac would drop that connection — 1 min after a command; a command finishing
last never shortens Claude's wait). `involved` resets when the level drops; changing a hold-off moves a
pending drop. Any resume inside the wait cancels it. The wait is for a remote user whose connection would die
with the Mac: someone typing or moving the mouse at the Mac after the work ended is responsible for arming it,
so `KoffeeLidController.checkLocalInput` (a 2 s timer alive only while a countdown runs) compares
`LocalInputMonitor.lastInputDate()` — `CGEventSource.secondsSinceLastEventType` over the keyboard and mouse
event types, no permission needed — with `ActivityArmPolicy.idleSince` and calls `userActive(now:)`, which
drops the level at once (log `auto-arm ended: local input during the hold-off`; a pending "Disarm once
finished" releases the manual mode with it). `requestDisarmOnce(on)` is the menu's "Disarm once
finished": while pending (`disarmOnce`), the next idle stretch — or the current one, measured from when the
work ended — is `onceHoldOff` (`ActivityConstants.disarmOnceHoldOffSeconds`, 60 s) long, and the drop carries
`releaseManual: true`, so `applyAuto` sets the manual mode Off too and the Mac disarms (log `disarm once
finished: manual mode (…) released`). Already idle for longer than that, the request fires at once
(`requestActivityDisarmOnce` ticks right after setting it). The request lasts until it fires, is clicked off
again (back to the full hold-off), or a rail `suspend`s the level. `statusLine()` shows `disarm once finished:
pending`; the log has `disarm once finished requested|cancelled`.

`ClaudeProcessRegistry.read` is the rescue path for turns that fire no hook (Esc, Ctrl-C); see "Claude Code
hooks and registry" in `docs/platform-notes.md` for why it always falls back to
`~/.claude/sessions/<pid>.json` on this Mac.

`statusLine()` appends `auto-armed (activity)` while the level holds an armed Mac (manual or not; `mode:`
stays the manual mode, so `mode: off · auto-armed (activity)` is an auto-only arm and `script/install.sh`
refuses on it), `disarm once finished: pending` while the request stands, and always an `activity: …`
summary — so the hooks can be verified before the Settings switch is turned on.

Setting either hook up is not limited to the CLI: the onboarding "Arm while you work" page and the Settings
"Hooks" group (§ Settings UI) both render `HookCatalog.items`, two `PermissionItem`s over the same
`HookInstaller`. The Claude Code row's button calls `HookInstaller.install()` (unchanged). The Terminal (zsh)
row's button calls `HookInstaller.addToZshrc()`, new alongside `install()`/`uninstall()`: it appends
`zshrcHeader` ("# ---------- KoffeeLid ----------"), `zshrcDescription` and the guarded `zshLine` to `~/.zshrc`
(creating the file if needed), guarded by `zshrcHasSnippet()` so a second click is a no-op — it recognizes
both its own marked block and a hand-written `shell-init zsh` line. Either button, on success, sets
`Preferences.shared.armOnActivity = true`: setting up a hook from the UI is the user asking for auto-arm; the
Settings switch remains the only way to turn it back off.

## Effect wiring

The effect is a **closing-only** illusion: the desktop keeps its orientation in space while the lid
folds over it, so the Mac visibly keeps working. It never plays on opening.

`EffectController.start()` is called by the coordinator on arm (lid open) and on lid reopen when the arm
was not the lid gesture (`armSource != .gesture`); `stop()` on lid close, disarm and quit. `start()` prepares only: an invisible
`EffectOverlayPanel` (full screen frame at `.screenSaver` level, so its black backdrop also covers the menu bar
and its status items while the plane folds; the capture excludes the panel's window number), a paused `PlaneRenderer`, and a `DesktopCapture` whose shareable content is
enumerated ahead of time (`prepare()`, no frames). It asks for angle samples through
`onNeedsAngleSampling` (consumer key `"effect"` on `LidAngleObserver`); the coordinator registers
`"gesture"` while the detector is wanted (idle, or armed from another source with the lid open and no external
display — `gestureWanted`, `docs/gesture.md`) and the Advanced page registers `"settings"` while visible.

Per sample (`feed(angleDegrees:)`), `FoldTracker.update`:

- the rest angle follows the lid whenever it opens (fold stays 0);
- once the lid is more than the gesture's `gestureActivationDegrees` (default 4, mirrored into
  `EffectController.foldThresholdDegrees` by the coordinator) below the rest angle,
  `fold = (rest − threshold) − angle` grows with every degree and shrinks back to 0 when the lid is
  reopened to that point; opening further does nothing and moves the rest angle;
- a lid left part-way closed for `settleDelay` eases back to flat (rest → angle + threshold);
- for arms other than the lid gesture (`EffectController.gateToStartAngle`, set by `arm()`), the zero point is
  additionally capped at `startBelowDegrees` (75°, slider 30–90, never above the gesture's start angle:
  `EffectParameters.clamped()` raises the gesture one and the two Advanced sliders push or stop at each
  other): nothing starts while the lid is above it,
  so adjustments while working at 100–120° never trigger it. The gesture
  detector keeps running during such an arm; a completed gesture calls `effect.followLidFromHere()` (gate off,
  zero at the current angle — unless the gate already started a fold, which is kept) instead of arming again,
  so the plane still answers the hand immediately; when
  that fold ends (reopened or settled flat) the gate is restored. Stillness is 1.5° in `FoldTracker` and
  `ReopenCancelWatch` because the integer sensor can flicker 89↔90 indefinitely.

The tracker's fold only says *whether* the plane is folding; what it shows is `FoldGeometry.fold(angle:
zeroAngle:)` (Core, tests in `FoldGeometryTests`): the inner screen stands upright at
`EffectParameters.gestureStartBelowDegrees` (Advanced › Lid effect › "Start below (with the lid gesture)",
default 95°, slider 30–120°; the controller rebuilds its `FoldGeometry` from it), so the fold is
`upright − lid angle`, 1:1 with the hinge and nothing above it. With the default, a gesture made at 110°
starts its session at 106° (capture warms up) but shows nothing until the lid passes 95°. When the zero angle is below
the upright angle (the start-below gate, a `followLidFromHere` rebase, a gesture under it, the settle-back easing of the
rest angle) the fold starts flat there and catches up with the 1:1 curve over `min(gap, 30°)` of travel
with a quadratic ease-out: faster than the lid at first, exactly with it once caught up. Reopening runs the
same function backward.

`foldBegan` starts a **session**: `captureStill()` (one `SCScreenshotManager` frame, ~20 ms) is shown
immediately, then the 60 fps stream takes over and `effect: capture started` is logged. `foldEnded`
ends the session after a 0.75 s linger (`effect: capture stopped`); the panel fades out and the
renderer forgets its content. Nothing is recorded while armed with the lid at rest.

Smoothness: the sensor publishes a new whole-degree value only every ~100 ms (10 Hz, measured with
`script/lid-sensor-rate.swift`, see `docs/platform-notes.md`), so a close arrives as a staircase of
100 ms plateaus and two-point interpolation of 30 Hz reads showed it as stop-and-go. `LidAngleObserver`
therefore polls at 120 Hz while the value has changed within the last 0.7 s (30 Hz at rest; a read costs
~0.5 ms) so the moment each value appears is known to ~8 ms, but still *delivers* at 30 Hz — the gesture
filters count samples — with every delivery stamped with the time its value was first seen.
`EffectController.feed(angleDegrees:changedAt:)` runs `FoldTracker` on the delivery time and feeds
`AngleSmoother` with the change time, so the smoother sees one event per value change (same time + same
value = ignored; same time + new value = a change without motion such as the settle-back easing, which
collapses the buffer so it is honoured exactly). The smoother keeps 0.25 s of events, fits a least-squares
line, evaluates it 100 ms in the past — one sensor period, so the read point lies between two known events;
never beyond the newest event and never outside the buffered value range, so a stopping lid does not
overshoot — and low-passes the result (τ = 50 ms). That is the *smooth* end of Advanced › Lid effect ›
**Responsiveness** (`EffectParameters.responsiveness`, `AngleSmoother.tuning`): 0 % waits the full sensor
period (≈ 157 ms behind the true lid at 45°/s, of which ~50 ms is the sensor itself; frames within
80–120 % of the ideal step at 15°/s; no overshoot on a stop). 100 % reads 40 ms in the past and follows the
fitted line ahead by up to 60 ms past the newest event, τ 30 ms (≈ 79 ms behind; 62–163 % at 15°/s; an
abrupt 45°/s stop overshoots ≤ 2.3° and comes back as the prediction fades out 150 ms after the last
event). In between the three timings interpolate linearly; default 70 % (≈ 102 ms behind, 68–146 % at
15°/s). Once events stop the estimate settles on the last real reading, not on the fitted line (which
carries a rounding residual). Numbers from `AngleSmootherTests` and the harness in the 2026-09-11 session.
The renderer pulls the value every display frame through `angleProvider` at up to 120 Hz. Blur levels are computed at 1, 1/2, 1/4 and 1/8 of the capture size
only when a new frame arrives.

`DesktopCapture` excludes the overlay's own window from the filter. `start()`/`stop()` are
re-entrant per session; a stop landing during an in-flight start wins via a generation counter.

`PlaneShader.source` (MSL string, compiled at runtime) and `PlaneRemap` (Swift) implement the same
geometry, the **inner screen**: the desktop stands upright at the hinge and never moves while the display
folds over it by `a`. Seen from the front, a display row at height `h` (0 = hinge) sits at `h·cos a`, so it
samples the desktop there: the desktop stays anchored at the hinge, is magnified by `1 / cos a`
(`zoomStrength`, 0…2, applies `cos a ^ -zoom`; 1 = exact geometry, 0 = no zoom, 2 = squared) and its top is cropped away above
the display's edge. Perspective (`perspectiveStrength`, 0…2) narrows the inner screen toward the top, from
`| |` to `/ \`, with the black void beside it. The top row is
`N = 1 + 2·(1 − cos a)·perspective` times narrower (≈ the earlier `1 / cos a − 1` below 60°, half of it at
80°, capped at `1 + 2·perspective`: the `1 / cos` form pinched the top into a spike at the end of the fold,
seen in the user's recording) and the visible half-width is linear in `h` from the
hinge to `1 / N`, so the sampling factor is `1 / (1 − h·(1 − 1/N))` and the edges are straight lines; a
linear factor `1 + h·(N − 1)` drew them as inward-bowing hyperbolas. The gap between the glass and
the inner screen is `h·sin a`, hence blur radius
`strength · h · |sin a| · 65`, zero at the hinge, blended across four Gaussian levels (σ = 2, 6, 16, 40 per
1000 px) and skipped entirely when `blurStrength` is 0.

**Soft edges and shading** (2026-09-12, the look of Apple's foldable, tuned against frames of its
product video with a CPU render of the same model): away from the hinge the inner screen never ends on a
hard line, because a hard edge commits to one viewing angle and any mismatch reads as fake. With the same
gap `g = h·sin a`: each keystone side melts into the void over a band `0.35·edgeSoftness·g` display widths
wide (`PlaneRemap.sideFeather`, a smoothstep on the display-space distance to the side, so crisp at the
hinge and widest at the top corners); the top row melts over `0.08·edgeSoftness·sin a` display heights
(`topFeather`, narrow: Apple's far edge only dims, the corners go black where the side melt meets the
shading); and the picture is multiplied by `1 − 0.55·shading·g` (`shade`). `coverage(uv:…)` is the product
of the two melts; `edgeSoftness` 0 is the old crisp cut (a zero-width melt is a step). Both are
Advanced › Lid effect sliders, 0…200 %, default 100 %, `PlaneUniforms.edgeSoftness/shading`. Change one,
change the other, and update `PlaneRemapTests`.

## Settings UI

Two windows, one look. `SettingsWindow` has a standard opaque title bar with the title text hidden (the page
starts below the bar, so scrolling never runs under the traffic lights), follows light/dark, and sets its
content view controller to a `PaneViewController` subclass; `preferredContentSize` is capped to the visible
screen height (menu bar and Dock excluded; `NSScreen.main` can be nil for a menu-bar app, so it falls back to
the first screen) and the page scrolls if taller. `PaneViewController.loadView` paints the
background (`NSVisualEffectView(.underWindowBackground)`), then calls `build(_ f: SettingsForm)` once and
reports `preferredContentSize`.

`SettingsForm` is the only layout vocabulary: `header` (13 pt semibold), `group { g in … }` (10 pt rounded
box tinted with `labelColor` at 7 %) containing `row(label, controls…, detail:)` (33 pt, label left,
controls right), `sliderRow` (full-width slider + value, under its switch) and `labelledSlider` (label +
value line above a slider); `note` (11.5 pt secondary) and `link` (accent-coloured text button) sit between
groups. Controls come from `SettingsForm.switch/popup/button/value`, all at the small control size.
`labelledSlider` returns a `SliderHandle` (`set(value)` moves the knob and its value label) for the sliders that
must keep an ordering with a neighbour: the two "Start below" sliders of Advanced › Lid effect push or stop at
each other through it after every change (`EffectParameters.clamped()` decides, the handle only redraws).
Closures capture `[prefs]` or `[weak self]`, never the control (the `actionHandler` trampoline retains it).

`SettingsViewController` (main page): App › launch at login; Arm with › Fn + close lid (label follows
`gestureModifier`), right-click, Armed shortcut ⌃⌥⌘L (switch), Armed + screen on shortcut ⌃⌥⌘K (switch);
While KoffeeLid is armed › lid effect, lid-close sound (popup + switch), forced volume + slider, low-battery
disarm + slider; Permissions › one row per `PermissionCatalog` item (value "Granted" in grey or "Not granted"
in orange, ⚠︎-prefixed for required items, the grant button only while missing; rows re-read on
`viewWillAppear` and on `NSWindow.didBecomeKeyNotification`); Hooks › one row per `HookCatalog` item, built
the same way and sharing the same `permissionRows` refresh (value is the item's `doneTitle` — "Set up" for both — once granted, with a Remove button that runs the
item's `remove` action; neither hook is required); link to Advanced settings…. There is no master
switch: KoffeeLid is always enabled. `AdvancedViewController`: Lid gesture › Hold while closing (Fn/Option),
activation and cancel sliders, live lid angle; Lid effect › start-below (gesture, then the others), return-to-flat, zoom, perspective, blur
strength, show angle, Simulate a fold (works idle too: starts the effect temporarily); App › crash-recovery
(watchdog) status, Diagnostics log switch (`Preferences.diagnosticsEnabled`; `DiagnosticLog.log` returns early
when off, the last line before and the first line after the switch are written); links: Open diagnostics
log, Show onboarding again (`AppDelegate.showOnboarding` builds a fresh controller), Reset permissions and undo
every change… (`confirmReset` → `KoffeeLidController.resetEverything()` → onboarding).

**Permissions** (`UI/Permissions.swift`). `PermissionItem` (title, why, required, granted, buttonTitle, action,
`doneTitle` — "Granted" by default) is the row model shared by both catalogs below. `PermissionCatalog.items`
is the single list of macOS grants: Sleep lock (required; `sleepLockAvailable`; `SleepLockSetupAction`), Login
Items (required; the watchdog agent's `SMAppService.status == .enabled`; opens System Settings), Screen
Recording (`ScreenCapturePermission`), Notifications (asynchronous: `refreshNotifications` caches
`UNUserNotificationCenter` authorization; a denied grant opens the Notifications pane, otherwise the system
prompt). `KoffeeLidController.start()` only calls `requestAuthorization` once onboarding is completed, so the
first prompt comes from the row, with its reason.

**Hooks** (`UI/Hooks.swift`). `HookCatalog.items` mirrors `PermissionCatalog` for the two hooks behind
auto-arm on activity: Claude Code (granted when `HookInstaller.installedCount() ==
HookConfig.events.count`; the button runs `HookInstaller.install()`, Remove runs `uninstall()`) and Terminal (zsh) (Remove runs
`removeFromZshrc()`, whose pure part is `ShellInit.zshrcRemoving` — it removes only what KoffeeLid owns:
everything between two `zshrcHeader` lines inclusive (the block opens and closes with
"# ---------- KoffeeLid ----------" and its comment warns that Remove deletes what sits between them); an
unclosed header's block when it holds nothing but comments and KoffeeLid eval lines, else the header alone;
the old `zshrcMarker` comment; any uncommented line calling `shell-init zsh` that names KoffeeLid. Another tool's
`shell-init zsh` line — SidePulse has one — is neither detected as ours nor removed (2026-09-12 fix);
granted by `HookInstaller.zshrcHasSnippet()`; the button runs `HookInstaller.addToZshrc()`, which appends
the header block once, idempotently). Both buttons read "Set up…". Either action also
sets `Preferences.armOnActivity` to `true` — setting up a hook from the UI is asking for auto-arm — and the
Settings switch stays the only way to turn it back off.

**Menu bar** (`KoffeeLidController.buildMenu`, rebuilt on every click). After the three modes (checked
against `userMode`, so an auto-arm shows as Off; each title ends with its cup in grey through
`StatusItemController.menuTitle`, an inline text attachment drawn in `secondaryLabelColor`, as does the
auto-arm hint line with the `auto` cup), one item when either hook is set up
(`HookInstaller.installedCount() == HookConfig.events.count` / `HookInstaller.zshrcHasSnippet()`): "Disarm
once finished", checked while `activityDisarmOncePending`, a toggle (`menuToggleDisarmOnce` →
`requestActivityDisarmOnce`). The two hold-offs live in Advanced › Auto-arm on activity ("Auto-disarm after
Claude Code finishes", 1–120 min; "Auto-disarm after a command finishes", 10 s–10 min).

**Onboarding** (`OnboardingWindowController`): a floating window (`level = .floating`, re-activated after
every action, since a menu-bar app's windows drop behind whatever took focus) with four pages rebuilt on each
`render()`: the pitch (headline with the word "agents" in the mug brown, three SF Symbol capsules), the
Permissions page, the Hooks page ("Arm while you work": the two `HookCatalog` items, same layout), and "All
set". Permissions and Hooks share one `listPage(header:intro:items:continueTitle:)` (one row per catalog item
with title, ⚠︎ for required, why, grant button or the item's `doneTitle`, separators; the footer button reads
Continue once every required item — or, on the Hooks page, any hook — is granted, Skip otherwise; grants
refresh on `didBecomeKey`, on both pages). Page views are plain stacks pinned to the content view; width
constraints are activated only once the views share an ancestor.

**Reset** (`KoffeeLidController.resetEverything()`): disarm, `SleepLock.removeRule()` (admin dialog) when the
rule exists, delete the sleep-lock marker, unregister then re-register the login items (so the row has
something to approve), `tccutil reset ScreenCapture`, drop the app's entry from usernoted's group preferences
and restart the daemon (no public API), delete relaunch-history and brightness-recovery files, remove the
UserDefaults domain, re-register the hot keys. Logged as one `reset:` line.

## Threading

- Everything in `KoffeeLidController` and the UI is `@MainActor` / main thread. IOKit callbacks are routed
  to main (`IONotificationPortSetDispatchQueue(.main)`, run-loop sources on the main loop, NSWorkspace
  observers with `queue: .main`).
- `LidAngleObserver` ticks on a private utility queue and hops to main before `onSample`; `filter.reset()`
  runs before the timer resumes.
- `PlaneRenderer.draw(in:)` runs on MTKView's callback (main thread by default); `submit(pixelBuffer:)` is
  called from the capture queue and hands over the latest buffer under a lock.
- `DiagnosticLog` appends on a serial queue; `flush()` before `exit()`.

## Watchdog contract

The app writes `koffeelid.pid` (pid + executable path) at start and removes it on clean quit. The watchdog
(LaunchAgent `dev.rubens.koffeelid.agent`, `RunAtLoad`, `KeepAlive.SuccessfulExit = false`) resolves its
bundle from its own executable path (`proc_pidpath`, not argv[0]), then:

- no pid file, or pid file older than boot, or not inside an `.app` → log and `exit(0)` (launchd does not
  restart a successful exit);
- polls `kill(pid, 0)` every second and also checks `proc_pidpath(pid)` still points at the recorded
  executable (pid reuse);
- after death: pid file gone → clean exit, stand down; unreadable → unclean; pid changed → follow the new
  instance; else `CrashLoopGuard` (3 relaunches / 10 min, history in `relaunch-history.json`, consumed before
  the `open` attempt) → `open <bundle>` → wait ≤ 30 s for a fresh pid.

Because launchd starts the watchdog before the app at login, `RelaunchAgentController.kickstartIfEnabled()`
runs `launchctl kickstart` on every app start so a live watchdog observes the current pid. Both need the
user's Login Items approval (`SMAppService.Status.requiresApproval` until then).

## Files that matter most

- `App/Sources/KoffeeLidController.swift` — the state machine above; ~780 lines, read all of it before editing.
- `App/Sources/PowerManager.swift` — the only place that talks to `IOPMrootDomain`.
- `Sources/LidPlaneKit/EffectController.swift` — effect lifecycle; `Sources/KoffeeLidCore/FoldTracker.swift` — when and how far it folds.
- `Sources/KoffeeLidCore/ArmingPolicy.swift` — `ArmBlockReason` cases must stay exhaustive in `notifyBlocked`.
- `App/Sources/Preferences.swift` — registered defaults are the single source of default values.
- `App/Sources/CommandServer.swift` — CLI client (`CommandLineClient`, runs before AppKit) and in-app server.
- `App/Sources/MugShape.swift` — the menu bar glyph / app icon geometry (embedded SVG path data); also pasted
  into `script/make_icon.sh`.
- `App/Sources/StatusItemController.swift` — status item rendering, `state/warning/standingBy`, glyph size.
