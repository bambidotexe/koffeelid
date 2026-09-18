# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app, **KoffeeLid** (bundle id `dev.rubens.koffeelid`), that keeps a MacBook awake with the
lid closed, plays a closing-only "desktop stays up" lid effect, can force the volume of the lid-close sound,
and has an **Armed + screen on** mode (display never sleeps). Three manual modes: Off / Armed / Armed + screen
on (`ArmMode.caffeinate` in code and CLI, « Activé + écran allumé » in French), plus an auto-arm while Claude
Code or a terminal command works. The lid gesture is Fn (Globe) + close (Option selectable). A `koffeelid`
command line drives everything. Personal build: no licensing, no updater, en + fr only.

Repo: `~/Projects/koffeelid`, GitHub `git@github.com:bambidotexe/koffeelid.git` (`origin`, branch `main`, SSH
auth as `bambidotexe`, `gh` installed and logged in). Installed copy: `/Applications/KoffeeLid.app`, data in
`~/Library/Application Support/KoffeeLid/`.

Docs, all present tense; read them when the task touches the area:

- `docs/functional.md` — what the app does: modes, arming paths, gesture, auto-arm, rails, the lid effect and
  its reset rule, UI, settings and defaults, permissions.
- `docs/architecture.md` — targets, the coordinator's state machine, kernel-flag ownership, who watches what,
  the effect, the activity pipeline, persistence, privilege boundary, threading, build.
