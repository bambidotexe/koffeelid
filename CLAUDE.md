# KoffeeLid — CLAUDE.md

The operating manual for an agent working in this tree. Read it whole before the first edit.

## What this project is

KoffeeLid (bundle id `dev.rubens.koffeelid`) is a macOS menu-bar app that keeps a MacBook running with the lid
closed. Three manual modes: **Off**, **Armed**, **Armed + screen on** (`ArmMode.caffeinate` in code and CLI,
« Activé + écran allumé » in French). It also arms itself while Claude Code or a terminal command is working
(Claude Code hooks and a zsh snippet feed an activity journal; the app reads it), and a lid gesture (Fn, or
Option, held while the lid closes) arms for one close. While armed, the built-in panel darkens when the lid
shuts, a lid-close sound plays (at a forced volume if wanted), a closing-only Metal effect shows the desktop
staying upright behind the glass, and the screen locks when the lid reopens. Safety rails end an arm: low
battery, thermal pressure, a sleep started by something else, a reset. A `koffeelid` command line,
`koffeelid://` URLs and App Intents drive the same modes. It looks for a newer release on GitHub at launch and
once a week, announces one with a notification, and installs it on a click: a window fetches and checks the
release while the app runs, and "Install and Relaunch" swaps the bundle once the app has quit cleanly.

The mechanism is one kernel scalar on `IOPMrootDomain` (selector 12, `kPMSetClamshellSleepState`), plus a
`pmset disablesleep` **sleep lock** through a sudoers rule so that macOS cannot start a clamshell sleep behind
it. Everything else in the coordinator exists to guarantee that flag is cleared again when the app is not armed.

Swift 5 language mode. Two SwiftPM libraries plus an XcodeGen-generated Xcode project for the app and its two
helper tools. Deployment target macOS 15; built and run on macOS 27.0 (26A428) with Xcode 27.0, on one MacBook
Pro. A personal app by and for one user: English and French, no licensing, updates from GitHub releases (the
check is automatic, the fetch and the install each need a click). Releases are Apple-Development-signed DMGs
that run on this Mac only.

Repo `~/Projects/koffeelid`, GitHub `git@github.com:bambidotexe/koffeelid.git` (`origin`, branch `main`, SSH
as `bambidotexe`, `gh` logged in). **The installed copy `/Applications/KoffeeLid.app` is the owner's daily
driver and is usually armed while you work** (see Rules). Its data lives in
`~/Library/Application Support/KoffeeLid/`: `diagnostics.log`, `activity.jsonl`, `koffeelid.pid`, `sleep-lock`.

## Read first

| File | What it is |
|---|---|
| `docs/README.md` | The index: which document answers which question, and how to start a session. |
| `docs/functional.md` | **The authority on behaviour.** Every mode, arming path and rail, the gesture, the effect, the UI, every setting with its default, the permissions, the non-goals, the open questions. Kept in sync with the code by the rule below. |
| `docs/architecture.md` | The five targets, the coordinator's state machine and kernel-flag ownership, who watches what, the gesture, the effect, the activity pipeline, persistence, the privilege boundary, threading, build. |
| `docs/macOS.md` | The platform facts the app relies on: the kernel flag and powerd, the sleep lock, assertions, the lid-angle sensor, modifier keys, displays, capture, TCC, Claude Code's hooks and registry, zsh. Read it before designing on a platform assumption. |
| `docs/pitfalls.md` | Traps already hit, each with symptom, cause, what the code does and what not to do. **Read the matching section before changing sleep, lid, gesture, effect, watchdog, privilege or hook code.** |
| `docs/development.md` | Build, install and debug loop; how to add a preference, a string, a control, a permission row, a verb, an effect tunable, a collaborator; icons; the release checklist; known limitations. |
| `docs/manual-checks.md` | The hardware checklist: the only verification of everything IOKit, Metal, CoreAudio and TCC. Unit tests cannot reach those paths; the log lines it greps for are part of the contract. |
| `docs/_audit.md`, `docs/_coverage.md` | Records of the September 2026 audits: what was read, verified and decided. History, not rules. |

## Changing behaviour — the workflow

Every change to what the app does follows these steps, in this order. A change that skips one is not done.

1. **Find the rule.** Read the section of `docs/functional.md` that governs the behaviour, then the matching
   section of `docs/pitfalls.md`. What `functional.md` says is what the app is supposed to do today.
2. **Check for a conflict.** If the request contradicts a written rule — a mode semantic, a rail, a default, an
   order, a "never" in this file or in `functional.md` — **stop and ask the owner whether that rule is
   overruled, quoting it.** Do not guess, do not implement both, do not add an exception beside the old rule.
   A request that adds behaviour no rule covers needs no question. If the owner reaffirms the request, that is
   the answer: replace the rule.
