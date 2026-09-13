# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app, **KoffeeLid** (bundle id `dev.rubens.koffeelid`), that keeps a MacBook awake with the
lid closed, plays a closing-only "desktop stays up" lid effect, can force the volume of the lid-close sound,
and has an **Armed + screen on** mode (display never sleeps, replaces Vorssaint). Three modes:
Off / Armed / Armed + screen on (`ArmMode.caffeinate` in code and CLI, « Activé + écran allumé » in French). The lid gesture is Fn (Globe) + close (Option selectable). A `koffeelid` command
line drives everything. Personal build: no licensing, no updater, en + fr only.

Repo: `~/Projects/koffeelid`, GitHub `git@github.com:bambidotexe/koffeelid.git` (`origin`, branch `main`, SSH
auth works as `bambidotexe`, `gh` installed via brew and logged in as `bambidotexe`). History was squashed to one root commit for **v1.0.0**
(tag pushed, GitHub release with `dist/KoffeeLid-1.0.0.dmg` created with `gh release create`, 2026-09-13). Installed copy: `/Applications/KoffeeLid.app`, data in `~/Library/Application Support/KoffeeLid/`.

Deeper docs, read them when the task touches the area:

- `docs/architecture.md` — modules, arming state machine, threading, who owns the kernel flag.
- `docs/development.md` — build/install/debug workflow, how to add a preference, string or settings control, testing constraints on this Mac.
- `docs/platform-notes.md` — the macOS mechanisms and how they were verified (kernel flag selector 12, HID lid-angle sensor, private frameworks, watchdog contract).
- `docs/manual-checks.md` — the hardware checklist; unit tests cannot cover IOKit/Metal/CoreAudio paths.
- `docs/gesture.md` — the Fn + close detector: pipeline, when it listens, what it does in every state, the 2026-09-11 softlock post-mortem, log lines.

## Commands

```bash
swift test                                            # KoffeeLidCore + LidPlaneKit unit tests (223); needs the Claude Code sandbox off, like xcodebuild
swift test --filter LidProgressDriverTests            # one test class
swift test --filter LidProgressDriverTests/testArmsAfterActivationDegreesWithOption   # one test
swift build                                           # libraries only; the app needs Xcode (below)

script/bootstrap.sh                                   # xcodegen generate (run after adding/removing App or Watchdog files)
xcodebuild -project KoffeeLid.xcodeproj -scheme KoffeeLid -configuration Debug \
  -derivedDataPath DerivedData build 2>&1 | grep -E 'error|warning:|BUILD'   # Debug app build
script/build.sh [Release|Debug]                       # same, prints the .app path last
script/install.sh                                     # Release build → /Applications/KoffeeLid.app; REFUSES while the app is armed (FORCE=1 overrides)
script/run.sh                                         # install + launch + tail the diagnostics log (never returns)
script/make_icon.sh                                   # regenerate the app icon PNGs from MugShape (glyph SVGs in App/Resources/Glyphs)

"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" status   # CLI: arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings | install-hooks | uninstall-hooks | shell-init zsh
```

The CLI is the app binary itself (`main.swift` forwards the verb to the running instance over distributed
notifications, launching it if needed, and exits). `script/install.sh` writes a `/usr/local/bin/koffeelid`
wrapper when that directory is writable; otherwise it prints the `sudo` one-liner.

- `KoffeeLid.xcodeproj`, `DerivedData/` and `.build/` are generated and git-ignored; edit `project.yml`, never the xcodeproj.
  If `xcodebuild` prints "Stale file … outside of the allowed root paths" or `swift test` fails on a module-cache
  path, the repo folder moved: `rm -rf DerivedData .build` and rebuild.
- Version lives in three places that must agree: `App/Info.plist` `CFBundleShortVersionString`,
  `KoffeeLidCore.version` (`Sources/KoffeeLidCore/KoffeeLidCore.swift`) and its assertion in
  `Tests/KoffeeLidCoreTests/SmokeTests.swift`; the README test badge is a static shields.io URL.
- App targets only build with `xcodebuild` (App Intents metadata, String Catalog, asset catalog). `swift build` covers `Sources/` only.
- Treat compiler warnings as failures; the branch is warning-free.
- No linter is configured.

