# Development guide

## Environment

- macOS 15+ target (the Settings kit needs SwiftUI's `Group(subviews:)`); developed on macOS 27 with Xcode 27 / Swift 6.4 in Swift 5 language mode.
- XcodeGen (`brew install xcodegen`) generates `KoffeeLid.xcodeproj` from `project.yml`; `script/bootstrap.sh`
  installs it if missing and generates. Run it again after adding, removing or moving a file under
  `App/Sources`, `App/Resources`, `Watchdog/Sources` or `Hook/Sources` (directories are included whole).
  `KoffeeLid.xcodeproj`, `DerivedData/` and `.build/` are generated and git-ignored: edit `project.yml`.
- Signing is automatic with the Wooflab team's Developer ID (`85F6AC5QZF` in `project.yml`). Hardened Runtime
  on, no App Sandbox. `script/signing.env` holds the team id, the `wooflab-notary` notarytool profile and the
  other constants every signing/build/publish script sources; the signing identity itself,
  `Developer ID Application: Wooflab (85F6AC5QZF)`, is looked up in the keychain by team id, not written out.
- The Metal shader is a Swift string compiled at runtime; a syntax error only shows as
  `PlaneRenderer: pipeline failed` in Console and `effect: no built-in display or Metal unavailable` in the
  log at the next arm. Check it after every edit (needs the Metal Toolchain:
  `xcodebuild -downloadComponent MetalToolchain`):

  ```bash
  sed -n '/^    static let source = #"""$/,/^    """#$/p' Sources/LidPlaneKit/PlaneShader.swift | sed '1d;$d' > "$TMPDIR/plane.metal" \
    && xcrun -sdk macosx metal -c "$TMPDIR/plane.metal" -o "$TMPDIR/plane.air" && echo shader ok
  ```
- **Claude Code's sandbox**: `swift test` and `xcodebuild` fail inside it (SwiftPM's manifest cache under
  `~/Library/Caches`), and so do image and video decoders that go through system services. Run those commands
  with the sandbox off. `$TMPDIR` differs inside and outside the sandbox, so build throwaway tools in the
  session scratchpad.
- If `xcodebuild` prints "Stale file … outside of the allowed root paths" or `swift test` fails on a
  module-cache path, the repository folder moved: `rm -rf DerivedData .build` and rebuild.

## Daily loop

```bash
swift test                                   # Core + LidPlaneKit unit tests, hermetic
swift test --filter FoldTrackerTests         # one class; append /testName for one test
script/bootstrap.sh                          # only when files were added or removed
xcodebuild -project KoffeeLid.xcodeproj -scheme KoffeeLid -configuration Debug \
  -derivedDataPath DerivedData build 2>&1 | grep -E 'error|warning:|BUILD'
open -a "DerivedData/Build/Products/Debug/KoffeeLid.app"
tail -f "$HOME/Library/Application Support/KoffeeLid/diagnostics.log"
osascript -e 'tell application id "dev.rubens.koffeelid" to quit'
```

Compiler warnings are failures; the tree is warning-free. A `warning:` line from `appintentsmetadataprocessor`
(`Metadata extraction skipped`) is not a compiler warning: that build wrote no `Metadata.appintents`, and the next
build that relinks the app does (`docs/pitfalls.md` § Working on this Mac). `swift build` covers `Sources/` only:
the app targets need `xcodebuild` (App Intents metadata, String Catalog, asset catalog). No linter is configured.
XCTest's summary line undercounts here; count the per-case `passed` lines.

**Definition of done.** A change is done when the code and `docs/functional.md` (and the other documents it
touches: architecture, macOS facts, pitfalls, the manual checklist) describe the same app, `swift test` and the
warning check pass, the string catalog covers every new `L("…")` key, and the commit is per task. A request that
contradicts a written rule is put to the owner before the code changes (`CLAUDE.md` § Changing behaviour).

`script/install.sh` does a Release build into `/Applications/KoffeeLid.app`, quitting the running instance and
its watchdog first. It **refuses unless `koffeelid status` says `mode: off` without `auto-armed`** (`FORCE=1`
overrides), because quitting an armed app ends the user's session. It does not launch the app: run
`open -a KoffeeLid` and check `status`. Cycle when the user is armed with the lid open:
`"$BIN" off && script/install.sh && open -a KoffeeLid && "$BIN" caffeinate` (restore the mode they had, or
nothing if they were Off). With a Claude Code session working, a fresh launch auto-arms at once (`launched`
then `armed (activity, armed)`); a CLI `arm`/`caffeinate` afterwards takes that arm over as a manual one.
`script/run.sh` installs, launches and tails the log. `script/build.sh [Release|Debug]` builds and prints the
`.app` path.