3. **Change the code in the layer that owns it.** `KoffeeLidCore` for anything decidable without asking macOS
   (a value type with injected time, tested first); `LidPlaneKit` for the effect; the app for wiring,
   collaborators and UI; the hook or watchdog tool for their own verbs. A comment states the present rule,
   never the history of the change.
4. **Update `docs/functional.md` in the same commit.** Replace the old rule with the new one; never keep an
   outdated rule, not as a note, not as "it used to be". A structural change updates `docs/architecture.md`; a
   new platform fact `docs/macOS.md`; a trap `docs/pitfalls.md`; a behaviour only hardware can show gets a line
   in `docs/manual-checks.md`; a new setting is a row in `functional.md` § Settings and defaults; every new
   user-visible string gets its `fr` entry.
5. **Verify.** `swift test` green (count the per-case `passed` lines), the Debug `xcodebuild` warning-free,
   the string catalog covering every `L("…")` key. Add or amend a unit test for any pure rule.
6. **Commit per task**, `feat|fix|build|docs(scope): …`, staged by path, with the attribution trailers from the
   session's system reminder. Push, tag and release only when asked.

The sync rule in one sentence: **the code and `docs/functional.md` describe the same app at every commit,
and a request beats a written rule only after the owner has said so.**

### Where a change usually lands

Paths are relative to `Sources/KoffeeLidCore` (`Core/`), `Sources/LidPlaneKit` (`LidPlaneKit/`) and
`App/Sources` (`App/`).