- `docs/macOS.md` — the macOS interfaces (kernel flag selector 12, `pmset disablesleep`, assertions, HID
  lid-angle sensor, modifier flags, private frameworks, TCC, Claude Code's hooks and registry).
- `docs/pitfalls.md` — traps already hit. **Read the matching section before changing sleep, lid, gesture,
  effect, watchdog, privilege or hook code.**
- `docs/development.md` — build/install/debug workflow, how to add a preference, string or settings control.
- `docs/manual-checks.md` — the hardware checklist; unit tests cannot cover IOKit/Metal/CoreAudio paths.

## Commands

```bash
swift test                                            # KoffeeLidCore + LidPlaneKit unit tests (248); needs the Claude Code sandbox off, like xcodebuild
swift test --filter LidProgressDriverTests            # one test class
swift test --filter LidProgressDriverTests/testArmsAfterActivationDegreesWithOption   # one test
swift build                                           # libraries only; the app needs Xcode (below)

script/bootstrap.sh                                   # xcodegen generate (run after adding/removing App, Hook or Watchdog files)
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

- `KoffeeLid.xcodeproj`, `DerivedData/` and `.build/` are generated and git-ignored; edit `project.yml`, never
  the xcodeproj. If `xcodebuild` prints "Stale file … outside of the allowed root paths" or `swift test` fails
  on a module-cache path, the repo folder moved: `rm -rf DerivedData .build` and rebuild.
- Version lives in three places that must agree: `App/Info.plist` `CFBundleShortVersionString`,
  `KoffeeLidCore.version` (`Sources/KoffeeLidCore/KoffeeLidCore.swift`) and its assertion in
  `Tests/KoffeeLidCoreTests/SmokeTests.swift`; the README test badge is a static shields.io URL.
- App targets only build with `xcodebuild` (App Intents metadata, String Catalog, asset catalog). `swift build`
  covers `Sources/` only.
- Treat compiler warnings as failures; the tree is warning-free. No linter is configured.
- XCTest's summary line undercounts here; count the per-case `passed` lines.

## Architecture in one screen

Five targets, dependency direction strictly downward:

| Target | Kind | Depends on | Contents |
|---|---|---|---|
| `KoffeeLidCore` (`Sources/KoffeeLidCore`) | SwiftPM library, Foundation only | — | Every policy/state machine as a value type with injected time: `ArmMode`/`ModeCycle`, `ArmingPolicy`, `LidProgressDriver`, `OptionGateFilter`, `FnKeyReading`, `AngleSampleFilter`, `FoldTracker`, `AngleSmoother`, `FoldGeometry`, `ReopenCancelWatch`, `ReopenLockDecision`, `GestureArmHold`, `EffectParameters`, `VolumeOverridePolicy`, `SleepInterruptionPolicy`/`SleepOverrideGuard`/`SleepLockSetup`, `CrashLoopGuard`, `PidFileRecord`/`AppSupport`, `DiagnosticFileWriter`, `DeepLink`, the activity feature's `ActivityConstants`/`ActivityEvent`/`ActivityTrim`/`ActivitySessionStore`/`ActivityJobStore`/`ActivityArmPolicy`/`ClaudeRegistryRecord`/`HookConfig`/`HookSettingsFile`/`ShellInit`/`ProcWalk`. **All logic tests live against it.** |
| `LidPlaneKit` (`Sources/LidPlaneKit`) | SwiftPM library | Core | The lid-close effect: `EffectController` turns lid angles into a fold (`FoldTracker`, closing only, threshold-gated) and runs a capture session only while folded: `DesktopCapture` (ScreenCaptureKit) → `PlaneRenderer` (Metal, shader in `PlaneShader.swift`; `PlaneRemap.swift` is the same maths in Swift, the tested reference) inside `EffectOverlayPanel`. |
| `KoffeeLid` (`App/Sources`) | Xcode app target | Core, LidPlaneKit | `KoffeeLidController` is the **only** object that mutates arming state (`setMode(_:source:)` is the entry point; `perform(_:source:)` runs CLI/URL verbs); every other file is a collaborator that reports events to it via closures. `HookInstaller` is a stateless helper used by the CLI client and the Settings page. UI under `App/Sources/UI` is programmatic AppKit built with `SettingsForm`: one Settings page, an Advanced window, a four-page onboarding; `PermissionCatalog` and `HookCatalog` are the single lists of grants and hooks. |
| `KoffeeLidWatchdog` (`Watchdog/Sources/main.swift`) | Xcode tool, embedded in the app | Core | LaunchAgent that relaunches the app after an unclean exit (pid file present) and stands down otherwise. |
| `KoffeeLidHook` (`Hook/Sources/main.swift`) | Xcode tool, embedded in the app | Core | `hook` and `job begin\|end` verbs, run once per Claude Code event and per zsh command: append a trimmed `ActivityEvent` line to `~/Library/Application Support/KoffeeLid/activity.jsonl`. Never launches the app, always exits 0. |

The kernel mechanism: `PowerManager` opens an `IOPMrootDomain` user client and calls
`IOConnectCallScalarMethod(…, 12 /* kPMSetClamshellSleepState */, …)`. Everything else in the coordinator
exists to guarantee that flag is cleared again. See `docs/architecture.md` § Kernel flag ownership before
touching `arm`, `disarm`, `shutdown`, `start` or `reapplyFlag`.

## Non-negotiable invariants

1. **Idle means the flag is clear.** Any code path that returns the coordinator to `.idle` (disarm, quit,
   rails, crash recovery at launch) must have attempted `setLidSleepDisabled(false)` **and**
   `releaseSleepLock()` (`pmset disablesleep 0` survives reboots). Do not add an early return between
   setting the flag and updating `state`.
2. **Do not clear the flag on evidence you did not create.** Launch/quit clears are conditional (stale pid
   file, brightness-recovery file, `isArmed || flagClearPending || power.lidSleepDisabled`) because other
   lid-sleep utilities drive the same kernel flag. Keep them conditional.
3. **Scope process commands to our bundle.** Every `pgrep`/`pkill` targets `KoffeeLid.app/Contents/MacOS/`
   or pids from `~/Library/Application Support/KoffeeLid/koffeelid.pid`; never kill by bare process name.
4. **The installed app is the user's daily driver.** `AppleClamshellCausesSleep = No` in `ioreg` usually
   means it is armed — run `koffeelid status` before drawing conclusions. **Never quit or reinstall it
   without checking `koffeelid status` first**: `script/install.sh` refuses while it is armed or auto-armed
   (`FORCE=1` overrides); quitting an armed instance ends the user's live session and, with the lid closed, may
   sleep the Mac. Restore the mode the user was in afterwards (`koffeelid caffeinate` / `arm`). Any other
   utility that sets the same kernel flag will fight the arm; quit it before testing.
5. **Main thread.** All collaborators call back on main; `LidAngleObserver.addConsumer/removeConsumer` are
   main-thread only; the sampler runs on its own queue (30 Hz at rest, 120 Hz while the lid moves, always
   delivering at 30 Hz, changed value or not) and hops to main before `onSample`.
6. **Every user-visible string goes through `L("literal key")`** and must exist in
   `App/Resources/Localizable.xcstrings` with an `fr` entry (an untranslated key is a build warning). No
   interpolation inside `L()`; use `String(format: L("… %d …"), …)`. App Intents strings are
   `LocalizedStringResource` literals in the same catalog. App-name + version strings are not localized.
7. **Preferences** are UserDefaults-backed properties on `Preferences.shared`. Pages write prefs; the
   coordinator reacts in `preferenceChanged(_:)`. `Preferences.onChange` has exactly one subscriber (the
   coordinator) — do not overwrite it from UI code.
8. **Modes and arm semantics are fixed, not preferences.** `mode` is the manual choice; `isArmed` ⇔
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
9. **The gesture detector never stays latched, and the modifier read is truthful.** `LidProgressDriver` resets
   itself when the modifier is released after an arm; the coordinator resets it on `arm`, `disarm` and every
   change of `gestureWanted`. Fn + close while armed from another source is visual confirmation
   (`effect.followLidFromHere()`, never a second arm). The modifier is read fresh on every sample, nothing
   cached, and the Fn flag only counts without the numeric-pad flag (`FnKeyReading`: arrow keys set the Fn
   flag too). The effect's return to flat has no timer behind it; it depends on samples arriving and on
   `holding` being true only while a key is really down (`docs/pitfalls.md`).
10. **One threshold.** The effect has no start threshold of its own: `gestureActivationDegrees` drives both the
    gesture and `EffectController.foldThresholdDegrees` (synced in `start()` and `preferenceChanged`).
11. **Diagnostics**: log through `DiagnosticLog.shared.log` (app) or `DiagnosticFileWriter` (watchdog);
    both lock `diagnostics.lock`. `Preferences.diagnosticsEnabled` silences the app's writer; check it before
    concluding a log is empty. Log lines are the primary debugging tool; keep the existing phrasing
    (`docs/manual-checks.md` greps for them).
12. **Two independent arms, ORed.** The manual mode (`mode`) and the auto level (`ActivityArmPolicy.isOn`)
    never touch each other; the Mac is armed while either holds (`autoArmed`, `applyAuto`). Manual Off
    (`releaseManual`) sets `mode = .off` and keeps the session if the auto level is on (`armSource` becomes
    `.activity`); the auto level dropping keeps the session if the manual mode is armed. Only the rails
    (battery, thermal, external sleep, reset, quit) end everything, through `disarm`, which also `suspend`s the
    level until the running work stops and something starts again (`armFailed` does the same for a blocked
    arm). Caffeinate comes only from the manual side. The hold-off after the work ends is the longest among
    the kinds that ran; local keyboard or mouse input during it drops the level at once; "Disarm once
    finished" shortens it to a minute and releases the manual mode too. Timings in `ActivityConstants` were
    sized from recorded Claude Code sessions — retune only against evidence.

## Testing constraints on this machine

- Unit tests are hermetic. Everything hardware-facing (kernel flag, brightness, lock screen, HID sensor,
  modifier flags, capture, CoreAudio) is verified only via `docs/manual-checks.md` and log lines.
- `swift test`, `xcodebuild` and anything that decodes HEIC or video fail inside Claude Code's sandbox; run
  them with the sandbox off. The shader is compiled at runtime: syntax-check it with `xcrun metal`
  (`docs/development.md` § Environment).
- A runtime smoke that is always safe: launch the Debug app with `KOFFEELID_DISABLE_ACTIVITY=1`, confirm
  `launched (pid …)` in the log, quit with `osascript -e 'tell application id "dev.rubens.koffeelid" to quit'`,
  confirm `clean termination`. While the installed app runs, a second instance exits at once.
- Prefer the CLI (`koffeelid status|arm|off|…`) over `open "koffeelid://…"`. `status` is always safe; never
  send `off` while the user's lid is closed on an armed session.
- Launch with `--open-settings` (run the binary inside the bundle directly) to render the Settings window
  without clicking the status item.
- Screen Recording and Login Items approvals are per bundle path and per team id: the DerivedData build and the
  `/Applications` build are different apps to TCC/launchd.

## Conventions

- Commit subjects use `feat|fix|build|docs(scope): …`. Commits in this repo end with
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and a `Claude-Session:` line. Push to `origin main`
  only when asked; tag releases `vX.Y.Z` (annotated) after bumping the three version locations; GitHub releases
  are created with `gh release create` and the DMG from `dist/`.
- Releases for other people: `script/release.sh` (Developer ID export + notarization + staple → `dist/*.zip`,
  Wooflab team `75MADVD27T`); it needs a Developer ID Application certificate and a `notarytool` profile
  (`docs/development.md` § Release checklist). Dev builds are Apple Development-signed and only run on this Mac.
- Shell scripts are zsh (`${0:A:h:h}` for the repo root, `set -euo pipefail`, BSD userland).
- Docs describe the present system only. History belongs in git; a trap worth remembering goes in
  `docs/pitfalls.md` with symptom, cause, what the code does and what not to do.
- Sound assets are free to use (`App/Resources/Sounds/SoundEffects-LICENSE.txt`); the effect maths is derived
  in `PlaneRemap.swift`, no third-party code.

## State of the tree

- Version 1.0.3 is tagged, released on GitHub with its DMG, and installed in `/Applications`. The working tree
  after it carries the arrow-key fix for the modifier read (`FnKeyReading`), the dead-code cleanup and the
  rewritten docs; none of that is installed or released.
- Hardware verification is tracked only in `docs/manual-checks.md`. Not walked on hardware: the dark-wake hold,
  the one-close hold, the late-display reopen lock, the arrow-key check, and most of the auto-arm section.
- The `/usr/local/bin/koffeelid` wrapper may be missing (`/usr/local/bin` is root-owned); call the bundle binary.
- Auto-arm on activity is set up on this Mac (both hooks, the switch on): a fresh launch of the app while a
  Claude Code session works auto-arms at once.