A runtime smoke that is always safe: launch the Debug app with `KOFFEELID_DISABLE_ACTIVITY=1`, confirm
`launched (pid …)` in the log, quit with the `osascript` line above, confirm `clean termination`. A Debug
instance launched while the installed app runs exits at once (`duplicate-instance exit`).

## Debugging

- The diagnostics log is the primary tool: `~/Library/Application Support/KoffeeLid/diagnostics.log`, rotated to
  `diagnostics.1.log` at 256 KB, guarded by `diagnostics.lock`, shared with the watchdog (lines prefixed
  `watchdog:`). Log through `DiagnosticLog.shared.log` (app) or `DiagnosticFileWriter` (watchdog). Settings ›
  System › Diagnostics silences the app's writer: an empty log usually means it is off. Keep the existing
  phrasing of log lines; `docs/manual-checks.md` greps for them.
- Kernel flag: `ioreg -r -d1 -c IOPMrootDomain | grep -E 'AppleClamshellCausesSleep|AppleClamshellState'`.
  Trust `koffeelid status`, the log and `pmset -g assertions | grep KoffeeLid` over `AppleClamshellCausesSleep`
  alone (`docs/pitfalls.md`).
- `pmset -g | grep SleepDisabled` must read `0` whenever nothing is armed. `1` with the app off means a crashed
  instance left the sleep lock on: `sudo pmset disablesleep 0` (the next launch does it too).
- CLI: the wrapper in `/usr/local/bin`, or `"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" <verb>`.
  `status` is always safe. Prefer the CLI over `open "koffeelid://…"`.
- Settings without the menu bar: `koffeelid settings`, or run the bundle binary with `--open-settings`.
  Onboarding: Settings › System › "Show Onboarding Again", or `defaults delete dev.rubens.koffeelid onboardingCompleted`
  and relaunch. Settings › System › "Reset KoffeeLid…" puts every grant back (the Login Items
  approval is remembered by macOS per team id and may come back as granted).
- French UI: `defaults write dev.rubens.koffeelid AppleLanguages -array fr` (delete it afterwards).
- Watchdog by hand, no Login Items approval needed: run `"…/KoffeeLid.app/Contents/MacOS/KoffeeLidWatchdog" &`
  while the app runs, then `kill -9` the pid from `koffeelid.pid`. Simulate launchd's relative `argv[0]` with
  `(cd / && exec -a Contents/MacOS/KoffeeLidWatchdog "<abs path>")`.
- `swift script/lid-sensor-rate.swift 8` while moving the lid: how often the sensor's value really changes and
  what a read costs.
- Gesture: `gesture: started @…deg (fn via hardware|events)` tells which source saw the modifier;
  `gesture: cancelled (optionLost|reversed|timeout)` explains a miss. `defaults write dev.rubens.koffeelid
  gestureModifier option` switches the key without the UI. A `gesture: started` line while nobody touches the
  modifier means the modifier read is wrong (`docs/pitfalls.md` § The Fn flag is not the Fn key).
- Inspecting the Settings UI without screenshots: launch with `--open-settings`, then read the accessibility
  tree with `osascript` (`tell application "System Events" to tell process "KoffeeLid" to …`; controls live
  inside `scroll area 1 of window 1`).

Log lines worth grepping:

```
launched (pid N) · clean termination · launch: unclean previous exit detected; …
armed (SOURCE, MODE) · disarmed (REASON) · manual off (REASON); the auto-arm holds the session
mode A → B (SOURCE) · arm blocked (SOURCE): REASON
re-applied lid-sleep flag after REASON · lid-sleep flag clear FAILED
sleep lock engaged|released · sleep lock unavailable: …
macOS started a lid sleep behind the arm …; holding the session in dark wake
lid state notification: open -> closed|closed -> open · lid opened; arm stands (MODE)
lid-open lock confirmed · lid-open lock still unconfirmed; giving up
external display connected while armed; standing by · external display disconnected; …
gesture: started|armed via tilt|modifier + close while armed|cancelled (…)|lid reopened …|lid still …
one-close session held on lid open · one-close arm held · one-close session ended on unlock|lid open
effect: capture started|capture stopped|stopped|retracting from N°|following the lid from N°
effect: gesture fold ended; waiting below N° again
activity: running (…)|idle|quiet turn …|hooks look dead for …|no registry record for pid …
auto-armed (activity) · auto-disarm scheduled in Ns · auto-arm ended: local input during the hold-off
built-in Fn reader: reading …|Input Monitoring not granted|no built-in keyboard found|open FAILED
```

