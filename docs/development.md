# Development guide

## Environment

- macOS 14+ target; developed on macOS 26 with Xcode 26 / Swift 6.3 (Swift 5 language mode).
- XcodeGen (`brew install xcodegen`) generates `KoffeeLid.xcodeproj` from `project.yml`; `script/bootstrap.sh`
  installs it if missing and generates. Re-run after adding, removing or moving files under `App/Sources`,
  `App/Resources` or `Watchdog/Sources` (they are globbed).
- Signing is automatic with the "Apple Development: Rubens NUNZI" identity of the Wooflab team (`75MADVD27T`
  in `project.yml`). Hardened Runtime on, no App Sandbox (IOKit user clients, private frameworks and `pmset`
  are not sandbox-compatible).
- The Metal shader is a Swift string compiled at runtime; a syntax error only shows as
  `PlaneRenderer: pipeline failed` in Console and `effect: no built-in display or Metal unavailable` in the log,
  at the next arm. Syntax-check it offline after every edit (the Metal Toolchain is installed):

  ```bash
  sed -n '/^    static let source = #"""$/,/^    """#$/p' Sources/LidPlaneKit/PlaneShader.swift | sed '1d;$d' > "$TMPDIR/plane.metal" \
    && xcrun -sdk macosx metal -c "$TMPDIR/plane.metal" -o "$TMPDIR/plane.air" && echo shader ok
  ```
- **Claude Code's sandbox** (2026-09-12): `swift test` and `xcodebuild` fail inside it (`Invalid manifest` /
  "authorization denied" on SwiftPM's manifest cache under `~/Library/Caches`), and so do image and video
  decoders that go through system services (HEIC wallpapers, `AVAssetImageGenerator` on a screen recording:
  `Cannot Decode`). Run those commands with the sandbox off (`/sandbox`, or per command); everything under
  the repo is fine inside it. `$TMPDIR` differs inside and outside the sandbox, so build throwaway tools in the
  session scratchpad, not in `$TMPDIR`.

## Daily loop

```bash
swift test                                   # fast, hermetic
script/bootstrap.sh                          # only when files were added/removed
xcodebuild -project KoffeeLid.xcodeproj -scheme KoffeeLid -configuration Debug \
  -derivedDataPath DerivedData build 2>&1 | grep -E 'error|warning:|BUILD'
open -a "DerivedData/Build/Products/Debug/KoffeeLid.app"
tail -f "$HOME/Library/Application Support/KoffeeLid/diagnostics.log"
osascript -e 'tell application id "dev.rubens.koffeelid" to quit'
```

`script/install.sh` does a Release build into `/Applications/KoffeeLid.app`, quitting the running instance and
its watchdog first — but it **refuses while `koffeelid status` is not `mode: off`** (`FORCE=1` overrides), because
quitting an armed app ends the user's session. Typical cycle when the user is armed with the lid open:
`"$BIN" off && script/install.sh && open -a KoffeeLid && "$BIN" caffeinate` (restore whatever mode they had).
`install.sh` does not launch the app: once on 2026-09-12 it came back on its own ~9 s after the clean
termination, once it did not — always `open -a KoffeeLid` and check `status` (`KoffeeLid is not running`).
With a Claude Code session working, a fresh launch **auto-arms at once** (`launched` then `armed (activity,
armed)`); a CLI `arm`/`caffeinate` afterwards takes that arm over as a manual one, and leaving it alone lets
it end on its own, so "restore the mode" means: send the verb the user had, or nothing if they were Off.
`script/run.sh` installs, launches and tails the log. After moving the repo folder, `rm -rf DerivedData .build`
(stale-path warnings / module-cache errors otherwise).

## Debugging

- The diagnostics log is the primary tool: `~/Library/Application Support/KoffeeLid/diagnostics.log`
  (rotated to `diagnostics.1.log` at 256 KB, guarded by `diagnostics.lock`, shared with the watchdog whose
  lines are prefixed `watchdog:`). Debug builds mirror to `NSLog`.
