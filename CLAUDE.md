# KoffeeLid — CLAUDE.md

The operating manual for an agent working in this tree. Read it whole before the first edit.

## What this project is

KoffeeLid (bundle id `dev.rubens.koffeelid`) is a macOS menu-bar app that keeps a MacBook running with the lid
closed. Three manual modes: **Off**, **Armed**, **Armed + screen on** (`ArmMode.caffeinate` in code and CLI,
« Activé + écran allumé » in French). It also arms itself while Claude Code, Codex, Copilot, OpenCode or a
terminal command is working (Claude Code hooks, Codex hooks, Copilot's hook file, OpenCode's plugin and a zsh
snippet feed an activity journal; the app reads it), and a lid gesture (Fn, or
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
check is automatic, the fetch and the install each need a click). Releases are Developer ID-signed, notarized
DMGs (`script/release.sh`, the Wooflab team, `85F6AC5QZF`) that run on any Mac.

Repo `~/Projects/koffeelid`, GitHub `git@github.com:bambidotexe/koffeelid.git` (`origin`, branch `main`, SSH
as `bambidotexe`, `gh` logged in). **The installed copy `/Applications/KoffeeLid.app` is the owner's daily
driver and is usually armed while you work** (see Rules). Its data lives in
`~/Library/Application Support/KoffeeLid/`: `diagnostics.log`, `activity.jsonl`, `koffeelid.pid`, `sleep-lock`.

## The family, and the shared documents

This app is one of the macOS apps under `~/Projects` that share one shape; the `macos-map` skill lists
them and routes a task to the right skill. **`docs/shared/` is a synced copy of
`~/Projects/macos-app-template/docs/shared/`, and it is never edited here**: a change goes in the template
and `sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh` replicates it to every app. A trap, a
convention or a platform fact that applies to more than this app goes there, not in this app's own
documents. `docs/shared/workflow.md` is the change workflow every app of the family follows and
`docs/shared/pitfalls.md` the traps they all share; the sections below are this app's own statement of the
workflow, with its own file names, and this app's own traps.

## Read first