## Testing an update without publishing one

`KOFFEELID_UPDATE_FEED` replaces the URL of GitHub's latest-release reply with any `file://` or `http://` URL, and
the `browser_download_url` inside that reply can be a `file://` URL too, so the whole update runs offline:

```bash
# 1. A build to install: bump the three version places in a scratch copy, script/build.sh Release, then
hdiutil create -volname KoffeeLid -srcfolder <folder holding KoffeeLid.app and an Applications symlink> -format UDZO /tmp/KoffeeLid-9.9.9.dmg
# 2. The stand-in reply. "size" and "digest" are optional; when present they are enforced.
cat > /tmp/latest.json <<JSON
{ "tag_name": "v9.9.9", "assets": [ { "name": "KoffeeLid-9.9.9.dmg",
  "browser_download_url": "file:///tmp/KoffeeLid-9.9.9.dmg",
  "size": $(stat -f %z /tmp/KoffeeLid-9.9.9.dmg), "digest": "sha256:$(shasum -a 256 /tmp/KoffeeLid-9.9.9.dmg | cut -d' ' -f1)" } ] }
JSON
# 3. The installed app, started by hand with the stand-in (quit it first, off and lid open: CLAUDE.md § Rules)
KOFFEELID_UPDATE_FEED=file:///tmp/latest.json /Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid
```

The update is only accepted from a build signed by the same team as the running one, and the app replaces the
bundle it runs from: test on the installed copy, not on `DerivedData`. The helper's own log is
`~/Library/Application Support/KoffeeLid/updates/install.log`; `docs/manual-checks.md` § Updates is the walk.

## Safety on this Mac

The installed app is the user's daily driver; see `docs/pitfalls.md` § Working on this Mac. Other utilities that
disable lid-close sleep drive the same kernel flag: quit them before any test that arms, disarms or clears it.
A safe pgrep is `pgrep -fl "KoffeeLid.app/Contents/MacOS/"`.

## How to add things

**A preference.** Register the default in `Preferences.init` and add the accessor (`get { d.… } set {
set("key", …) }`). If the coordinator must react, add a case in `KoffeeLidController.preferenceChanged(_:)`;
`Preferences.onChange` has exactly one subscriber, the coordinator. A Settings page binds it with
`model.binding(\.key)`, which announces the change to SwiftUI itself (`SettingsModel`).

**A user-visible string.** Write `L("Exact English text")`, then add the key to
`App/Resources/Localizable.xcstrings` with an `fr` stringUnit (`state: translated`), in the tone of the
existing French (macOS System Settings vocabulary). No interpolation inside `L()`: use
`String(format: L("… %d …"), …)`. App Intents titles, descriptions and dialogs are `LocalizedStringResource`
literals and use the same catalog. App name + version strings are not localized. Edit the catalog **in place**;
renaming a key means renaming it where `L("…")` is called and in the catalog's key, nothing else. Check
coverage: `grep -rhoE 'L\("[^"]+"\)' App/Sources | sort -u` against the catalog's keys. An
untranslated key is a build warning.

**A settings control.** Start with the `building-settings-pages` skill
(`.claude/skills/building-settings-pages/SKILL.md`): it holds the window's structure, its numbers and how its
words are written, in both languages. The window is `SettingsWindow` (an `NSToolbar` over one
`NSHostingController`); a page is a SwiftUI `Settings…Page` built only from the kit in `SettingsKit.swift`
(`SettingsPage`, `SettingsGroup`, `ToggleRow`, `SegmentedRow`, `SliderRow`, `PopUpRow`, `StatusRow`,
`ButtonRow`); `SettingsModel` gives the bindings onto `Preferences` and the polled states. Pick the page by
subject and the group by what the control governs; a control that depends on a switch sits under it with
`enabled:`. A rule about a state's colour goes in `SettingsStatus` (Core, tested); the Updates group's rules
are `UpdatePanel` (Core, tested). How it looks or reads is judged by the owner in the running app, never by
the agent.