- Kernel flag state: `ioreg -r -d1 -c IOPMrootDomain | grep -E 'AppleClamshellCausesSleep|AppleClamshellState'`.
  `AppleClamshellCausesSleep` has been observed to stay `No` after a successful clear with no app armed (it seems to be
  re-evaluated on lid events); trust `koffeelid status`, the log and `pmset -g assertions` over that single value.
  Assertions: `pmset -g assertions | grep KoffeeLid`.
- CLI: `koffeelid status | arm | off | caffeinate | toggle-armed | toggle-caffeinate | settings` (the wrapper in
  `/usr/local/bin`, or the bundle binary directly). `status` prints `mode: … · lid: … [· standing by (external display)]`.
  Caffeinate is visible in `pmset -g assertions | grep KoffeeLid` as `PreventUserIdleDisplaySleep` plus a
  `UserIsActive "KoffeeLid: caffeinate"` while the lid is open.
- Settings without the menu bar: `koffeelid settings` (or `"…/KoffeeLid.app/Contents/MacOS/KoffeeLid" --open-settings &`).
  Settings is one page; "Advanced settings…" opens a second window with every tunable. Onboarding: Advanced ›
  Show onboarding again (or `defaults delete dev.rubens.koffeelid onboardingCompleted` and relaunch). To test
  it as a first run, Advanced › Reset permissions and undo every change… puts every grant back (the Login Items
  approval is remembered by macOS per team id and may come back as granted).
- Diagnostics: Advanced › App › Diagnostics log switch; an empty `diagnostics.log` usually means it is off.
- French UI: `defaults write dev.rubens.koffeelid AppleLanguages -array fr` (delete it afterwards).
- Watchdog by hand (no Login Items approval needed): run
  `"…/KoffeeLid.app/Contents/MacOS/KoffeeLidWatchdog" &` while the app runs, then `kill -9` the app's
  pid from `koffeelid.pid`. Simulate launchd's relative argv[0] with `(cd / && exec -a Contents/MacOS/KoffeeLidWatchdog "<abs path>")`.
- `swift script/lid-sensor-rate.swift 8` while moving the lid: how often the sensor's value really changes
  (decides whether polling above 30 Hz is worth it; see `docs/architecture.md` § Smoothness).
- Screen Recording denied → `effect: screen recording not granted; effect stays off` in the log and arming
  still works. TCC grants are per bundle path. The main page shows the status (Granted / Not granted + Allow…).
- Gesture tuning: `gesture: started @…deg (fn via monitor|hardware)` tells which key path saw the modifier;
  `gesture: cancelled (optionLost|reversed|timeout)` explains a miss. `defaults write dev.rubens.koffeelid
  gestureModifier option` switches the key without the UI.
- Inspecting the Settings UI without screenshots (the terminal has no Screen Recording grant): launch with
  `--open-settings`, then read the accessibility tree with `osascript`, e.g.
  `tell application "System Events" to tell process "KoffeeLid" to get size of window 1` and
  `click button "Réglages avancés…" of scroll area 1 of window 1` (controls live inside `scroll area 1`).

## Safety on this Mac

Other utilities that disable lid-close sleep drive the same kernel flag. Before any test that arms, disarms,
or clears it, quit them (or accept that `AppleClamshellCausesSleep` cannot be interpreted). Never signal
processes by bare name; a safe pgrep is `pgrep -fl "KoffeeLid.app/Contents/MacOS/"`.

The **installed app is the user's daily driver**. `AppleClamshellCausesSleep = No` is usually *its* arm.
Run `koffeelid status` first; if it is armed (or the lid is closed), do not quit,
reinstall or send `off` — that ends the user's session and can sleep a closed Mac. `script/install.sh`
quits the running dev app: only run it when `koffeelid status` says `mode: off`.

A second instance (the DerivedData build) launched while the installed app runs exits at once
(`AppDelegate` finds the other pid before `start()`, log line `duplicate-instance exit`), so it cannot clear the
flag under the user's session; the hazard only exists if that guard is ever removed.

`pmset -g | grep SleepDisabled` must read `0` whenever nothing is armed. `1` with the app off means a
crashed instance left the sleep lock on; run `sudo pmset disablesleep 0` (the next app launch does it too).

## How to add things