## Architecture in one screen

Five targets, dependency direction strictly downward:

| Target | Kind | Depends on | Contents |
|---|---|---|---|
| `KoffeeLidCore` (`Sources/KoffeeLidCore`) | SwiftPM library, Foundation only | — | Every policy/state machine as a value type with injected time: `ArmMode`/`ModeCycle`, `ArmingPolicy`, `LidProgressDriver`, `OptionGateFilter`, `AngleSampleFilter`, `FoldTracker`, `AngleSmoother`, `FoldGeometry`, `ReopenCancelWatch`, `EffectParameters`, `VolumeOverridePolicy`, `CrashLoopGuard`, `PidFileRecord`, `DiagnosticFileWriter`, `DeepLink`, the activity feature's `ActivityConstants`/`ActivityEvent`/`ActivityTrim`/`ActivitySessionStore`/`ActivityJobStore`/`ActivityArmPolicy`/`ClaudeRegistryRecord`/`HookConfig`/`HookSettingsFile`/`ShellInit`/`ProcWalk`… **All unit tests live here.** |
| `LidPlaneKit` (`Sources/LidPlaneKit`) | SwiftPM library | Core | The lid-close effect: `EffectController` turns lid angles into a fold (`FoldTracker`, closing only, threshold-gated) and runs a capture session only while folded: `DesktopCapture` (ScreenCaptureKit) → `PlaneRenderer` (Metal, shader in `PlaneShader.swift`, CPU twin `PlaneRemap.swift`: the "inner screen" geometry, desktop anchored at the hinge, magnified `cos(fold)^-zoom`, cropped at the top, narrowed toward the top by `perspectiveStrength`, blur ∝ `h·sin(fold)`) inside `EffectOverlayPanel`. |
| `KoffeeLid` (`App/Sources`) | Xcode app target | Core, LidPlaneKit | `KoffeeLidController` is the **only** object that mutates arming state (`setMode(_:source:)` is the entry point; `perform(_:source:)` runs CLI/URL verbs); every other file is a collaborator that reports events to it via closures (`CommandServer` for the arming verbs, `ActivityMonitor` for auto-arm on activity); `HookInstaller` is a stateless helper used directly by the CLI client (`CommandLineClient`) and the Settings page, with no link to the coordinator. UI under `App/Sources/UI` is programmatic AppKit built with `SettingsForm` (section headers, translucent grouped rows, notes, links): one Settings page (`SettingsViewController`: App, Arm with, While armed, Permissions, Hooks) plus an Advanced window (`AdvancedViewController`: every tunable, diagnostics switch, show onboarding, reset) both hosted by `SettingsWindow`; `PermissionCatalog` (`UI/Permissions.swift`) is the one list of macOS grants, and `HookCatalog` (`UI/Hooks.swift`) the one list of activity hooks, both shared by Settings and the four-page `OnboardingWindowController`. |
| `KoffeeLidWatchdog` (`Watchdog/Sources/main.swift`) | Xcode tool, embedded in the app | Core | LaunchAgent that relaunches the app after an unclean exit (pid file present) and stands down otherwise. |
| `KoffeeLidHook` (`Hook/Sources/main.swift`) | Xcode tool, embedded in the app | Core | `hook` and `job begin\|end` verbs, run once per Claude Code event and per zsh command: append a trimmed `ActivityEvent` line to `~/Library/Application Support/KoffeeLid/activity.jsonl`. Never launches the app, always exits 0. |

The kernel mechanism: `PowerManager` opens an `IOPMrootDomain` user client and calls
`IOConnectCallScalarMethod(…, 12 /* kPMSetClamshellSleepState */, …)`. Everything else in the coordinator
exists to guarantee that flag is cleared again. See `docs/architecture.md` §"Kernel flag ownership" before
touching `arm`, `disarm`, `shutdown`, `start` or `reapplyFlag`.

## Non-negotiable invariants