**A permission or a hook row.** Add a case to `SettingsGrant` (Core) with its colour rule and test in
`SettingsStatus`, then a `PermissionItem` to `PermissionCatalog.items` or `HookCatalog.items`: its `id`, title,
why, `required`, a synchronous `granted` closure (cache asynchronous state the way notifications do), button
title and an action that calls `done` when the state may have changed. The onboarding lists it from the catalog;
the Settings page that owns it adds its `StatusRow`, and its `ButtonRow` shown only while it is missing.

**A block reason.** Add the case to `ArmBlockReason` (Core, with tests), handle it in
`KoffeeLidController.notifyBlocked(_:)` and `describe(_:)` (exhaustive switches), add the notification text.

**A CLI / URL verb.** Add the case to `DeepLink` (Core, test the spelling in `SmallPoliciesTests`), handle it in
`KoffeeLidController.perform(_:source:)`, add an App Intent if Shortcuts should have it, update
`CommandLineClient.usage`.

**Core logic.** Test first in `Tests/KoffeeLidCoreTests`, inject `now:` instead of calling `Date()`, Foundation
only.

**An effect tunable.** In this order: the field in `EffectParameters` (default in `default`, range in
`clamped()`, `decodeIfPresent … ?? Self.default.x` in `init(from:)` so stored settings keep decoding); its tests
in `EffectParametersTests`; the maths in `PlaneRemap` with tests in `PlaneRemapTests`; the same maths in
`PlaneShader.source` and the value in `PlaneUniforms` (field order must match the MSL `Uniforms` struct); a
`SliderRow` in `SettingsLidEffectPage` with its `fr` string; the defaults row in
`docs/functional.md` and the Reset item in `docs/manual-checks.md`. Then check the shader offline.

**Tuning the effect's look without the lid.** The plane is `PlaneRemap` plus four Gaussian levels, so a CPU
render of the same formulas shows what the shader draws: blur a still with `CIGaussianBlur` at σ = 2, 6, 16,
40 × height/1000, then per display pixel apply `remap`, `coverage`, `shade` and the four-level blend at a few
fold angles and compare. One 1440 × 900 render takes about a second with `swiftc -O`.

**Testing the activity feature.** Set `KOFFEELID_DISABLE_ACTIVITY=1` in a Debug app's environment: it shares
UserDefaults and the activity journal with the installed app. Fake one Claude Code turn:
`echo '{"hook_event_name":"UserPromptSubmit","session_id":"fake"}' | /Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook`
(arms if the activity switch is on; the fake event carries no pid, so only a matching `Stop` or staleness ends
it). Run `koffeelid install-hooks` only from `/Applications/KoffeeLid.app`: it writes the absolute path of the
binary that ran it. The timings in `ActivityConstants` were sized from recorded Claude Code sessions; change
them only against new recordings.

**A collaborator.** One file, one system API, closures back to the coordinator (`onX`), an `onLog` closure if
it can fail, a `deinit` that tears down any C callback holding an unretained `self`. Wire it in
`KoffeeLidController.start()` and tear it down in `shutdown()`. It calls back on the main thread.

## Icons

The menu-bar glyph and the app icon are two separate pieces of artwork of the same mug. They are not
generated from each other: a change to one is a change to one.

**The menu-bar glyph** is `App/Sources/MugShape.swift`, whose path constants are the `d` attributes of
`App/Resources/Glyphs/mug-off.svg`, `mug-auto.svg`, `mug-armed.svg`, `mug-caffeinate.svg` (viewBox 325 × 244,
even-odd fill): the shared `cup`, one eye string per armed state, and the `liquid` ellipse in every state but
off. To change it: edit the SVGs, paste the new `d` strings into `MugShape` (the parser handles M L H V C A Z),
update `MugShape.box` if the cup bounds moved, and rebuild. Glyph size and vertical offset live in
`StatusItemController.mugImage` (22 pt wide, template image).