| To change… | Edit | Then document in |
|---|---|---|
| a mode, an arming path, a transition | `Core/ArmMode.swift` (`ModeCycle`), `Core/ArmingPolicy.swift`; `App/KoffeeLidController.swift` (`setMode`, `arm`, `disarm`, `perform`) | `functional.md` § Modes and arming; `architecture.md` § The coordinator |
| the kernel flag, the sleep lock, assertions | `App/PowerManager.swift`, `App/SleepLock.swift`, `Core/SleepInterruptionPolicy.swift` (`SleepOverrideGuard`, `SleepLockSetup`); `KoffeeLidController.reapplyFlag` | `architecture.md` § The coordinator (kernel-flag ownership); `macOS.md` § Kernel lid-sleep flag, § Sleep lock; `pitfalls.md` § Sleep and the kernel flag |
| a safety rail (battery, thermal, external sleep) | `Core/LowBatteryPolicy.swift`; `App/BatteryMonitor.swift`, `ThermalMonitor.swift`, `SleepInterruptionMonitor.swift`; `KoffeeLidController.handleBattery`, `handleThermal`, `handleExternalSleep` | `functional.md` § Power and safety rails |
| lid closed / lid open, darkening, the reopen lock | `App/LidObserver.swift`, `InternalDisplayBrightnessController.swift`, `LidReopenLockController.swift`, `ScreenLockObserver.swift`; `Core/LidStateTransitionFilter.swift`, `ReopenLockDecision.swift`, `LidReopenLockRetryPolicy.swift`; `KoffeeLidController.handleLid` | `functional.md` § Lid closed, lid open; `pitfalls.md` § Displays and the lock |
| the external-display stand-by | `App/DisplayTopologyMonitor.swift`; `KoffeeLidController.handleDisplays`, `standingBy` | `functional.md` § External display |
| the lid gesture | `Core/LidProgressDriver.swift`, `OptionGateFilter.swift`, `FnKeyReading.swift`, `ReopenCancelWatch.swift`, `GestureArmHold.swift`; `App/GestureController.swift`, `BuiltInFnKeyReader.swift`; `KoffeeLidController.gestureWanted` | `functional.md` § Modes and arming (the gesture); `architecture.md` § The lid gesture; `macOS.md` § Modifier keys; `pitfalls.md` § Lid, sensor, gesture, effect |
| the lid-angle sensor and its sampling | `App/LidAngleSensor.swift`, `LidAngleObserver.swift`; `Core/AngleSampleFilter.swift`, `AngleSmoother.swift` | `macOS.md` § Lid-angle sensor; `architecture.md` § Threading |
| the lid effect (fold, capture, shader) | `LidPlaneKit/EffectController.swift`, `DesktopCapture.swift`, `CaptureStartGate.swift`, `PlaneRenderer.swift`, `PlaneShader.swift`, `PlaneRemap.swift` (the tested reference maths), `EffectOverlayPanel.swift`; `Core/FoldTracker.swift`, `FoldGeometry.swift`, `EffectParameters.swift` | `functional.md` § The lid effect; `architecture.md` § The lid effect; `development.md` § How to add things (an effect tunable) |
| the close sound, the volume override | `App/LidCloseSoundPlayer.swift`, `OutputVolumeOverride.swift`; `Core/VolumeOverridePolicy.swift`; `App/Resources/Sounds` | `functional.md` § Lid closed, lid open; `macOS.md` § Sounds |
| auto-arm on activity | `Core/ActivityConstants.swift`, `ActivityEvent.swift`, `ActivitySessionStore.swift`, `ActivityJobStore.swift`, `ActivityArmPolicy.swift`, `ActivityTrim.swift`, `ClaudeRegistryRecord.swift`, `ProcWalk.swift`; `App/ActivityMonitor.swift`, `ActivityJournalTailer.swift`, `ActivityProcessWatcher.swift`, `ClaudeProcessRegistry.swift`, `LocalInputMonitor.swift`; `KoffeeLidController.applyAuto` | `functional.md` § Modes and arming (auto-arm); `architecture.md` § Auto-arm on activity; `macOS.md` § Claude Code; `pitfalls.md` § Claude Code hooks and the shell |
| the hooks, the zsh snippet, the hook binary | `Hook/Sources/main.swift`; `Core/HookConfig.swift`, `HookSettingsFile.swift`, `ShellInit.swift`, `ActivityJournalWriter.swift`; `App/HookInstaller.swift`, `App/UI/Hooks.swift` (`HookCatalog`) | the same, plus `macOS.md` § zsh |
| the CLI, `koffeelid://` URLs, App Intents | `App/main.swift`, `App/CommandServer.swift` (`CommandLineClient`), `Core/DeepLink.swift`, `App/Intents/KoffeeLidIntents.swift`; `KoffeeLidController.perform(_:source:)` | `functional.md` § User interface; `development.md` § How to add things (a CLI / URL verb) |
| the menu, the status item, the menu-bar glyph | `App/StatusItemController.swift`, `MugShape.swift`, `App/Resources/Glyphs` | `functional.md` § User interface; `development.md` § Icons |
| the app icon | `App/Resources/AppIcon.icon` (Icon Composer document), its `type: file` source entry in `project.yml` | `development.md` § Icons; `architecture.md` § Build, signing, entitlements |
| Settings (start with the `building-settings-pages` skill) | `App/UI/SettingsWindow.swift` (pages, toolbar, height), `SettingsKit.swift` (the kit and every number), `SettingsModel.swift` (bindings, polled states), `Settings…Page.swift` (one per page); `Core/SettingsStatus.swift` (a state's colour) | `functional.md` § User interface, § Settings and defaults; `development.md` § How to add things (a settings control); the skill, if a rule of the window changes |
| onboarding | `App/UI/OnboardingWindowController.swift`, `ControlActionHandler.swift` | `functional.md` § User interface |
| a preference and its default | `App/Preferences.swift`; `KoffeeLidController.preferenceChanged(_:)` | `functional.md` § Settings and defaults |
| a user-visible string | `App/Resources/Localizable.xcstrings`, edited in place, with its `fr` entry | `development.md` § How to add things (a user-visible string) |
| a permission row, the sudoers setup, Reset | `App/UI/Permissions.swift` (`PermissionCatalog`), `Core/SettingsStatus.swift` (`SettingsGrant`), `App/UI/SettingsSystemPage.swift`, `App/UI/SleepLockSetupAction.swift`; `KoffeeLidController.resetEverything` | `functional.md` § Permissions and what breaks without them; `macOS.md` § Permissions and how each is reset |
| a notification | `App/NotificationsController.swift` and the call site | the section of the behaviour that posts it |
| the shortcuts | `App/HotKeyController.swift` | `functional.md` § User interface |
| the watchdog, crash recovery, the pid file | `Watchdog/Sources/main.swift`; `App/RelaunchAgentController.swift`; `Core/CrashLoopGuard.swift`, `PidFileRecord.swift`, `RelaunchHistoryStore.swift`, `DiagnosticFileWriter.swift` | `architecture.md` § Watchdog contract; `macOS.md` § Login items and the watchdog; `pitfalls.md` § Watchdog and launch |
| diagnostics and log lines | `App/DiagnosticLog.swift`, `Core/DiagnosticLine.swift` | `docs/manual-checks.md` greps for the phrasing: keep it |
| updates: the check, its schedule, the notification | `Core/UpdateCheck.swift` (`ReleaseVersion`, `LatestRelease`, `UpdateCheck`), `Core/UpdateSchedule.swift`, `Core/UpdatePanel.swift` (the Updates group: mark, button, what a press starts); `App/UpdateController.swift` (the one owner), `App/UpdateChecker.swift`, `App/NotificationsController.swift`; the Updates group of `App/UI/SettingsGeneralPage.swift` | `functional.md` § Updates; `architecture.md` § Updates |
| updates: the window, the fetch, making it ready | `Core/UpdateSession.swift`, `Core/StagedUpdateCheck.swift`; `App/UI/UpdateWindow.swift`, `App/UpdateChecker.swift` (`UpdateDownload`), `App/UpdateStager.swift`, `App/CodeSignature.swift` | the same, plus `macOS.md` § Updates |
| updates: Install and Relaunch | `Core/UpdateInstallScript.swift` (the helper's text, `UpdateInstallPlan`, `UpdateResult`), `Core/DetachedProcess.swift`; `App/UpdateInstaller.swift`, `UpdateController.installAndRelaunch`, `KoffeeLidController.quitWouldSleepTheMac` | the same, plus `pitfalls.md` § Updates and `manual-checks.md` § Updates. **Read `pitfalls.md` § Updates before touching the order of an install** |
| build, install, release | `project.yml` (never the xcodeproj), `script/bootstrap.sh`, `build.sh`, `install.sh`, `run.sh`, `release.sh`, `ExportOptions.plist`; the version in its three places (Commands) | `development.md` § Release checklist; `architecture.md` § Build, signing, entitlements |

## Commands

```bash
swift test                                            # KoffeeLidCore + LidPlaneKit unit tests (337); needs the Claude Code sandbox off, like xcodebuild
swift test --filter LidProgressDriverTests            # one test class
swift test --filter LidProgressDriverTests/testArmsAfterActivationDegreesWithOption   # one test
swift build                                           # libraries only; the app needs Xcode (below)

script/bootstrap.sh                                   # xcodegen generate (run after adding/removing App, Hook or Watchdog files)
xcodebuild -project KoffeeLid.xcodeproj -scheme KoffeeLid -configuration Debug \
  -derivedDataPath DerivedData build 2>&1 | grep -E 'error|warning:|BUILD'   # Debug app build
script/build.sh [Release|Debug]                       # same, prints the .app path last
script/install.sh                                     # Release build → /Applications/KoffeeLid.app; REFUSES while the app is armed (FORCE=1 overrides)
script/run.sh                                         # install + launch + tail the diagnostics log (never returns)

"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" status   # CLI: arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings | install-hooks | uninstall-hooks | shell-init zsh
tail -f "$HOME/Library/Application Support/KoffeeLid/diagnostics.log"   # the primary debugging tool
/usr/bin/log show --last 10m --predicate 'process == "powerd"'           # the unified log; `log` alone is a shell function here
```

- The CLI is the app binary itself (`main.swift` forwards the verb to the running instance over distributed
  notifications, launching it if needed, and exits). `script/install.sh` writes a `/usr/local/bin/koffeelid`
  wrapper when that directory is writable; otherwise it prints the `sudo` one-liner.
- `KoffeeLid.xcodeproj`, `DerivedData/` and `.build/` are generated and git-ignored; edit `project.yml`, never
  the xcodeproj. If `xcodebuild` prints "Stale file … outside of the allowed root paths" or `swift test` fails
  on a module-cache path, the repo folder moved: `rm -rf DerivedData .build` and rebuild.
- The version lives in three places that must agree: `App/Info.plist` `CFBundleShortVersionString` (bump
  `CFBundleVersion` with it), `KoffeeLidCore.version` (`Sources/KoffeeLidCore/KoffeeLidCore.swift`) and its
  assertion in `Tests/KoffeeLidCoreTests/SmokeTests.swift`; the README test badge is a static shields.io URL.
- App targets only build with `xcodebuild` (App Intents metadata, String Catalog, asset catalog). `swift build`
  covers `Sources/` only.
- Treat compiler warnings as failures; the tree is warning-free. A `warning:` line from
  `appintentsmetadataprocessor` is not one: that Debug build wrote no App Intents metadata, the next relink does
  (`docs/pitfalls.md` § Working on this Mac). No linter is configured.
- XCTest's summary line undercounts here; count the per-case `passed` lines
  (`swift test 2>&1 | grep -E "^Test Case '.*' passed" | sort -u | wc -l`).
- A release: bump the three version locations, commit `build: release X.Y.Z`, `git tag -a vX.Y.Z -m "KoffeeLid
  X.Y.Z"`, `script/build.sh Release`, a UDZO DMG holding `KoffeeLid.app` and an `Applications` symlink in
  `dist/KoffeeLid-X.Y.Z.dmg`, `git push origin main vX.Y.Z`, `gh release create vX.Y.Z dist/… --title
  "KoffeeLid X.Y.Z" --notes-file …`. The notes end with the sentence that the build is Apple-Development-signed
  and not notarized. `script/release.sh` (Developer ID + notarization) needs a certificate and a `notarytool`
  profile this Mac does not have.

## Architecture in one screen

Five targets, dependency direction strictly downward. Full version in `docs/architecture.md`.

| Target | Kind | Depends on | Contents |
|---|---|---|---|
| `KoffeeLidCore` (`Sources/KoffeeLidCore`) | SwiftPM library, Foundation only | — | Every policy/state machine as a value type with injected time: `ArmMode`/`ModeCycle`, `ArmingPolicy`, `LidProgressDriver`, `OptionGateFilter`, `FnKeyReading`, `AngleSampleFilter`, `FoldTracker`, `AngleSmoother`, `FoldGeometry`, `ReopenCancelWatch`, `ReopenLockDecision`, `GestureArmHold`, `EffectParameters`, `VolumeOverridePolicy`, `SleepInterruptionPolicy`/`SleepOverrideGuard`/`SleepLockSetup`, `CrashLoopGuard`, `PidFileRecord`/`AppSupport`, `DiagnosticFileWriter`, `DeepLink`, the update feature's `ReleaseVersion`/`LatestRelease`/`UpdateCheck`/`UpdateSchedule`/`UpdatePanel`/`UpdateSession`/`StagedUpdateCheck`/`UpdateInstallScript`/`DetachedProcess`/`UpdateResume`, `SettingsStatus`, the activity feature's `ActivityConstants`/`ActivityEvent`/`ActivityTrim`/`ActivitySessionStore`/`ActivityJobStore`/`ActivityArmPolicy`/`ClaudeRegistryRecord`/`HookConfig`/`HookSettingsFile`/`ShellInit`/`ProcWalk`. **All logic tests live against it.** |
| `LidPlaneKit` (`Sources/LidPlaneKit`) | SwiftPM library | Core | The lid-close effect: `EffectController` turns lid angles into a fold (`FoldTracker`, closing only, threshold-gated) and runs a capture session only while folded: `DesktopCapture` (ScreenCaptureKit) → `PlaneRenderer` (Metal, shader in `PlaneShader.swift`; `PlaneRemap.swift` is the same maths in Swift, the tested reference) inside `EffectOverlayPanel`. |
| `KoffeeLid` (`App/Sources`) | Xcode app target | Core, LidPlaneKit | `KoffeeLidController` is the **only** object that mutates arming state (`setMode(_:source:)` is the entry point; `perform(_:source:)` runs CLI/URL verbs); every other file is a collaborator that reports events to it via closures. `HookInstaller` is a stateless helper used by the CLI client and the Settings window; `UpdateController` owns the update feature (the checks, the notification, the update window, Install and Relaunch) and never touches arming state: it quits the app through `NSApp.terminate`. UI under `App/Sources/UI`: the Settings window is an AppKit toolbar window (`SettingsWindow`) hosting six SwiftUI pages built only from the kit in `SettingsKit.swift`, sharing one `SettingsModel`; the four-page onboarding is programmatic AppKit; `PermissionCatalog` and `HookCatalog` are the single lists of grants and hooks, read by both. |
| `KoffeeLidWatchdog` (`Watchdog/Sources/main.swift`) | Xcode tool, embedded in the app | Core | LaunchAgent that relaunches the app after an unclean exit (pid file present) and stands down otherwise. |
| `KoffeeLidHook` (`Hook/Sources/main.swift`) | Xcode tool, embedded in the app | Core | `hook` and `job begin\|end` verbs, run once per Claude Code event and per zsh command: append a trimmed `ActivityEvent` line to `~/Library/Application Support/KoffeeLid/activity.jsonl`. Never launches the app, always exits 0. |

The kernel mechanism: `PowerManager` opens an `IOPMrootDomain` user client and calls
`IOConnectCallScalarMethod(…, 12 /* kPMSetClamshellSleepState */, …)`. See `docs/architecture.md`
§ The coordinator before touching `arm`, `disarm`, `shutdown`, `start` or `reapplyFlag`.

## Rules

### Working in this tree

- **`docs/functional.md` is kept in sync with every behaviour change, in the same commit, and never carries an
  outdated rule.** A rule the owner has overruled is replaced, not annotated. "It was like that before" is not a
  sentence that belongs in any document or comment in this repo; history lives in git and, for traps only, in
  `docs/pitfalls.md`.
- **A request that conflicts with a written rule is a question, not a change.** Quote the rule, ask whether it
  is overruled, and only then implement. If the owner reaffirms the request, that is the answer: replace the rule.
- **The installed app is the owner's daily driver.** `AppleClamshellCausesSleep = No` in `ioreg` usually
  means it is armed — run `koffeelid status` before drawing conclusions. **Never quit or reinstall it without
  checking `koffeelid status` first**: `script/install.sh` refuses while it is armed or auto-armed (`FORCE=1`
  overrides); quitting an armed instance ends the owner's live session and, with the lid closed, may sleep the
  Mac. Never send `off` while the lid is closed on an armed session. Restore the mode the owner was in
  afterwards (`koffeelid caffeinate` / `arm`). Any other utility that sets the same kernel flag will fight the
  arm; quit it before testing.
- **Any work on the Settings window starts with the `building-settings-pages` skill**
  (`.claude/skills/building-settings-pages/SKILL.md`): adding, moving, renaming or rewording a setting, a
  status, a group, a page or any sentence the window shows. It holds the window's structure, its numbers and
  how its words are written.
- **Every user-visible string goes through `L("literal key")`** and must exist in
  `App/Resources/Localizable.xcstrings` with an `fr` entry (an untranslated key is a build warning). No
  interpolation inside `L()`; use `String(format: L("… %d …"), …)`. App Intents strings are
  `LocalizedStringResource` literals in the same catalog. App-name + version strings are not localized. Edit
  the catalog in place; never load and re-serialise it.
- **Comments state the present.** A comment records a rule, an invariant, a measurement or a platform
  constraint; no dates, task numbers or accounts of what the code replaced. Docs describe the present system
  only, in the present tense.
- **Ask before any change to arming behaviour, to TCC grants or to privilege** (sudoers, login items): those
  are the owner's decisions, and the wrong one sleeps or unlocks a closed Mac.
- Compiler warnings are failures. Unit tests are hermetic and live against Core; a pure rule gets its test
  first. Anything hardware-facing gets a line in `docs/manual-checks.md` and a log line to grep for.
- Diagnostics go through `DiagnosticLog.shared.log` (app) or `DiagnosticFileWriter` (watchdog); both lock
  `diagnostics.lock`. `Preferences.diagnosticsEnabled` silences the app's writer; check it before concluding a
  log is empty. Keep the existing phrasing of log lines (`docs/manual-checks.md` greps for them).
- Shell scripts are zsh (`${0:A:h:h}` for the repo root, `set -euo pipefail`, BSD userland). `rg` is not
  installed; `log` is a shell function (use `/usr/bin/log`).
- Subagents run on Sonnet by default, with an explicit `model`, and only for a slice with a written brief;
  the parent reviews the diff, re-runs the tests and the warning check itself before committing.
- Commit per task, `feat|fix|build|docs(scope): …`, ending with `Co-Authored-By: Claude Fable 5.1
  <noreply@anthropic.com>` and a `Claude-Session:` line. **Stage by path, never `git add -A`.** Push to
  `origin main`, tag and release only when asked. Sound assets are free to use
  (`App/Resources/Sounds/SoundEffects-LICENSE.txt`); the effect maths is derived in `PlaneRemap.swift`.

### Non-negotiable invariants of the app

1. **Idle means the flag is clear.** Any code path that returns the coordinator to `.idle` (disarm, quit,
   rails, crash recovery at launch) must have attempted `setLidSleepDisabled(false)` **and**
   `releaseSleepLock()` (`pmset disablesleep 0` survives reboots). Do not add an early return between
   setting the flag and updating `state`.
2. **Do not clear the flag on evidence you did not create.** Launch/quit clears are conditional (stale pid
   file, brightness-recovery file, `isArmed || flagClearPending || power.lidSleepDisabled`) because other
   lid-sleep utilities drive the same kernel flag. Keep them conditional.
3. **Scope process commands to our bundle.** Every `pgrep`/`pkill` targets `KoffeeLid.app/Contents/MacOS/`
   or pids from `~/Library/Application Support/KoffeeLid/koffeelid.pid`; never kill by bare process name.
4. **Main thread.** All collaborators call back on main; `LidAngleObserver.addConsumer/removeConsumer` are
   main-thread only; the sampler runs on its own queue (30 Hz at rest, 120 Hz while the lid moves, always
   delivering at 30 Hz, changed value or not) and hops to main before `onSample`.
5. **Preferences** are UserDefaults-backed properties on `Preferences.shared`. Pages write prefs; the
   coordinator reacts in `preferenceChanged(_:)`. `Preferences.onChange` has exactly one subscriber (the
   coordinator) — do not overwrite it from UI code.
6. **Modes and arm semantics are fixed, not preferences.** `mode` is the manual choice; `isArmed` ⇔
   `state != .idle` ⇔ manual armed **or** auto level on. The lid gesture (`ArmSource.gesture`) arms **one
   close** and never changes a manual mode: before the lid shuts it is cancelled by reopening
   (`gestureReverseCancelDegrees`) or by stillness (`settleDelay`, `ReopenCancelWatch`); after the lid has shut
   it is held across the lid opening and ends when the user logs back in (`GestureArmHold`; it falls back to
   ending at the reopen if no lock ever takes; while held the closes play the sound but no effect). Stillness is
   ignored while the modifier is physically held, for that cancel and for the plane's return to flat.
   Every other source stays in its mode until changed; transitions are `ModeCycle`. The in-place
   Armed ↔ Armed + screen on switch records `armSource = source`, so a one-close arm switched in place
   becomes a manual arm. The screen always locks on reopen. The two shortcuts are fixed combos, each with its
   own switch. **External display**: does not block; the mode and the kernel flag stay, but darken / sound /
   effect / lock-on-reopen and the gesture stand by (`standingBy`). **Low battery** (option on, on battery,
   ≤ threshold): hard no for every mode and source; unplugging below the threshold disarms.
7. **The gesture detector never stays latched, and the modifier read is truthful.** `LidProgressDriver` resets
   itself when the modifier is released after an arm; the coordinator resets it on `arm`, `disarm` and every
   change of `gestureWanted`. Fn + close while armed from another source is visual confirmation
   (`effect.followLidFromHere()`, never a second arm). The modifier is read fresh on every sample, nothing
   cached, and the Fn flag only counts without the numeric-pad flag and with virtual key 63 physically down
   (`FnKeyReading`, `CGEventSource.keyState`: arrow keys, F1–F12 and an external keyboard's navigation keys
   set the Fn flag too); with the Input Monitoring grant the built-in keyboard's own Fn key is read through HID
   (`BuiltInFnKeyReader`) and required as well, so an external keyboard's Fn never arms. The effect's return to
   flat has no timer behind it; it depends on samples arriving and on `holding` being true only while a key is
   really down (`docs/pitfalls.md`).
8. **One threshold.** The effect has no start threshold of its own: `gestureActivationDegrees` drives both the
   gesture and `EffectController.foldThresholdDegrees` (synced in `start()` and `preferenceChanged`).
9. **Two independent arms, ORed.** The manual mode (`mode`) and the auto level (`ActivityArmPolicy.isOn`)
   never touch each other; the Mac is armed while either holds (`autoArmed`, `applyAuto`). Manual Off
   (`releaseManual`) sets `mode = .off` and keeps the session if the auto level is on (`armSource` becomes
   `.activity`); the auto level dropping keeps the session if the manual mode is armed. Only the rails
   (battery, thermal, external sleep, reset, quit) end everything, through `disarm`, which also `suspend`s the
   level until the running work stops and something starts again (`armFailed` does the same for a blocked
   arm). Caffeinate comes only from the manual side. The hold-off after the work ends is the longest among
   the kinds that ran; local keyboard or mouse input during it drops the level at once; "Disarm once
   finished" shortens it to a minute and releases the manual mode too. Timings in `ActivityConstants` were
   sized from recorded Claude Code sessions — retune only against evidence.
10. **An update never installs by itself, and never leaves a closed Mac armed behind a dead app.** The automatic
    check only announces; the fetch and the install each need a click. Everything that can refuse an update runs
    while the app is up. The install leaves through `NSApp.terminate`, so `shutdown()` clears the flag and the
    sleep lock (invariant 1): never `exit()` or a kill for an update. The helper touches nothing until the pid is
    gone, and the previous bundle is kept until the new version is seen running. The quit leaves the manual mode
    in `update-resume`, and the new version goes back to it through `setMode` if it starts within 2 min
    (`UpdateResume`); nothing else may arm at launch. Install and Relaunch is refused
    while quitting would sleep the Mac (`quitWouldSleepTheMac`: armed, lid closed, no external display).
    `script/install.sh` stays the way to install a build from this tree.

## Testing constraints on this machine

- Unit tests are hermetic. Everything hardware-facing (kernel flag, brightness, lock screen, HID sensor,
  modifier flags, capture, CoreAudio, TCC, the network) is verified only via `docs/manual-checks.md` and log
  lines.
- `swift test`, `xcodebuild` and anything that decodes HEIC or video fail inside Claude Code's sandbox; run
  them with the sandbox off. The shader is compiled at runtime: syntax-check it with `xcrun metal`
  (`docs/development.md` § Environment).
- A runtime smoke that is always safe: launch the Debug app with `KOFFEELID_DISABLE_ACTIVITY=1`, confirm
  `launched (pid …)` in the log, quit with `osascript -e 'tell application id "dev.rubens.koffeelid" to quit'`,
  confirm `clean termination`. While the installed app runs, a second instance exits at once.
- Prefer the CLI (`koffeelid status|arm|off|…`) over `open "koffeelid://…"`. `status` is always safe; never
  send `off` while the owner's lid is closed on an armed session.
- Launch with `--open-settings` (run the binary inside the bundle directly) to render the Settings window
  without clicking the status item.
- Screen Recording, Input Monitoring and Login Items approvals are per bundle path and per team id: the
  DerivedData build and the `/Applications` build are different apps to TCC and launchd.

## Traps

`docs/pitfalls.md` is the full list. The five that cost the most time:

1. **powerd rewrites the kernel flag under you.** Selector 12 sets the same bit powerd owns; a charger plug, a
   display hot-plug or leaving desktop mode can bring the mask to 0 and start a clamshell sleep inside the same
   call. The sleep lock is what actually holds a closed Mac; `reapplyFlag` is the second line.
2. **`AppleClamshellCausesSleep` lies for a while.** It is refreshed only by the kernel's own clamshell
   notifications, never by a selector-12 write. `koffeelid status`, the log and `pmset -g assertions` are the
   reliable views.
3. **The Fn flag is not the Fn key.** Arrow keys, F1–F12 and an external keyboard's navigation keys raise the
   secondary-Fn flag too; a modifier read that trusts the flag arms on a plain lid adjustment and keeps the
   effect from settling. Key 63, and with Input Monitoring the built-in keyboard's HID element, are the truth.
4. **A display that vanishes behind a closed lid is reported late**, about 130 ms after the lid-open
   notification, so a reopen decision on a cached topology unlocks the session. The list is re-read at lid
   open and a skipped lock stays pending for 2 s.
5. **Hooks are not a complete signal.** Esc and Ctrl-C fire no hook, `SubagentStop` is often missing,
   `idle_prompt` is a timer, a dialog can be answered without any hook, and hooks fire while the app is down.
   The activity feature reads the registry and the process tree as well; do not tighten it against one
   recording.

## Status

- Version 1.0.5 is tagged and released on GitHub with its DMG: the manual update check (Settings › Updates), the
  built-in-keyboard Fn rule with its Input Monitoring row and the physical-key requirement (1.0.4), the arrow-key
  fix, the dead-code cleanup and the rewritten docs. The tree is ahead of it and unreleased: the "Show in menu
  bar" switch, "Quit KoffeeLid", the Icon Composer icon, and the six-page Settings window with its macOS 15
  target, and the automatic update (weekly check, notification, update window, Install and Relaunch).
  `/Applications` runs a build older than this tree, without the automatic update: its first update is still by
  hand (`script/install.sh`, or the next release's DMG).
- `swift test` is green (337 distinct cases: 315 Core, 22 LidPlaneKit) and the Debug build warning-free at this
  commit. The app target has no automated tests; `docs/manual-checks.md` is its verification.
- Not walked on hardware: the Settings window's checklist (`docs/manual-checks.md` § Settings UI; the owner
  approved its look and wording in the running app), the dark-wake hold, the one-close hold, the late-display
  reopen lock, the arrow-key check, the built-in-keyboard Fn rule, and most of the auto-arm section. The update
  feature has been run through its unit tests, through a real install and a real roll-back of a stand-in app by
  the real helper, and through the real 1.0.5 release (check, fetch with its digest, unpacking, signature
  rule); KoffeeLid installing over itself, the notification and the update window have not been seen
  (`docs/manual-checks.md` § Updates). Open questions the owner has not settled: `docs/functional.md` § Unconfirmed.
- The `/usr/local/bin/koffeelid` wrapper may be missing (`/usr/local/bin` is root-owned); call the bundle binary.
- Auto-arm on activity is set up on this Mac (both hooks, the switch on): a fresh launch of the app while a
  Claude Code session works auto-arms at once.
- A Claude turn that dies when the Thunderbolt dock is unplugged is the dock's Ethernet going away, not a failed
  arm (`docs/pitfalls.md` § Working on this Mac).