| File | What it is |
|---|---|
| `docs/README.md` | The index: which document answers which question, and how to start a session. |
| `docs/functional.md` | **The authority on behaviour.** Every mode, arming path and rail, the gesture, the effect, the UI, every setting with its default, the permissions, the non-goals, the open questions. Kept in sync with the code by the rule below. |
| `docs/architecture.md` | The five targets, the coordinator's state machine and kernel-flag ownership, who watches what, the gesture, the effect, the activity pipeline, persistence, the privilege boundary, threading, build. |
| `docs/macOS.md` | The platform facts the app relies on: the kernel flag and powerd, the sleep lock, assertions, the lid-angle sensor, modifier keys, displays, capture, TCC, Claude Code's hooks and registry, zsh. Read it before designing on a platform assumption. |
| `docs/pitfalls.md` | Traps already hit, each with symptom, cause, what the code does and what not to do. **Read the matching section before changing sleep, lid, gesture, effect, watchdog, privilege or hook code.** |
| `docs/development.md` | Build, install and debug loop; how to add a preference, a string, a control, a permission row, a verb, an effect tunable, a collaborator; icons; the release checklist; known limitations. |
| `docs/manual-test-checklist.md` | The hardware checklist: the only verification of everything IOKit, Metal, CoreAudio and TCC. Unit tests cannot reach those paths; the log lines it greps for are part of the contract. |
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
   in `docs/manual-test-checklist.md`; a new setting is a row in `functional.md` § Settings and defaults; every new
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
| the close sound, the closed-lid reminders, the volume override | `App/LidCloseSoundPlayer.swift`, `OutputVolumeOverride.swift`; `Core/VolumeOverridePolicy.swift`, `LidSoundRoute.swift`, `ClosedLidReminder.swift`; `KoffeeLidController.remindIfClosed`; `App/Resources/Sounds` | `functional.md` § Lid closed, lid open; `macOS.md` § Sounds |
| auto-arm on activity | `Core/ActivityConstants.swift`, `ActivityEvent.swift` (`ActivityAgent`, the event lists, `ActivityVerdict`), `ActivitySessionStore.swift` (the turn guard, `rescueStamp`), `ActivityJobStore.swift`, `ShellJobLiveness.swift`, `ActivityArmPolicy.swift` (`ActivityKind`), `ActivityTrim.swift` (also `HookCall`), `ClaudeRegistryRecord.swift`, `CodexRolloutTail.swift`, `CodexThreadRecord.swift` (with `CodexDaemonRPC`), `WebSocketFrame.swift`, `CopilotSessionState.swift`, `CopilotTranscriptTail.swift`, `FrenchElision.swift`, `ProcWalk.swift`; `App/ActivityMonitor.swift`, `ActivityJournalTailer.swift`, `ActivityProcessWatcher.swift`, `ClaudeProcessRegistry.swift`, `CodexRollout.swift`, `CodexDaemonClient.swift`, `CopilotTranscript.swift`, `LocalInputMonitor.swift`; `KoffeeLidController.applyAuto`, `autoArmHint` | **`docs/shared/activity-detection.md` first** (the contract shared with my-sidepulse, below); then `functional.md` § Modes and arming (auto-arm); `architecture.md` § Auto-arm on activity; `macOS.md` § Claude Code, § Codex, § Copilot, § OpenCode; `pitfalls.md` § Claude Code hooks and the shell, § Codex hooks, § Copilot hooks, § OpenCode plugin |
| the hooks, the zsh snippet, the hook binary | `Hook/Sources/main.swift`; `Core/HookConfig.swift` (one spec per agent), `HookSettingsFile.swift`, `CodexHookTrust.swift` (Codex's trust key and hash, the `config.toml` edit), `CopilotHookFile.swift` (Copilot's whole hooks file), `OpencodePlugin.swift` (OpenCode's whole plugin text), `SHA256.swift`, `ShellInit.swift`, `ActivityJournalWriter.swift`; `App/HookInstaller.swift`, `App/UI/Hooks.swift` (`HookCatalog`) | the same, plus `macOS.md` § zsh, § Codex, § Copilot, § OpenCode |
| the CLI, `koffeelid://` URLs, App Intents | `App/main.swift`, `App/CommandServer.swift` (`CommandLineClient`; `install-hooks`/`uninstall-hooks` take `claude`/`codex`/`copilot`/`opencode`), `Core/DeepLink.swift`, `App/Intents/KoffeeLidIntents.swift`; `KoffeeLidController.perform(_:source:)` | `functional.md` § User interface; `development.md` § How to add things (a CLI / URL verb) |
| the menu, the status item, the menu-bar glyph | `App/StatusItemController.swift`, `MugShape.swift`, `App/Resources/Glyphs`; the auto-armed cup's badges: `Core/ActivityBadges.swift` (which app stands for which work, `AutoArmBadges`), `App/ActivityIcons.swift` | `functional.md` § User interface; `development.md` § Icons |
| the app icon | `App/Resources/AppIcon.icon` (Icon Composer document), its `type: file` source entry in `project.yml` | `development.md` § Icons; `architecture.md` § Build, signing, entitlements |
| Settings (start with the `macos-building-settings-pages` skill) | `App/UI/SettingsWindow.swift` (pages, toolbar, height), `SettingsKit.swift` (the kit and every number), `SettingsModel.swift` (bindings, polled states), `Settings…Page.swift` (one per page); `Core/SettingsStatus.swift` (a state's colour: a missing grant is red when `SettingsGrant.isRequired`, orange otherwise, on every page) | `functional.md` § User interface, § Settings and defaults; `development.md` § How to add things (a settings control); the skill, if a rule of the window changes |
| the Health page: a check, a reading, its colour, its words (start with the `macos-building-settings-pages` skill, *The Health page*) | `Core/HealthReport.swift` (`HealthFacts`, `checks(for:)` and `readings(for:)`: which lines, their level, word, value, detail and fix), `Core/HealthRules.swift` (the level rules, `CrashReports`), `Core/Health.swift` (`HealthLevel`, `HealthRow`, `InfoRow`, `HealthLimits`, `HealthConstants`); `App/UI/SettingsHealthPage.swift` (the view: two tables), `App/UI/HealthWords.swift` (every word), `App/UI/HealthCheck.swift` (the readings taken on show and on Check Again, the facts), `App/HealthReaders.swift` (`WatchdogProcess`); a coordinator state it reads is a read-only property on `KoffeeLidController` | `functional.md` § User interface (The Health page); `HealthTests` and `SettingsWordsTests`; `manual-test-checklist.md` § Settings UI |
| onboarding (start with the `macos-building-onboarding` skill) | `App/UI/OnboardingWindowController.swift`, `ControlActionHandler.swift`; `App/AppDelegate.swift` (`showOnboarding`, `applicationShouldHandleReopen`) | `functional.md` § User interface; `pitfalls.md` § Windows and permission grants; the skill, if a rule of the window changes |
| the Tip page, the Ko-fi link | `App/UI/SettingsTipPage.swift`, `KoFiMark.swift`; `Core/SupportLink.swift` (the page and the smallest tip it takes) | `functional.md` § User interface; `manual-test-checklist.md` § Settings UI |
| a preference and its default | `App/Preferences.swift`; `KoffeeLidController.preferenceChanged(_:)` | `functional.md` § Settings and defaults |
| a user-visible string | `App/Resources/Localizable.xcstrings`, edited in place, with its `fr` entry | `development.md` § How to add things (a user-visible string) |
| a permission row, the sudoers setup, Reset (start with the `macos-building-onboarding` skill) | `App/UI/Permissions.swift` (`PermissionCatalog`, `FocusReturnWatch`), `Core/SettingsStatus.swift` (`SettingsGrant`), `App/UI/SettingsSystemPage.swift`, `App/UI/SleepLockSetupAction.swift`; `KoffeeLidController.resetEverything` | `functional.md` § Permissions and what breaks without them; `macOS.md` § Permissions and how each is reset; `pitfalls.md` § Windows and permission grants |
| the uninstall | `Core/UninstallPlan.swift` (the root-owned files, the one privileged line, and the helper that waits for this pid); `KoffeeLidController.uninstallEverything`, `App/SleepLock.swift` (`runPrivilegedScript`), `App/DiagnosticLog.swift` (`silence`), the Uninstall group of `App/UI/SettingsGeneralPage.swift` | `functional.md` § Uninstall; `manual-test-checklist.md` § Settings UI |
| a notification | `App/NotificationsController.swift` and the call site | the section of the behaviour that posts it |
| the shortcuts | `App/HotKeyController.swift` | `functional.md` § User interface |
| the watchdog, crash recovery, the pid file | `Watchdog/Sources/main.swift`; `App/RelaunchAgentController.swift`; `Core/CrashLoopGuard.swift`, `PidFileRecord.swift`, `RelaunchHistoryStore.swift`, `DiagnosticFileWriter.swift` | `architecture.md` § Watchdog contract; `macOS.md` § Login items and the watchdog; `pitfalls.md` § Watchdog and launch |
| diagnostics and log lines | `App/DiagnosticLog.swift`, `Core/DiagnosticLine.swift` | `docs/manual-test-checklist.md` greps for the phrasing: keep it |
| updates: the check, its schedule, the notification | `Core/UpdateCheck.swift` (`ReleaseVersion`, `LatestRelease`, `UpdateCheck`), `Core/UpdateSchedule.swift`, `Core/UpdatePanel.swift` (the Updates group: mark, button, what a press starts); `App/UpdateController.swift` (the one owner), `App/UpdateChecker.swift`, `App/NotificationsController.swift`; the Updates group of `App/UI/SettingsGeneralPage.swift` | `functional.md` § Updates; `architecture.md` § Updates |
| updates: the window, the fetch, making it ready | `Core/UpdateSession.swift`, `Core/StagedUpdateCheck.swift`; `App/UI/UpdateWindow.swift`, `App/UpdateChecker.swift` (`UpdateDownload`), `App/UpdateStager.swift`, `App/CodeSignature.swift` | the same, plus `macOS.md` § Updates |
| updates: Install and Relaunch | `Core/UpdateInstallScript.swift` (the helper's text, `UpdateInstallPlan`, `UpdateResult`), `Core/DetachedProcess.swift`; `App/UpdateInstaller.swift`, `UpdateController.installAndRelaunch`, `KoffeeLidController.quitWouldSleepTheMac` | the same, plus `pitfalls.md` § Updates and `manual-test-checklist.md` § Updates. **Read `pitfalls.md` § Updates before touching the order of an install** |
| build, install, release | `project.yml` (never the xcodeproj), `script/bootstrap.sh`, `build.sh`, `install.sh`, `run.sh`, `release.sh`, `ExportOptions.plist`; the version in its three places (Commands) | `development.md` § Release checklist; `architecture.md` § Build, signing, entitlements |

## Commands

```bash
# ---- the two actions. A build of this app reaches a Mac by one of these and by nothing else. ----
script/install.sh                                     # skill: macos-install-locally. Production build → /Applications; leaves no .app or .dmg behind
                                                      # It works on this Mac: signing and the notary are set up and nothing is wrong with them.
                                                      # Use the script; a refusal at the notary check is run again, never diagnosed.
script/publish.sh <patch|minor|major> --notes=<file> [--install]  # skill: macos-publish-release. The same build, plus a version bump, tag, push, GitHub release; installs only with --install
# -------------------------------------------------------------------------------------------------

swift test                                            # KoffeeLidCore + LidPlaneKit unit tests (635); needs the Claude Code sandbox off, like xcodebuild
swift test --filter LidProgressDriverTests            # one test class
swift test --filter LidProgressDriverTests/testArmsAfterActivationDegreesWithOption   # one test
swift build                                           # libraries only; the app needs Xcode (below)

script/bootstrap.sh                                   # xcodegen generate (run after adding/removing App, Hook or Watchdog files)
script/build.sh                                       # Release build, prints the .app path last; Debug refuses without DEBUG_OK=1
script/release.sh                                     # the notarized disk image on its own, publishing and installing nothing
script/run.sh                                         # install + launch + tail the diagnostics log (never returns)

"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" status   # CLI: arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings | install-hooks [claude|codex|copilot|opencode] | uninstall-hooks [claude|codex|copilot|opencode] | shell-init zsh
tail -f "$HOME/Library/Application Support/KoffeeLid/diagnostics.log"   # the primary debugging tool
/usr/bin/log show --last 10m --predicate 'process == "powerd"'           # the unified log; `log` alone is a shell function here
```

- The CLI is the app binary itself (`main.swift` forwards the verb to the running instance over distributed
  notifications, launching it if needed, and exits). `script/install.sh` writes a `/usr/local/bin/koffeelid`
  wrapper when that directory is writable; otherwise it prints the `sudo` one-liner.
- `KoffeeLid.xcodeproj`, `DerivedData/` and `.build/` are generated and git-ignored; edit `project.yml`, never
  the xcodeproj. If `xcodebuild` prints "Stale file … outside of the allowed root paths" or `swift test` fails
  on a module-cache path, the repo folder moved: `rm -rf DerivedData .build` and rebuild.
- **The version lives in three places that must agree**, and `script/version.sh` is the only thing that writes
  them: `App/Info.plist` `CFBundleShortVersionString` (with `CFBundleVersion` rising beside it),
  `KoffeeLidCore.version` and its assertion in `Tests/KoffeeLidCoreTests/SmokeTests.swift`. **A local install
  always builds and installs exactly the tree's version** — the same version production runs, until the next
  publish. Publishing is the only thing that moves the version: `script/publish.sh <patch|minor|major>` bumps
  the tree by that level, commits and pushes the bump before it builds anything, then releases exactly that
  version. Nothing bumps it again afterward. The README test badge is a static shields.io URL.
- App targets only build with `xcodebuild` (App Intents metadata, String Catalog, asset catalog). `swift build`
  covers `Sources/` only.
- Treat compiler warnings as failures; the tree is warning-free. A `warning:` line from
  `appintentsmetadataprocessor` is not one: that Debug build wrote no App Intents metadata, the next relink does
  (`docs/pitfalls.md` § Working on this Mac). No linter is configured.
- XCTest's summary line undercounts here; count the per-case `passed` lines
  (`swift test 2>&1 | grep -E "^Test Case '.*' passed" | sort -u | wc -l`).
- A release is `script/publish.sh <patch|minor|major> --notes=<file>` and nothing else: it refuses without
  release notes written from every commit since the last tag (skill `macos-publish-release`, *Release
  notes*), on a dirty tree, computes
  the new version and refuses if that tag already exists, then bumps the version, commits and pushes that
  bump, builds the notarized image, tags, pushes, creates the GitHub release. It installs the same bundle in `/Applications` only with `--install`, which is
  passed only when the owner asks for it; otherwise the installed copy finds the release itself. Nothing bumps the tree again afterward — it sits at exactly what was published.
  `script/release.sh` underneath it makes the image alone.
  The DMG is signed with the Wooflab team's Developer ID (`85F6AC5QZF`) and notarized; it runs on any Mac.

## Architecture in one screen

Five targets, dependency direction strictly downward. Full version in `docs/architecture.md`.

| Target | Kind | Depends on | Contents |
|---|---|---|---|
| `KoffeeLidCore` (`Sources/KoffeeLidCore`) | SwiftPM library, Foundation only | — | Every policy/state machine as a value type with injected time: `ArmMode`/`ModeCycle`, `ArmingPolicy`, `LidProgressDriver`, `OptionGateFilter`, `FnKeyReading`, `AngleSampleFilter`, `FoldTracker`, `AngleSmoother`, `FoldGeometry`, `ReopenCancelWatch`, `ReopenLockDecision`, `ClosedLidReminder`, `GestureArmHold`, `EffectParameters`, `VolumeOverridePolicy`/`LidSoundRoute`, `SleepInterruptionPolicy`/`SleepOverrideGuard`/`SleepLockSetup`, `CrashLoopGuard`, `PidFileRecord`/`AppSupport`, `DiagnosticFileWriter`, `DeepLink`, the update feature's `ReleaseVersion`/`LatestRelease`/`UpdateCheck`/`UpdateSchedule`/`UpdatePanel`/`UpdateSession`/`StagedUpdateCheck`/`UpdateInstallScript`/`DetachedProcess`/`UpdateResume`, `SettingsStatus`, the activity feature's `ActivityConstants`/`ActivityEvent`/`ActivityVerdict`/`ActivityTrim` (with `HookCall`)/`ActivitySessionStore` (with `rescueStamp`)/`ActivityJobStore`/`ShellJobLiveness`/`ActivityArmPolicy`/`ClaudeRegistryRecord`/`CodexRolloutTail`/`CodexThreadRecord`/`CodexDaemonRPC`/`WebSocketFrame`/`CopilotSessionState`/`CopilotTranscriptTail`/`CopilotHookFile`/`OpencodePlugin`/`FrenchElision`/`HookConfig`/`HookSettingsFile`/`CodexHookTrust`/`SHA256`/`ShellInit`/`ProcWalk`, the Health page's `Health`/`HealthRules`/`HealthReport`/`CrashReports`. **All logic tests live against it.** |
| `LidPlaneKit` (`Sources/LidPlaneKit`) | SwiftPM library | Core | The lid-close effect: `EffectController` turns lid angles into a fold (`FoldTracker`, closing only, threshold-gated) and runs a capture session only while folded: `DesktopCapture` (ScreenCaptureKit) → `PlaneRenderer` (Metal, shader in `PlaneShader.swift`; `PlaneRemap.swift` is the same maths in Swift, the tested reference) inside `EffectOverlayPanel`. |
| `KoffeeLid` (`App/Sources`) | Xcode app target | Core, LidPlaneKit | `KoffeeLidController` is the **only** object that mutates arming state (`setMode(_:source:)` is the entry point; `perform(_:source:)` runs CLI/URL verbs); every other file is a collaborator that reports events to it via closures. `HookInstaller` is a stateless helper used by the CLI client and the Settings window; `UpdateController` owns the update feature (the checks, the notification, the update window, Install and Relaunch) and never touches arming state: it quits the app through `NSApp.terminate`. UI under `App/Sources/UI`: the Settings window is an AppKit toolbar window (`SettingsWindow`) hosting eight SwiftUI pages built only from the kit in `SettingsKit.swift`, sharing one `SettingsModel`, the Health page second to last with its own `HealthCheck`; the four-page onboarding is programmatic AppKit; `PermissionCatalog` and `HookCatalog` are the single lists of grants and hooks, read by both. |
| `KoffeeLidWatchdog` (`Watchdog/Sources/main.swift`) | Xcode tool, embedded in the app | Core | LaunchAgent that relaunches the app after an unclean exit (pid file present) and stands down otherwise. |
| `KoffeeLidHook` (`Hook/Sources/main.swift`) | Xcode tool, embedded in the app | Core | `hook` (Claude Code), `hook codex`, `hook copilot <event>`, `hook opencode` and `job begin\|end` verbs, run once per Claude Code event, per Codex event, per Copilot event, per OpenCode event (forwarded by its plugin) and per zsh command: append a trimmed `ActivityEvent` line to `~/Library/Application Support/KoffeeLid/activity.jsonl`. Never launches the app, always exits 0. |

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
- **A build of this app reaches a Mac in exactly two ways, and there is no third.** `script/install.sh`
  (skill `macos-install-locally`) builds the production bundle and puts it in `/Applications`; `script/publish.sh`
  (skill `macos-publish-release`) does the same and puts the disk image on GitHub. Both build the real thing —
  Release, Developer ID, Hardened Runtime, notarized, stapled — so what runs on this Mac is what a stranger
  would download. **Neither leaves an `.app` or a `.dmg` anywhere under the repository**, on any exit path,
  including a failed one: a signed bundle in `build/` or `DerivedData/` is a complete application that
  Spotlight indexes and the owner can launch by accident, giving a second instance with the same bundle
  identifier, the same preferences and the same launch agent — two KoffeeLids fighting over the kernel
  lid-sleep flag. `script/no-leftovers.sh` holds that rule; keep it holding.
- **A Debug build is never installed, and never made without asking the owner first.** It exists only to read
  something a Release build will not show. `script/build.sh Debug` refuses without `DEBUG_OK=1`; that guard is
  there to make the decision deliberate, not to be worked around. If a Debug build would help, say why and
  ask. Delete the bundle when done with it.
- **The installed app is the owner's daily driver, and quitting it must never be able to sleep the Mac.**
  `AppleClamshellCausesSleep = No` in `ioreg` usually means it is armed — run `koffeelid status` before
  drawing conclusions. **The refusal is `quitWouldSleepTheMac`, not the lid alone.** With the lid open, an
  external display connected, or the app unarmed, quitting is safe; only armed + lid shut + no external
  display can sleep the Mac at once. So `script/install.sh` refuses outright while `status` carries the
  warning `quitting would sleep the Mac`, with no override, and it checks again after the build because the
  state may have changed during it. Otherwise it installs over any arm and puts the manual mode back itself
  (`caffeinate` / `arm`), so the Mac is unarmed only for the seconds between the quit and the relaunch — the
  build and the notarizing are already done by then — and, with the sudoers rule in place, it holds the sleep
  lock itself across those seconds and hands it to the relaunched copy. The auto level needs no restoring: a launch while a
  session is working arms at once by itself. Never send `off` while the lid is closed on an armed session
  with no external display. Any other utility that sets the same kernel flag will fight the arm;
  quit it before testing.
- **Any work on the onboarding window, or on any permission row, starts with the `macos-building-onboarding` skill**
  (`~/.claude/skills/macos-building-onboarding/SKILL.md`): adding or rewording a page or a row, changing what a grant
  button does, or anything about which window is in front. It holds the window's contract, how a grant is
  named and asked for, and the traps that cost this window a whole session. Two rules from it that nothing
  may break: **no permission prompt without a click**, and **a grant is titled exactly what System Settings
  titles the switch**.
- **Any work on the Settings window starts with the `macos-building-settings-pages` skill**
  (`~/.claude/skills/macos-building-settings-pages/SKILL.md`): adding, moving, renaming or rewording a setting, a
  status, a group, a page or any sentence the window shows. It holds the window's structure, its numbers and
  how its words are written.
- **Every user-visible string goes through `L("literal key")`** and must exist in
  `App/Resources/Localizable.xcstrings` with an `fr` entry (an untranslated key is a build warning). No
  interpolation inside `L()`; use `String(format: L("… %d …"), …)`. App Intents strings are
  `LocalizedStringResource` literals in the same catalog. App-name + version strings are not localized. Edit
  the catalog in place; never load and re-serialise it.
- **Activity detection is one contract with my-sidepulse.** `docs/shared/activity-detection.md` is what both
  apps implement to decide whether an agent or a terminal command is working: the sources, the session machine,
  the rescues, the jobs and their constants. A change to any of it is made in the contract first (in
  `~/Projects/macos-app-template`, then synced), then here **and** in `~/Projects/my-sidepulse` in the same
  session, each with its test; a rule one app follows and the other does not is a bug in one of them, and the
  better rule wins in both. What KoffeeLid does with a session that is not working (the hold-off, "Disarm once
  finished", the drop on local input, the badges) is its own.
- **Comments state the present.** A comment records a rule, an invariant, a measurement or a platform
  constraint; no dates, task numbers or accounts of what the code replaced. Docs describe the present system
  only, in the present tense.
- **Ask before any change to arming behaviour, to TCC grants or to privilege** (sudoers, login items): those
  are the owner's decisions, and the wrong one sleeps or unlocks a closed Mac.
- Compiler warnings are failures. Unit tests are hermetic and live against Core; a pure rule gets its test
  first. Anything hardware-facing gets a line in `docs/manual-test-checklist.md` and a log line to grep for.
- Diagnostics go through `DiagnosticLog.shared.log` (app) or `DiagnosticFileWriter` (watchdog); both lock
  `diagnostics.lock`. `Preferences.diagnosticsEnabled` silences the app's writer; check it before concluding a
  log is empty. Keep the existing phrasing of log lines (`docs/manual-test-checklist.md` greps for them).
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
   `releaseSleepLock()` (`pmset disablesleep 0` survives reboots), **in that order: the flag while the lock
   still holds, then the lock.** Clearing the flag with the lid shut makes the kernel evaluate the clamshell at
   once, and only the lock keeps that evaluation from starting a sleep that darkens the displays and locks the
   session (`docs/pitfalls.md` § Sleep and the kernel flag). Do not add an early return between setting the
   flag and updating `state`.
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
  modifier flags, capture, CoreAudio, TCC, the network) is verified only via `docs/manual-test-checklist.md` and log
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

`docs/pitfalls.md` is the full list. The six that cost the most time:

1. **powerd rewrites the kernel flag under you.** Selector 12 sets the same bit powerd owns; a charger plug, a
   display hot-plug or leaving desktop mode can bring the mask to 0 and start a clamshell sleep inside the same
   call. The sleep lock is what actually holds a closed Mac; `reapplyFlag` is the second line. The same bit is
   powerd's closed-display protection: the app's own clear, with the lid shut on an external display, starts a
   clamshell sleep unless the lock still holds, so the flag is always cleared before the lock is released.
2. **`AppleClamshellCausesSleep` lies for a while.** It is refreshed only by the kernel's own clamshell
   notifications, never by a selector-12 write. `koffeelid status`, the log and `pmset -g assertions` are the
   reliable views.
3. **The Fn flag is not the Fn key.** Arrow keys, F1–F12 and an external keyboard's navigation keys raise the
   secondary-Fn flag too; a modifier read that trusts the flag arms on a plain lid adjustment and keeps the
   effect from settling. Key 63, and with Input Monitoring the built-in keyboard's HID element, are the truth.
4. **A display that vanishes behind a closed lid is reported late**, about 130 ms after the lid-open
   notification, so a reopen decision on a cached topology unlocks the session. The list is re-read at lid
   open and a skipped lock stays pending for 2 s.
5. **A permission row is a pointer into a list the user has to scan.** Name it anything but what System
   Settings prints beside the switch and the user cannot act on it; ask for a grant without a click and macOS
   remembers the refusal for good; take activation when a flow reports back and the window lands on top of the
   pane it just opened, while never taking it leaves the window behind the user's terminal. Start from the
   `macos-building-onboarding` skill, not from instinct.
6. **Hooks are not a complete signal.** In Claude Code, Esc and Ctrl-C fire no hook, `SubagentStop` is often
   missing, `idle_prompt` is a timer, a dialog can be answered without any hook, and hooks fire while the app
   is down. The activity feature reads the registry and the process tree as well; do not tighten it against
   one recording. In Codex, a hook written into `hooks.json` never runs until `config.toml` carries its trust
   (`docs/pitfalls.md` § Codex hooks); `install-hooks codex` writes both. In Copilot, an interrupt (Ctrl+C, a
   double Esc) fires no hook either, and a `preToolUse` hook that fails denies the tool, fail-closed — KoffeeLid
   never subscribes it, and the quiet check reads `events.jsonl` instead (`docs/pitfalls.md` § Copilot hooks).
   In OpenCode, the plugin must use the v2 shape (`export default { id, setup(ctx) }`, `ctx.event.subscribe()`);
   a v1-style plugin fails to load, and one plugin instance runs per open directory against the same one
   background server, so the file de-duplicates by event id across instances rather than assuming it is alone.

## Status

- Version 1.1.3 committed and published (`App/Info.plist`, `KoffeeLidCore.version`, `SmokeTests`), and the
  tree sits at exactly that: a local install always builds exactly the tree's own version, never one ahead of
  production, and nothing bumps the tree again until the next `script/publish.sh <patch|minor|major>`.
  1.1.3 was published without installing it: `/Applications/KoffeeLid.app` is still at **1.1.2**, so this Mac
  can walk KoffeeLid updating itself to 1.1.3 (notification, update window, Install and Relaunch). The tree carries the manual update
  check (Settings › Updates), the built-in-keyboard Fn rule with its Input Monitoring row and the physical-key
  requirement, the arrow-key fix, the "Show in menu bar" switch, "Quit KoffeeLid", the Uninstall group, the
  Icon Composer icon, the eight-page Settings window (its Health page second to last) with its macOS 15 target, and the automatic update (weekly
  check, notification, update window, Install and Relaunch). `script/install.sh` refuses only while quitting
  would sleep the Mac at once (armed, lid shut, no external display) — verified with a real closed-lid,
  external-display install (`docs/manual-test-checklist.md` § Safety rails). The sudoers rule and the watchdog
  agent are in place; the Claude Code hooks and the zsh snippet are not. The uninstall took them, and an
  install puts them back no more than it puts back a TCC grant: Settings, the onboarding and `install-hooks`
  do.
  `script/release.sh` produces a Developer ID-signed, notarized DMG under the Wooflab team (`85F6AC5QZF`,
  looked up by `script/signing.env`); it publishes nothing by itself.
- The onboarding is an ordinary window, and everything about that was walked on this Mac: the normal level and
  default collection behaviour (it stays behind what the user raises, and keeps its place across a Space
  switch), per-row redraw with a spinner beside the pressed button instead of a page rebuild, the grant buttons
  showing only the system dialog, the administrator dialog handing the front back, and System Settings handing
  it back when it quits. Every grant row is titled what System Settings titles the switch, quoted from the
  system's tables, and **nothing in the app asks for a permission without a click**. The rules and the traps
  are in the `macos-building-onboarding` skill; read it before touching that window or any permission row.
- `swift test` is green (635 distinct cases: 613 Core, 22 LidPlaneKit) and the Debug build warning-free at this
  commit. The app target has no automated tests; `docs/manual-test-checklist.md` is its verification.
- **Codex auto-arm is in the tree and not yet walked with the installed app.** What was checked on this Mac
  from the tree: Codex CLI 0.157.0's `hooks/list` reports for a probe hook the same twelve hashes
  `CodexHookTrust` computes, a trust written in the shape KoffeeLid writes is reported `trusted`, and one real
  `codex exec` turn under a trusted probe hook fired `SessionStart`, `UserPromptSubmit`, `Stop` and `SessionEnd`
  with the hook's parent being the `codex` process. Not seen: KoffeeLid's own binary under Codex, the Codex
  rows of the onboarding (page 3 now holds five rows at 560 pt) and of Settings › Auto-Arm and Health, the
  Interrupt path, and the thirteen-check, eight-reading Health limits in the running app
  (`docs/manual-test-checklist.md` § Auto-arm on activity).
- **Copilot and OpenCode auto-arm are in the tree and not yet walked with the installed app.** The facts came
  from two research probes run on this Mac against a real Copilot CLI 1.0.88 and a real OpenCode 2.0.17 (the
  session-state and `events.jsonl` shapes, the plugin's v2 API, the server's pid); none of KoffeeLid's own code
  has met either agent yet — the trims, `CopilotTranscriptTail`, `CopilotHookFile`, `OpencodePlugin`, the
  onboarding's fourth and fifth hook rows, the two Settings › Auto-Arm groups and the two Health lines are
  pinned only by fixtures replayed through the store. Not seen: `install-hooks copilot`/`opencode` against a
  real `~/.copilot`/`~/.config/opencode`, a real Ctrl+C or failed turn ending a Copilot session, a real
  OpenCode subagent chain or plugin reload, and the two badges (`com.github.githubapp`, `ai.opencode.desktop`)
  on the cup (`docs/manual-test-checklist.md` § Onboarding, § Settings UI, § Auto-arm on activity).
- **The ghost-session work is in the tree and not walked on hardware**: the turn guard (a closed turn stays
  closed; a tool call reopens a verdict-closed one), the compaction rule, the Codex rollout check and the
  managed daemon's `thread/read` and launch `thread/loaded/list`, the journaled verdicts, and the jobs' shell
  probe. Their rules are unit-tested in Core; the Swift daemon client (`CodexDaemonClient`) has only met a
  fake daemon, never Codex's own (`docs/manual-test-checklist.md` § Auto-arm on activity).
- Not walked on hardware: the auto-armed cup's badges (`docs/manual-test-checklist.md` § Arming paths: the app icon
  on the cup in a light and a dark bar, the hosting terminal's icon, the stack, the badges staying through the
  hold-off, the icons on the menu's auto-arm line), the Settings window's checklist (`docs/manual-test-checklist.md` § Settings UI; the owner
  approved its look and wording in the running app, before the stop sign and the one colour rule for grants, and
  rejected the first Health page as far too long: the page is now two short tables, checks and readings, which the
  owner has not seen yet), the dark-wake hold, the one-close hold, the late-display
  reopen lock, the arrow-key check, the built-in-keyboard Fn rule, most of the auto-arm section, and the two volume-restore
  guarantees of the lid-close sound (put back at quit, and on a deadline when the audio system never reports the
  end of the clip; `docs/manual-test-checklist.md` § Sound / volume), and the quit that clears the flag under the
  sleep lock with `script/install.sh` holding the lock across the relaunch (§ Safety rails). On the
  onboarding, what has not been seen is the last page's Finish and the Notifications row's own prompt on a Mac
  where that grant has never been asked for. The update
  feature has been run through its unit tests, through a real install and a real roll-back of a stand-in app by
  the real helper, and end to end against a published GitHub release (check, fetch with its digest, unpacking,
  signature rule); KoffeeLid installing over itself, the notification, the update window and the window that says how an
  install ended have not been seen (`docs/manual-test-checklist.md` § Updates). Open questions the owner has not settled: `docs/functional.md` § Unconfirmed.
- There is no `/usr/local/bin/koffeelid` wrapper: `/usr/local/bin` is root-owned here, so `script/install.sh`
  prints the `sudo` one-liner instead of writing it. Call the bundle binary meanwhile. The sudoers rule for the
  sleep lock **is** in place.
- The uninstall (Settings › General › Uninstall) has been walked end to end on this Mac: it left no launch
  agent, no sudoers rule, no hooks, no zsh block, no preferences and no Application Support folder, and the
  Mac slept on a closed lid afterwards.
- A Claude turn that dies when the Thunderbolt dock is unplugged is the dock's Ethernet going away, not a failed
  arm (`docs/pitfalls.md` § Working on this Mac).