1. **Idle means the flag is clear.** Any code path that returns the coordinator to `.idle` (disarm, quit,
   rails, crash recovery at launch) must have attempted `setLidSleepDisabled(false)` **and**
   `releaseSleepLock()` (`pmset disablesleep 0` survives reboots). Do not add an early return between
   setting the flag and updating `state`.
2. **Do not clear the flag on evidence you did not create.** Launch/quit clears are conditional (stale pid
   file, brightness-recovery file, `isArmed || flagClearPending || power.lidSleepDisabled`) because
   other lid-sleep utilities drive the same kernel flag. Keep them conditional.
3. **Scope process commands to our bundle.** Every `pgrep`/`pkill` targets `KoffeeLid.app/Contents/MacOS/`
   or pids from `~/Library/Application Support/KoffeeLid/koffeelid.pid`; never kill by bare process name.
4. **The installed app is the user's daily driver.** `AppleClamshellCausesSleep = No` in `ioreg` usually
   means it is armed — run `koffeelid status` before drawing conclusions. **Never quit or reinstall it
   without checking `koffeelid status` first**: `script/install.sh` refuses while it is armed (`FORCE=1`
   overrides); quitting an armed instance ends the user's live session and, with the lid closed, may sleep the
   Mac. Any other utility that sets the same kernel flag will fight the arm; quit it before testing.
5. **Main thread.** All collaborators call back on main; `LidAngleObserver.addConsumer/removeConsumer` are
   main-thread only; the sampler runs on its own queue (30 Hz at rest, 120 Hz while the lid moves, always
   delivering at 30 Hz) and hops to main before `onSample` (angle + the time that value was first seen).
6. **Every user-visible string goes through `L("literal key")`** and must exist in
   `App/Resources/Localizable.xcstrings` with an `fr` entry (an untranslated key is a build warning). No
   interpolation inside `L()`; use `String(format: L("… %d …"), …)`. App-name + version strings are
   intentionally not localized.
7. **Preferences** are UserDefaults-backed properties on `Preferences.shared` (`armWithOption`, `armWithShortcut`,
   `armWithCaffeinateShortcut`, `lidCloseSoundName`, `gestureModifier`, `effectParameters` JSON, …). Pages write
   prefs; the coordinator reacts in `preferenceChanged(_:)`. `Preferences.onChange` has exactly one
   subscriber (the coordinator) — do not overwrite it from UI code.
8. **Modes and arm semantics are fixed, not preferences.** `ArmMode` is Off / Armed / Armed + screen on
   (`mode` is the manual choice; `isArmed` ⇔ `state != .idle` ⇔ manual armed **or** auto-armed, invariant 11; caffeinate adds `PreventUserIdleDisplaySleep` + a 30 s user-activity tickle
   while the lid is open, via `PowerManager.keepDisplayOn/tickleUserActivity`). The lid gesture — Fn (Globe) +
   close by default, Option via `gestureModifier` — (`ArmSource.gesture`) arms **one close** and never changes
   a manual mode: the lid reopening disarms, and reopening by `gestureReverseCancelDegrees` or standing still
   for the effect's `settleDelay` before the lid shuts cancels the arm (`ReopenCancelWatch`) — stillness is
   ignored while the modifier is held, for both that cancel and the plane's return to flat. **The detector
   must never stay latched**: `LidProgressDriver` resets itself when the modifier is released after an arm, and
   the coordinator resets it on `arm`, `disarm` and every change of `gestureWanted`; Fn + close while armed from
   another source is visual confirmation (`effect.followLidFromHere()`, never a second arm) and must keep working
   after that session ends (`docs/gesture.md`). Every other
   source (menu, right-click, shortcuts, intents, URL, CLI) stays in its mode until changed. Transitions are
   `ModeCycle`: right-click cycles Off → Armed → Caffeinate → Off but goes straight to Off once an armed mode
   has stood ≥ 3 s; ⌃⌥⌘L targets Armed and ⌃⌥⌘K targets Caffeinate (same mode → Off, other mode → switch).
   The screen always locks on reopen. The two shortcuts are fixed combos (prefs keys exist, no recorder), each
   with its own on/off switch in Settings (`armWithShortcut`, `armWithCaffeinateShortcut`).
   **Fold geometry**: the inner screen stands upright at `gestureStartBelowDegrees` (Advanced › "Start below (with the
   lid gesture)", default 95°, 30–120°), so the plane shows `upright − lid angle` (1:1, nothing above it); a fold that
   must begin lower (the "except the lid gesture" gate, which `clamped()` keeps ≤ the gesture one; rebase; gesture under
   it) catches up with that curve over ≤ 30° of travel (`FoldGeometry`). **External display**: does not block; the mode stays and the kernel flag stays set, but darken / sound /
   effect / lock-on-reopen and the gesture stand by (`standingBy`) until it disconnects; a display
   appearing while the lid is closed locks immediately. **Low battery** (option on, on battery, ≤ threshold):
   hard no for every mode and source; on AC everything is allowed; unplugging below the threshold disarms.
   The in-place Armed ↔ Caffeinate switch now records `armSource = source` too, so a lid-gesture one-close
   arm switched in place (e.g. via ⌃⌥⌘K) becomes a manual arm and no longer disarms on lid open.