**A preference.** Register the default in `Preferences.init` and add the accessor (same `get { d.… } set { set("key", …) }`
pattern). If the coordinator must react, add a case in `KoffeeLidController.preferenceChanged(_:)`. Bind it
in a page inside `f.group { g in g.row(L("…"), SettingsForm.switch(…)) }` — capture `[prefs]` or `[weak self]`, never the control.

**A user-visible string.** Write `L("Exact English text")`, then add the key to
`App/Resources/Localizable.xcstrings` with an `fr` stringUnit (`state: translated`), matching the tone of the
existing French (macOS System Settings vocabulary: « Réglages », « rabattre l’écran »). App Intents titles/descriptions/dialogs are `LocalizedStringResource` literals and use
the same catalog. Edit the catalog **in place** (a text replacement, or an entry inserted next to its
alphabetical neighbour): Xcode's key order is not a plain sort, so loading the JSON and writing it back sorted
turns a two-key change into a 180-line diff. Renaming a key means renaming it where `L("…")` is called, in the
catalog's key and in nothing else (the `fr` value stays). Check coverage:
`rg -o 'L\("([^"]+)"\)' -r '$1' --no-filename App/Sources | sort -u` versus the catalog's top-level keys.

**A settings control.** Put it in `SettingsViewController` only if a first-time user needs it; everything else
goes in `AdvancedViewController`. Both subclass `PaneViewController` and build once in `build(_ f: SettingsForm)`:
`f.header`, `f.group { g in g.row(label, control…) / g.sliderRow / g.labelledSlider }`, `f.note`, `f.link`.
`labelledSlider` returns a `SliderHandle`; keep it only when another control must move that slider
(`set(value)`), as the two "Start below" sliders do — never rebuild the page from inside a slider's action,
the knob being dragged would be replaced under the cursor.
The window height follows `preferredContentSize` (capped to the screen; the page scrolls beyond). Keep the
existing density: 13 pt text, small controls, one control per row. See `docs/architecture.md` §"Settings UI".

**A permission.** Add a `PermissionItem` to `PermissionCatalog.items` (`App/Sources/UI/Permissions.swift`):
title, why, `required`, a synchronous `granted` closure (cache asynchronous state the way notifications do),
button title and an action that calls `done` when the state may have changed. Both the onboarding page and
Settings › Permissions pick it up; add the strings to the catalog with `fr`.

**A block reason.** Add the case to `ArmBlockReason` (Core, keep tests), handle it in
`KoffeeLidController.notifyBlocked(_:)` and `describe(_:)` (exhaustive switches) and add the notification text to the catalog.

**A CLI / URL verb.** Add the case to `DeepLink` (Core, test the spelling in `SmallPoliciesTests`), handle it
in `KoffeeLidController.perform(_:source:)`, and add an App Intent in `Intents/KoffeeLidIntents.swift` if
Shortcuts should have it too (intent strings go in the catalog with an `fr` entry). Update `CommandLineClient.usage`.

**Core logic.** Write the test first in `Tests/KoffeeLidCoreTests`, inject `now:` instead of calling
`Date()`, keep Foundation-only.

**An effect tunable.** Six places, in this order: the field in `EffectParameters` (default in `default`,
range in `clamped()`, and `decodeIfPresent … ?? Self.default.x` in `init(from:)` so stored settings keep
decoding — the keys of the first geometry stay required so older shapes fall back to `default`); its tests in
`EffectParametersTests` (default, clamp, decoding without the key); the maths in `PlaneRemap` with tests in
`PlaneRemapTests` **before** the shader; the same maths in `PlaneShader.source` and the value in
`PlaneUniforms` (`PlaneRenderer.draw`, field order must match the MSL `Uniforms` struct); a `labelledSlider`
in `AdvancedViewController` › Lid effect with its `fr` string; the Reset list in `docs/manual-checks.md` and
the tuned-defaults line in `CLAUDE.md`. Check the shader offline (Environment above) — the app compiles it at
runtime, so `xcodebuild` cannot catch a typo.