**The app icon** is `App/Resources/AppIcon.icon`, an Icon Composer document (Xcode ships Icon Composer.app
under Xcode › Open Developer Tool). It holds `icon.json` and three 1024 × 1024 layers in `Assets/`:
`0_background.png` (the espresso gradient), `1_coffee.svg` (the coffee surface, `#9A5A2E`) and `2_cup.svg`
(the armed cup in `#FFF4E6`, `glass: true`, opacity 0.85, its rim, handle and eyes even-odd holes). The
group carries a neutral shadow at 0.5 and translucency 0.3. `actool` compiles it into `Assets.car` as a
layer stack plus pre-rendered sizes and an `AppIcon.icns` fallback, so macOS 26 and later draw it with the
system mask, shadow and specular glass while older systems get the flat rendering.

`project.yml` reaches it as **one file reference**, not as the four files inside: `App/Resources` excludes
`AppIcon.icon`, and a second `sources` entry adds `App/Resources/AppIcon.icon` with `type: file`. Without
that, XcodeGen walks into the directory, `actool` never sees a document, and the app ships with no icon.
`ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon`, matching the bundle's base name.

To change it: edit the layers in Icon Composer (or replace the files), `script/bootstrap.sh` only if the set
of files changed, then rebuild. To refresh the README image, take the 256 px rendering out of the built app:

```bash
iconutil -c iconset DerivedData/Build/Products/Debug/KoffeeLid.app/Contents/Resources/AppIcon.icns -o /tmp/AppIcon.iconset
cp /tmp/AppIcon.iconset/icon_128x128@2x.png docs/assets/icon.png
```

## Release checklist

1. `swift test` green, `xcodebuild` warning-free.
2. Bump the version in `App/Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`),
   `KoffeeLidCore.version` and `SmokeTests`; adjust the README test badge if the count changed.
3. `script/install.sh`, approve Login Items and grant Screen Recording if asked, quit and reopen.
4. Walk `docs/manual-checks.md` with any other lid-sleep utility quit.
5. `script/release.sh` (sources `script/signing.env`; refuses early without the Developer ID Application
   certificate for the Wooflab team or the `wooflab-notary` notarytool profile in the keychain) archives,
   exports with Developer ID, verifies the export, zips and notarizes the app, staples it, calls
   `script/make-dmg.sh` to build and sign the disk image, notarizes and staples the image, asserts Gatekeeper
   accepts both, and prints the image's path. It publishes nothing itself. One-time setup, by the Wooflab
   team's Account Holder: the Developer ID Application certificate in the keychain, then
   `xcrun notarytool store-credentials wooflab-notary --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer
   <ISSUER_ID>`.
6. Commit (`feat|fix|build|docs(scope): …`), `git tag -a vX.Y.Z -m "KoffeeLid X.Y.Z"`,
   `git push origin main vX.Y.Z`, `gh release create vX.Y.Z <image path> --title "KoffeeLid X.Y.Z" --notes-file
   …`. The installed copies update themselves from that release, which holds it to a contract: a tag that
   parses as a version, one asset whose name ends in `.dmg` with `KoffeeLid.app` at the image's root, a
   `CFBundleShortVersionString` strictly newer than the versions it replaces, and a signature from the same
   team as theirs.

## Known limitations

- The effect's stream needs 150–300 ms to start; the still image bridges the gap, so a very fast slam shows the
  plane only for its last part. Capture is capped at 2560 px on the long side.
- The lock on reopen relies on the private `SACLockScreenImmediate`; if it disappears the app notifies and gives
  up after five retries.
- macOS runs the Globe key's "Press 🌐 key to" action on release when nothing else was pressed; set it to
  Do Nothing if the emoji picker appears after the gesture.
- The shortcuts are fixed at ⌃⌥⌘L and ⌃⌥⌘K; Settings only switches each on or off. `hotKeyCode`,
  `hotKeyModifiers`, `caffeinateHotKeyCode` and `caffeinateHotKeyModifiers` are read by `HotKeyController` and
  can be changed with `defaults write`.
- `/usr/local/bin` is usually root-owned, so `script/install.sh` prints the `sudo` one-liner for the `koffeelid`
  wrapper instead of writing it. The wrapper is a zsh `exec` of the bundle binary.
- Without the sudoers rule every arm logs `sleep lock unavailable` and only the dark-wake hold protects a closed
  Mac from a charger or display change. While the lock is on, idle sleep and the Apple menu's Sleep are off too.