9. **One threshold.** The effect has no start threshold of its own: `gestureActivationDegrees` drives both the
   gesture and `EffectController.foldThresholdDegrees` (synced in `start()` and `preferenceChanged`).
10. **Diagnostics**: log through `DiagnosticLog.shared.log` (app) or `DiagnosticFileWriter` (watchdog);
   both lock `diagnostics.lock`. `Preferences.diagnosticsEnabled` (Advanced › App › Diagnostics log) silences
   the app's writer; check it before concluding a log is empty. Log lines are the primary debugging tool; keep the existing phrasing
   (`docs/manual-checks.md` greps for them).
11. **Two independent arms, ORed** (2026-09-12, evening). The manual mode (`mode`, what the user picked) and the
   auto level (`ActivityArmPolicy.isOn`, on while Claude Code or a command runs and through the hold-off after)
   never touch each other; the Mac is armed while either holds (`KoffeeLidController.autoArmed`, `applyAuto`).
   Manual Off (`releaseManual`: menu, right-click, shortcut, CLI, URL, intent, the end of a one-close gesture
   arm) sets `mode = .off` and keeps the session if the auto level is on (`armSource` becomes `.activity`); the
   auto level dropping keeps the session if the manual mode is armed. Only the rails (battery, thermal,
   external sleep, reset, quit) end everything, through `disarm`, which also `suspend`s the level until the
   running work stops and something starts again (`armFailed` does the same for a blocked arm). The manual mode
   decides *what* the arm is (caffeinate only from the manual side), the glyph shows manual first and the `auto`
   cup only for an auto-only arm, the menu checks `mode` and adds the greyed "Auto-armed while …" line while the
   level holds. The wait after the work ends is the longest hold-off among the kinds that ran during the stretch
   (`Preferences.activityHoldOffs`: 30 min after Claude Code so a remote user can prompt again, 1 min after a
   command; changing a hold-off moves a pending drop). The hold-off exists for a remote user whose connection
   would die with the Mac: local keyboard or mouse input after the work ended (`LocalInputMonitor`, HID idle
   time polled every 2 s while a countdown runs, `ActivityArmPolicy.userActive`) drops the level at once, log
   `auto-arm ended: local input during the hold-off`. "Disarm once finished" (`requestActivityDisarmOnce`)
   shortens that wait to a minute and releases the manual mode when the level drops. `koffeelid status` says
   `auto-armed (activity)` while the level holds an armed Mac, and `install.sh` refuses then too. Timings in
   `ActivityConstants` were sized from recorded Claude Code journals — retune only against evidence.

## Testing constraints on this machine