**Tuning the effect's look without the lid.** The plane is `PlaneRemap` plus four Gaussian levels, so a CPU
render of the same formulas shows exactly what the shader will draw. What worked on 2026-09-12 to match
Apple's foldable: grab frames of the reference video with `AVAssetImageGenerator` (no ffmpeg on this Mac;
`requestedTimeToleranceBefore/After = .zero`, sixteen evenly spaced times, sandbox off), build a fake lock
screen (a stock wallpaper from `/System/Library/Desktop Pictures/*.heic` with a big "9:41"), blur it with
`CIGaussianBlur` at σ = 2, 6, 16, 40 × height/1000 (the renderer's levels), then per display pixel apply
`remap`, `coverage`, `shade` and the four-level blur blend from the shader at 25°, 45°, 57° and montage the
results next to the reference frames (`NSImage` drawing, `NSBitmapImageRep` → PNG). One render of 1440 × 900
takes a second with `swiftc -O`. The constants 0.35 / 0.08 / 0.55 in `PlaneRemap` came from that sheet; the
user then tuned the defaults on the real lid (gesture start 95°, perspective 40 %).

**Testing the activity feature.** Set `KOFFEELID_DISABLE_ACTIVITY=1` in the Debug app's environment before a
runtime smoke: `ActivityMonitor` shares UserDefaults and `~/Library/Application Support/KoffeeLid/activity.jsonl`
with the installed app, so a Debug launch without it would auto-arm (or disarm) the real session's activity
state. Fake one Claude Code turn without Claude Code itself:
`echo '{"hook_event_name":"UserPromptSubmit","session_id":"fake"}' | /Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook`
— arms if "While Claude Code or a terminal command is running" is on in Settings; the fake event carries no
pid, so nothing watches it and only staleness (2 h) or a matching
`echo '{"hook_event_name":"Stop","session_id":"fake"}' | … KoffeeLidHook hook` ends it. `koffeelid
install-hooks` writes the absolute path of *the binary that ran it* (`ActivityMonitor.hookBinaryURL`,
resolved from `Bundle.main`) into `~/.claude/settings.json`, so always run it from
`/Applications/KoffeeLid.app` — running it from a DerivedData build points every hook at a path the next
Debug rebuild deletes. `~/.claude/settings.json` is the user's own file: `install-hooks`/`uninstall-hooks`
always back it up first to `~/.claude/settings.json.backup-koffeelid` before writing.

**A collaborator.** One file, one system API, closures back to the coordinator (`onX`), an `onLog` closure
if it can fail, `deinit` that tears down any C callback holding an unretained `self`. Wire it in
`KoffeeLidController.start()` and tear it down in `shutdown()`.

## Icons

- Menu bar glyph and app icon share `App/Sources/MugShape.swift`, whose path constants are the `d` attributes
  of `App/Resources/Glyphs/mug-off.svg`, `mug-auto.svg`, `mug-armed.svg`, `mug-caffeinate.svg` (viewBox
  325 × 244, even-odd fill): the `cup` sub-paths every file shares, then one eye string per armed state, plus the
  `liquid` `<ellipse>` drawn over the rim's hole in every state but off. To change the artwork: edit the SVGs,
  paste the new `d` strings into `MugShape` (the parser handles M L H V C A Z), update `MugShape.box` if the cup
  bounds moved (print `MugShape.path(from: MugShape.cup).bounds` in a `swift` script), update `liquid` if the
  ellipse moved, then `script/make_icon.sh` (regenerates `AppIcon.appiconset` from the armed cup; copy
  `icon_256x256.png` to `docs/assets/icon.png`) and rebuild. The script pastes `MugShape.swift` in front of its
  own renderer, so the two can never drift. The SVGs' `fill-opacity="0.85"` is ignored: the glyph is drawn opaque.
- Glyph size and vertical offset: `StatusItemController.mugImage` (22 pt wide, the cup being wider than tall;
  centred on the bar with no extra canvas). Template image; the status item tints it.
- Previews without screenshots: render the glyphs to a PNG with a small `swift` script (paste `MugShape.swift`,
  draw into an `NSBitmapImageRep`) and view the PNG.

## Release / install checklist

1. `swift test` green, `xcodebuild` warning-free.
2. Bump the version in `App/Info.plist` (`CFBundleShortVersionString`), `KoffeeLidCore.version` and
   `SmokeTests`; adjust the README badges if counts changed.
2b. For other people: `script/release.sh` (archive → Developer ID export → notarize → staple → zip; prints the
   zip path last). Ship `dist/KoffeeLid-<version>.zip`; recipients unzip, move to /Applications, and the
   onboarding asks for the rest. The CLI for them is `/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid <verb>`.
3. `script/install.sh`, then approve the app in System Settings › General › Login Items (watchdog + launch at
   login; Settings › Advanced settings… › Crash recovery › Open Login Items) and grant Screen Recording from
   Settings › Permissions › Screen Recording › Allow…; quit and reopen the app.
4. Walk `docs/manual-checks.md` with any other lid-sleep utility quit.
5. Commit, `git tag -a vX.Y.Z -m "KoffeeLid X.Y.Z"`, `git push origin main vX.Y.Z` (remote
   `git@github.com:bambidotexe/koffeelid.git`, SSH). No `gh` CLI: create GitHub Releases in the browser.

## Known limitations

- The effect's stream needs ~150–300 ms to start; the instant still frame bridges the gap, so a very fast
  slam shows the plane for only its last part. Capture is capped at 2560 px on the long side.
- The lock-on-reopen relies on the private `SACLockScreenImmediate`; if it disappears the app notifies and
  gives up after five retries.
- Distribution needs the Wooflab team (`75MADVD27T`, the paid one; `project.yml` `DEVELOPMENT_TEAM`).
  Dev builds sign with *Apple Development* and only run on this Mac (Gatekeeper: `spctl -a -vv` says
  rejected). `script/release.sh` produces the shippable build: Developer ID Application signature, hardened
  runtime, notarized and stapled, as `dist/KoffeeLid-<version>.zip`. One-time setup: create a *Developer ID
  Application* certificate for Wooflab (Xcode › Settings › Accounts › Manage Certificates; Account Holder or an
  allowed Admin) and store notary credentials once:
  `xcrun notarytool store-credentials koffeelid-notary --apple-id <apple id> --team-id 75MADVD27T`
  (app-specific password from appleid.apple.com). Changing the team id re-asks Screen Recording, Login Items
  and notifications once on this Mac.
- The lid gesture watches the Fn/Globe key (`NSEvent.ModifierFlags.function`, `CGEventFlags.maskSecondaryFn`) by
  default; `gestureModifier = option` switches back. macOS runs the Globe key's "Press 🌐 key to" action on
  release when nothing else was pressed, so the emoji picker may appear after the gesture unless that option is
  set to Do Nothing.
- The shortcuts are fixed at ⌃⌥⌘L (Armed) and ⌃⌥⌘K (Armed + screen on); Settings only switches each on or off. `hotKeyCode`/`hotKeyModifiers` and
  `caffeinateHotKeyCode`/`caffeinateHotKeyModifiers` are still read by `HotKeyController` (change them with
  `defaults write` if another app claims a combo) but have no UI.
- `/usr/local/bin` is root-owned on this Mac, so `script/install.sh` prints the `sudo` one-liner for the
  `koffeelid` wrapper instead of writing it. The wrapper only needs creating once; it points at
  `/Applications/KoffeeLid.app`, which every install replaces in place.
- The sleep lock (`pmset disablesleep`, the only thing that stops macOS sleeping a closed armed Mac when
  the charger or a display changes — `docs/platform-notes.md`) needs root. Settings › Permissions › Sleep lock ›
  Set up… (and the onboarding step) install the one-time sudoers rule through the administrator-password
  dialog (`SleepLockSetupAction` → `SleepLock.installRule()`: `/etc/sudoers.d/koffeelid`, mode 0440,
  validated with `visudo -cf` before it lands, exactly the two `pmset disablesleep 1|0` commands);
  `script/install.sh` prints the same rule as a terminal one-liner. Until it exists every arm logs
  `sleep lock unavailable` and only the dark-wake hold protects the session. While the lock is on, idle sleep and the Apple menu's Sleep are off too — that is the point
  of being armed.