- Unit tests are hermetic. Everything hardware-facing (kernel flag, brightness, lock screen, HID sensor,
  capture, CoreAudio) is verified only via `docs/manual-checks.md` and log lines. The effect's *look* can be
  previewed on the CPU from `PlaneRemap` (`docs/development.md` § Tuning the effect's look).
- `swift test`, `xcodebuild` and anything that decodes HEIC or video fail inside Claude Code's sandbox
  (SwiftPM's cache under `~/Library`, system decoder services); run them with the sandbox off. The shader is
  compiled at runtime: syntax-check it with `xcrun metal` (`docs/development.md` § Environment) — a bad shader
  only shows up as `effect: no built-in display or Metal unavailable` at the next arm.
- A runtime smoke that is always safe: launch the Debug app, confirm `launched (pid …)` in the log, quit with
  `osascript -e 'tell application id "dev.rubens.koffeelid" to quit'`, confirm `clean termination`.
- Prefer the CLI (`koffeelid status|arm|off|…`) over `open "koffeelid://…"`. `status` is always safe; never send `off` while the user's lid is closed on an armed session.
- Launch with `--open-settings` (run the binary inside the bundle directly) to render the Settings window
  without clicking the status item.
- Screen Recording and Login Items approvals are per-bundle-path: the DerivedData build and the
  `/Applications` build are different apps to TCC/launchd.

## Conventions

- Releases for other people: `script/release.sh` (Developer ID export + notarization + staple → `dist/*.zip`,
  Wooflab team `75MADVD27T`); needs the one-time certificate and `notarytool` profile from
  `docs/development.md` § Known limitations. Dev builds stay Apple Development and only run on this Mac.
- Commit subjects use `feat|fix|build|docs(scope): …`. Commits in this repo end with
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and a `Claude-Session:` line. Push to `origin main`
  only when asked; tag releases `vX.Y.Z` (annotated) after bumping the three version locations above.
- Before quitting or reinstalling the app, run `koffeelid status` (or the bundle binary) and restore the mode the
  user was in afterwards (`koffeelid caffeinate` / `arm`); `install.sh` enforces the "off" check.
- Shell scripts are zsh (`${0:A:h:h}` for the repo root, `set -euo pipefail`, BSD userland).
- Sound assets are free to use (`App/Resources/Sounds/SoundEffects-LICENSE.txt`); no code was copied from
  jh3y/lid-plane (no license) — the effect math is re-derived in `PlaneRemap.swift`.

## Status and open items (2026-09-12, end of day)

- **v1.0.1 released (2026-09-13)**: version bumped in the three places, `dist/KoffeeLid-1.0.1.dmg` built from a
  clean Release build (UDZO, volume "KoffeeLid", app + Applications symlink; Apple-Development-signed, hardened,
  **no `get-task-allow`** — the security fix ships), tag `v1.0.1` pushed, GitHub release created with the DMG.
  It bundles the security-audit fixes and the `KOFFEELID_SKIP` doc. Still Apple-Development-signed, so the DMG
  runs only on this Mac; not notarized. The installed `/Applications` copy is still the old 1.0.0 build until a
  `script/install.sh` (needs `koffeelid off`, then restore the mode).
- **Security audit (2026-09-13), four fixes on `main`, not yet reinstalled**: from a full audit at the user's
  request (focus: the sudoers path). The sudoers rule itself is sound (`sudo -n` refuses anything but the two
  `pmset disablesleep 0|1`, verified live). Fixes: (1) `project.yml` sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS:
  NO` for Release — the Apple Development identity was injecting `com.apple.security.get-task-allow`, so a
  same-user process with a self-signed `cs.debugger` entitlement could take the app's task port and inject
  under its Screen Recording grant (reproduced during the audit; a clean Release build now strips it from all
  three binaries, Debug keeps it); (2) the admin-dialog install script uses absolute tool paths and stages the
  rule as a dotted temp file inside `/etc/sudoers.d` (no PATH/TMPDIR trust, no swap window); (3) the terminal
  one-liner writes `koffeelid.tmp` + `visudo -cf` + rename so a malformed rule never locks sudo out; (4)
  availability requires the rule file to exist, not just a yes from `sudo -n -l` (which says yes to anything an
  admin may run once any NOPASSWD rule exists). **The installed `/Applications` build still has the old
  `get-task-allow`** — fix 1 lands only on the next `script/install.sh` (needs `koffeelid off`, then restore the
  mode). Not release-version-bumped by request.
- **v1.0.0 is on `main` (one squashed commit, tagged 2026-09-13, `dist/KoffeeLid-1.0.0.dmg` built with the Apple Development identity) and installed** (`script/install.sh`, Wooflab team, last install 2026-09-12
  evening with the three review fixes, the four new cup glyphs and the grey cups in the menu; the user was put back
  in armed + screen on afterwards). Tests: 223.
  The DMG is not notarized (no Developer ID certificate yet), so it only runs on this Mac.
- **Three review fixes (2026-09-12, evening)**, from the full-project review, none hardware-checked by Claude
  (checklist items added under Kernel & power, Effect and Settings UI): Advanced › Reset now calls `disarm(reason:
  "reset")` directly, since `setMode(.off, source: .menu)` is ignored while auto-armed and the reset went on to
  delete the sudoers rule with the sleep lock still engaged; `EffectController.beginSession` re-checks that the
  session still owns its capture after the still's await before starting the stream, and `DesktopCapture` takes
  its `CaptureStartGate` token before the first await (a cancelled fold could leave an orphaned SCStream with the
  recording indicator lit until quit); the status item keeps its template image, so the orange warning tint on a
  failed flag clear can actually render. Still open from the review: Reset leaves coordinator caches (fold
  threshold, hold-offs) at their pre-reset values, the renderer releases a pixel buffer it keeps sampling, and the
  README's signing and onboarding claims are stale.
- **Charger-plug sleep fixed**: powerd owns the same kernel bit selector 12 sets and rewrites it on every
  charger plug (PowerChime's assertion), display hot-plug or desktop-mode change; the kernel then sleeps a
  closed armed Mac inside that write (`docs/platform-notes.md` § Kernel lid-sleep flag). Two layers:
  `handleExternalSleep` holds a "Clamshell Sleep" in dark wake instead of disarming (`SleepInterruptionPolicy`,
  `SleepOverrideGuard`), and `SleepLock` engages `pmset disablesleep 1` on every arm through `sudo -n` when
  the sudoers rule exists (set up from Settings › Permissions or onboarding via the admin dialog,
  `SleepLockSetupAction`; `script/install.sh` prints the terminal one-liner too). The user has set the rule up
  and torn it down several times while testing onboarding; on 2026-09-12 it was on all day (`koffeelid status`
  shows `sleep lock: on/off`, `install.sh` prints `sleep lock: sudoers rule present`).
  The hold path was not hardware-tested by Claude; the lock was seen engaged (`SleepDisabled 1`).
- **Lid effect reworked (2026-09-11, evening)**: "inner screen" geometry replaces "hold content angle"
  (`docs/architecture.md` § effect): the desktop stands upright at the hinge, the display row at `h` samples
  it at `h·cos(fold)^zoom`, so it grows from the hinge and is cropped at the top; it narrows toward the top
  with straight edges (half-width linear in `h`, top `1 + (1/cos(fold) − 1)·perspective` times narrower: the
  keystone `| |` → `/ \`, void beside it; a linear sampling factor bowed the sides, fixed from the user's video); blur is
  linear in the glass gap `h·sin(fold)`; `progressiveBlur` is gone (`blurStrength` 0 = off). Tunables in
  Advanced › Lid effect: Inner screen zoom (`zoomStrength`, default 80 %; 100 % = exact `1/cos`) and
  Perspective (`perspectiveStrength`, default 40 %; top narrowing `1 + 2(1 − cos fold)·p`, the `1/cos` form
  pinched the end of the fold into a spike); defaults are the user's tuned set (gesture start 95°, start below 75°, return to flat
  0.5 s, zoom 80 %, perspective 40 %, blur 0.15×, edge softness 100 %, shading 100 %); both sliders run 0…200 % at the user's request (200 % zoom = `1/cos²`). The fold is capped at
  `EffectController.maxFoldDegrees` = 80° (was a slider; the geometry needs cos > 0). Stored `effectParameters` from before fail to decode and fall back to defaults. Not
  hardware-checked by Claude. A Defaults › Reset row restores `EffectParameters.default` and rebuilds the page.
- **Soft edges and shading (2026-09-12)**: the inner screen now looks like Apple's foldable (the user's reference
  video): the two keystone sides melt into the black over `0.35·edgeSoftness·h·sin(fold)` display widths, the top
  row over `0.08·edgeSoftness·sin(fold)` display heights, and the picture darkens by `1 − 0.55·shading·h·sin(fold)`
  (`docs/architecture.md` § Soft edges and shading; `PlaneRemap.coverage/shade`, mirrored in the shader). Advanced ›
  Lid effect: Edge softness and Shading, 0…200 %, default 100 % (0 % = the old crisp cut / no darkening); constants
  chosen from a CPU render compared with the Apple frames (method in `docs/development.md` § Tuning the effect's
  look); the user then tuned the defaults on the real lid the same afternoon (gesture start 95°, perspective 40 %),
  so the installed look is theirs. The gesture's start angle
  (inner screen upright, was hardcoded 90°) is `gestureStartBelowDegrees`, Advanced › "Start below (with the lid
  gesture)", default 95°, 30–120°, never below the "except" one (`clamped()` raises it; the sliders push/stop at each other).
- **Fn softlock fixed (2026-09-11, evening)**: Fn + close went dead after a "gesture while armed from the
  shortcut/menu" followed by a disarm, until the next `arm()` (log 15:44:00Z → 15:51:44Z). `LidProgressDriver`
  stayed `activated` until `reset()`, which that path never called. Now it resets itself on modifier release;
  `disarm()` and every `gestureWanted` transition reset too; the cached `flagsChanged` monitor is gone (fresh
  `CGEventSource`/`NSEvent` reads); `followLidFromHere` keeps a running fold instead of snapping it flat.
  Full state table and post-mortem in `docs/gesture.md`. Not hardware-checked by Claude; the checklist has
  four regression checks. The one-close stall cancel and the plane's return to flat share `effect.settleDelay`
  (0.5 s) but ignore stillness while Fn is held (`held:`/`holding:` through `handleAngle`).
- **Fold smoothness (2026-09-11, evening)**: the sensor publishes only every ~100 ms (10 Hz, measured with
  `script/lid-sensor-rate.swift`), which made closes stop-and-go. `LidAngleObserver` polls at 120 Hz while
  the value changes (30 Hz at rest), still delivers at 30 Hz (gesture filters count samples) and stamps each
  sample with the time its value was first seen; `AngleSmoother` fits a line through 0.25 s of those change
  events, reads it in the past and low-passes. Advanced › Lid effect › **Responsiveness** (default 70 %) trades
  lag for smoothness: 0 % = read one sensor period back (~157 ms behind, no overshoot), 100 % = 40 ms back +
  up to 60 ms of prediction along the fitted line (~79 ms behind, ≤ 2.3° overshoot on an abrupt stop, more
  jitter on slow closes); `docs/architecture.md` § Smoothness has the table. Simulated in tests, not
  hardware-checked by Claude; the user found the 100 %-smooth version "smooth but laggy".
- **Team is Wooflab (`75MADVD27T`)**, the paid membership, since 2026-09-11. Dev builds sign with Apple
  Development (Gatekeeper rejects them elsewhere). `script/release.sh` (archive → developer-id export →
  notarize → staple → `dist/KoffeeLid-<version>.zip`) is written but untested: no Developer ID Application
  certificate or `koffeelid-notary` keychain profile exists yet (`docs/development.md` § Known limitations).
- **UI today**: no master switch (always enabled); modes are Off / Armed / Armed + screen on (« Activé +
  écran allumé »; code and CLI keep `caffeinate`); Settings page = App, Arm with, While armed, Permissions,
  Hooks; Advanced = tunables + Diagnostics log switch + Show onboarding again + Reset permissions and undo every
  change… (`resetEverything`, see `docs/architecture.md`); onboarding = pitch / Permissions / Hooks / All set,
  floating window; settings windows have a standard opaque title bar and are capped to the visible screen.
- **Resetting grants for a fresh onboarding** (what the reset button does, also by hand): `koffeelid off`;
  sudoers rule via the admin dialog; `tccutil reset ScreenCapture dev.rubens.koffeelid`; drop the app's entry
  from `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist`
  and `killall usernoted`; `defaults delete dev.rubens.koffeelid`. Login Items approval lives in macOS's BTM
  database per team id and has no per-app reset (`sfltool resetbtm` wipes every app's); after the team change
  the Wooflab-signed watchdog needs approving once.
- **CLI wrapper missing**: `/usr/local/bin` is root-owned; until the user runs the `sudo` one-liner
  `install.sh` prints, call `"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" <verb>`.
- **Apple Music blip report** (unreproduced): once, a lid close with the chime made a paused Music resume
  for a second. Logs at those closes show no MediaRemote/Music activity; a test proved neither `AVAudioPlayer`
  nor `NSSound` registers a Now Playing session. Remaining suspects: the output-device volume/mute writes of
  the forced-volume feature, or Music reacting to the clamshell event. If it recurs, check the time against
  `volume override:` lines and `log show` for Music/mediaremoted.
- **Lid-close sounds**: six clips the user supplied on 2026-09-11 (`blip-pop`, `bloop`, `chime-blip`, `enter`,
  `notification`, `tick`, `App/Resources/Sounds/close-sound-<name>.mp3`), free to use, no attribution
  (`SoundEffects-LICENSE.txt`). A stored `lidCloseSoundName` that no longer exists falls back to the first.
- **Effect over the menu bar**: the overlay panel sits at `.screenSaver` level so the black backdrop hides the
  menu bar during the fold. Whether macOS's purple screen-recording pill is also hidden is unverified.
- **Icon workflow (2026-09-12, evening: the user's four new cups)**: glyph and app icon come from the SVGs in
  `App/Resources/Glyphs` (`mug-off/-auto/-armed/-caffeinate.svg`, viewBox 325 × 244: one even-odd `cup` path
  whose extra sub-paths are the eyes, plus a `liquid` ellipse in every state but off). The shared cup and the
  three eye sub-paths are embedded verbatim in `MugShape.swift` (`MugShape.State` = off / auto / armed /
  caffeinate; the parser handles M L H V C A Z); after editing an SVG, copy the new `d` into the matching
  constant, keep `MugShape.box` equal to the cup bounds (2, 9.41, 320.75 × 224.31 today) and run
  `script/make_icon.sh` (app icon = the armed cup). Glyph size/offset live in `StatusItemController.mugImage`
  (22 pt wide, centred on the bar, drawn opaque). `docs/assets/menubar.png` is rendered from the four SVGs (2026-09-13); `docs/assets/lid-effect.gif` comes from the user's 2026-09-13 video.
- **Auto-arm on activity is live on this Mac** (2026-09-12 afternoon): both hooks and the zsh snippet are
  installed and the switch is on — `koffeelid status` reports `activity: 1 session working, 1 command` during a
  Claude Code session, and every fresh launch of the app while a session is working auto-arms immediately
  (`launched` → `armed (activity, armed)` → `auto-armed (activity)` in the log; seen twice after reinstalls, see
  `docs/development.md` § Daily loop for what "restore the mode" means then). Set up from Settings › Hooks (or the
  onboarding "Arm while you work" page) — one "Set up…" button each, "Set up" + Remove once done — either one
  turns on "While Claude Code or a terminal command is running" automatically (the CLI equivalents
  `install-hooks` / `shell-init zsh` still work). The checklist in `docs/manual-checks.md` §"Auto-arm on
  activity" has not been worked through item by item. **Reworked on 2026-09-12** after the per-hook "disarm when it finishes" rules
  felt weird: the auto-arm is now invisible in the menu bar (Off stays checked, only the header hints), cannot
  be ended from the menu bar or a shortcut, and ends on its own after a per-kind hold-off (Advanced: 30 min
  after Claude Code, 1 min after a command); the menu has one item, "Disarm once finished" (a manual arm ends a
  minute after the work is over, an auto-arm skips its long wait). No warning dialog. **Reworked again the same
  evening** after the user found it "plainly not working": with a Claude Code session and a wrapper command
  (`cswap`) running all day, the aggregate level never fell, so the old rising-edge rule could never re-arm
  after a manual Off. Now the auto level and the manual mode are independent and ORed (invariant 11); the
  policy tests were rewritten for it. Not hardware-checked by Claude; the checklist covers it. The version bump
  went straight to 1.0.0 on 2026-09-13.

