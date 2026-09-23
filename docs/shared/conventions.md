# Conventions

How every macOS app of this family is built, and why. Where the four older apps disagree with the family's
answer, the last section says so; a new app follows the family's answer, which is what `template/` in
`~/Projects/macos-app-template` implements.

## 1. Project layout and build

| | The family's answer |
|---|---|
| Build system | SwiftPM, **no Xcode project**. `swift build` is the truth; editor diagnostics are frequently stale. |
| Swift tools version | **5.10**, Swift 5 language mode. |
| Deployment target | **macOS 26.0**, spelled `.macOS("26.0")` (tools 5.10 has no `.v26`). Not lower: SwiftPM records the target as the binary's SDK version and AppKit draws the Liquid Glass design only for a recorded SDK of 26 or later (`pitfalls.md`). |
| Dependencies | **none**, ever. |
| Targets | a pure `<App>Core`, an I/O `<App>Platform`, the app `<App>App`, a dev tool under `Tools/` that never ships (an Accessibility probe), and one XCTest bundle per library. A CLI is a fourth executable target only when the app has state to drive from a key binding. |
| Layering | dependencies point one way: Core ← Platform ← App. **Core is Foundation (+ CoreGraphics) only and never reads a clock**; `PurityTests` fails the build otherwise. |
| Scripts directory | **`scripts/`**, POSIX `/bin/sh`. |
| Tests | **XCTest**. `swift test` prints one summary line per bundle: count them. |
| `.gitignore` | `.build/`, `build/`, `*.xcodeproj`, `.swiftpm/`, `.DS_Store`, `*.swp`, `.claude/.cc-writes/`. |
| Claude configuration | `.claude/settings.local.json` turns the Bash sandbox off (`swift build`, `swift test`, `codesign`, the privacy database and `open` all fail inside it). No skills in the repository: the family's live in `~/.claude/skills/macos-*`. `CLAUDE.md` sits at the root. |

## 2. The app itself

- **AppKit owns the run loop**, not SwiftUI: `NSApplication.shared`, an `AppDelegate`, and
  `setActivationPolicy(.accessory)` stated in code as well as by `LSUIElement`, so a binary run out of
  `.build` is an accessory too. A `MenuBarExtra` scene cannot be added and removed as a setting changes
  (`pitfalls.md`).
- **The status item** is rebuilt from scratch on every open (`menuNeedsUpdate`), so it is never a language
  or a state behind, and its visibility follows one setting that is *observed* rather than pushed.
- **Menu order**: the feature's own state first, a separator, Launch at Login, a separator, the read-only
  status lines, a separator, `Settings…` (⌘,), a separator, `Quit <App>` (⌘Q).
- **The menu-bar mark is drawn in code** from a template `NSImage`, 18 pt, `isTemplate = true`, the same
  drawing as the app icon's mark.
- **A main menu is installed even though it is never seen**: an accessory app gets ⌘Q and ⌘W only through
  `NSApplication.mainMenu`.
- **Opening the bundle again opens Settings** (`applicationShouldHandleReopen`), which is the one way back
  when the icon is hidden, unless the wizard is up (it takes precedence) or has not been walked (it opens
  instead). A launch that was a login item's or an installer's opens nothing: `QuietLaunch` marks the
  installer's, and the open-application Apple event marks the login item's.
- **The language is read once, at launch**, from the system's preferred language, into `Loc.language`,
  before any window, menu or status item is built. English is the fallback for everything that is not
  French.
- **Logging** is `os.Logger` under the bundle identifier, one category per surface (`app`, `update`,
  `onboarding`, one per feature), deliberately sparse: what is otherwise invisible, at `notice` or above.
  **Silence is a defect**: anything that declines to act says why, once, with the numbers.

## 3. The Settings window

`macos-building-settings-pages` is the authority; `template/Sources/ExemplarApp/SettingsKit.swift` and
`SettingsWindow.swift` are the reference copies every app carries verbatim.

- A real `NSWindow` + `NSToolbar`, `toolbarStyle = .preference`, one selectable item per page, symbol above
  title. Never a SwiftUI `Settings` scene, never a `TabView`.
- Content width **640**; not resizable; **the height follows the shown page**, animated around the
  top-left corner, capped at `visibleFrame.height - 140`.
- **A page is a column of groups. A group is a title, a card of rows, and under the card, outside it, a
  hint, then warnings, then notes. A row is a control and its label and nothing else.**
- Pages: **General first**, then the features in the order a user meets them, then **System**, then
  **Health**, then **Tip last**. (That is the order all four apps draw; a document that says otherwise is
  wrong.)
- General is, in order: the app icon alone at 144 pt; **Startup** (Launch at login, Show in menu bar, one
  note naming the way back); **Updates**; **Quit**; **Uninstall**.
- **System** is what the app needs from the OS and the controls that give it: permissions (each a status
  row, with its button and warning only while missing), conflicts with the OS's own features, compatibility
  switches, and **Start over** (Show Onboarding Again). A state with nothing to press beside it is on Health.
- **Health** says at a glance whether the app works, and it is **two tables and nothing else**. **Health**:
  the checks, each green, orange or red and never blue, then **Check Again** as the card's last row, and
  under the card the warnings of the lines that are orange or red. A check is something that has to be in
  place or running for the app to work: every permission and every setup the wizard asks for (a hook, a
  rule, an agent), the service, listener or sensor the feature rests on. A check with nothing to say while
  it is fine (a flag that must hold while armed, a failure count, a crash in the last 7 days, the one line
  every app ends with) is a line only while it is wrong. **Information**: at most 5 blue readings worth
  having beside the checks (the last hook event, the lid angle, the last snap). **Never on it**: a
  preference, whichever way it is set (launch at login, a feature's own switch, a macOS setting that does
  not stop the app), the version and updates (General's), the battery, heat, memory, uptime, where the app
  is installed or the macOS version, unless one of them is the app's own job. Usually about five checks,
  never more than 10 with everything wrong at once (`HealthLimits`, held by a test). It reports and changes
  nothing. The lines are built in Core from plain values (`HealthFacts` → `HealthReport.checks(for:)` and
  `readings(for:)`) and tested.
- **One colour rule on every page**: green as it should be; blue a reading, or a state that is the user's own
  choice on the page that owns it (Health never shows one); orange not as it should be while the app still does its job (an optional permission or setup
  missing, a feature on that cannot work, a crash this week); red, with the stop sign, what stops the app
  from doing its job (a permission or setup the wizard marks `required`, the mechanism down). A grant reads
  the same on System and on Health (`HealthRules.grant(held:required:)`).
- **Tip** is the tip jar, its own page and the same in every app: a card with no title carrying the app
  icon and one sentence, then **One-time tip** with the Ko-fi cup and a button naming the smallest tip
  (`SupportLink.smallestTip`, 5 €, `https://ko-fi.com/bambidotexe`). Its two cards hold pictures and words
  rather than controls, the one place the row rule is set aside, and the owner asked for it.
- A state is always a `StatusRow` with one of five marks (green check, blue info, orange triangle, **red
  stop sign** `xmark.octagon.fill`, spinner) and **one word** from a fixed vocabulary (Granted/Denied,
  Enabled/Disabled, Available/Missing, Valid/Invalid, Failed).
- Every number is in `SettingsMetrics`; none of them is an agent's to retune.
- The copy rules: default size only, **no long dash anywhere a user reads**, a key is its symbol then its
  name (⇧ Shift, ⌘ Command), a hint earns its place or is deleted, buttons are Title Case verbs.
- The kit is the union of what the four apps needed: `ToggleRow`, `SegmentedRow`, `TileRow`, `SliderRow`,
  `PopUpRow`, `StatusRow`, `ButtonRow`. A slider and a pop-up were the owner's choices for one app each; a
  new one is still the owner's to decide.

## 4. Updates, end to end

Identical in every app, and carried whole (`Core/Update*.swift` + `Platform/Update*.swift` +
`App/UpdateController.swift`, `UpdateNotifier.swift`, `UpdateWindow.swift`):

1. **The check** is an anonymous `GET https://api.github.com/repos/<owner>/<repo>/releases/latest`. 404
   means *no release published*, not a failure. A release must carry a tag that parses as a version and an
   asset ending in `.dmg`.
2. **The schedule**: once shortly after launch, then a week after the last answer, re-asked at every wake;
   a failed check is retried after an hour. Nothing is persisted.
3. **The Updates group** is one `StatusRow("<App> <version>")` and **one** button, no hint. The button
   reads *Check for Updates* until a release is known and then *Update*, prominent and blue.
4. **The update window** ("Software Update") fetches the image, checks its length and SHA-256, mounts it,
   copies the app out, and holds it against the running one (same bundle id, strictly newer, runs on this
   macOS, **signed by the same team**), all while the app is still up.
5. **Install and Relaunch** starts a detached `/bin/sh` helper and quits through `NSApp.terminate`. The
   helper waits for the pid, renames the old bundle aside, renames the new one in, starts it, and **puts
   the old one back if the new version is not seen running**. It leaves one line in a result file that the
   next launch reads and shows.
6. Releases are **GitHub releases carrying the `.dmg`**; the check is anonymous, so the repository has to
   be public for it to see anything.

## 5. Quit, uninstall, launch at login

- **Quit** is a `ButtonRow` with `role: .destructive` in a group of its own titled *Quit*, at the bottom
  of General but above Uninstall, and it goes through `NSApplication.terminate` so that
  `applicationWillTerminate` runs. ⌘Q reaches it through the invisible main menu. No confirmation.
- **Uninstall** is the last group of General: a hint saying what goes, a permanent **warning** that
  dragging the app to the Trash leaves the rest behind, and one destructive button that asks first with an
  `NSAlert`. It removes the system registrations *while the bundle they name still exists* (`tccutil
  reset` for each permission, the login item), leaves the notification authorization where macOS keeps
  it (`pitfalls.md` X3: no public API puts it back), moves the bundle to the **Trash** (not a delete),
  and hands the preferences and the Application Support folder to a **detached helper that waits for
  this pid**, because `cfprefsd` writes the domain back out as the process exits.
- **Launch at login** is `SMAppService.mainApp`, and the switch shows *the system's* answer, re-read after
  every attempt; nothing is mirrored into the settings file. An app that must survive a crash unnoticed
  uses a plain launch agent plist bootstrapped with `launchctl` instead (my-sidepulse), which is both "open
  at login" and "restart on crash"; `macOS.md` and `pitfalls.md` say what that costs.

## 6. Permission onboarding

`macos-building-onboarding` is the authority; `template/Sources/ExemplarApp/OnboardingWindow.swift`,
`GrantCatalogue.swift` and `ControlActionHandler.swift` are the reference copies.

- A titled, closable, fixed 540 wide window, an **ordinary** level and collection behaviour, stepping
  through a hero page, one list page per set of grants, and a final page.
- **Only a row's button ever asks macOS for a permission.** Nothing at launch, and the reader
  (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, `IOHIDCheckAccess`, `getNotificationSettings`,
  `SMAppService…status`) is never the asker.
- A row's title is **what System Settings calls the switch**, quoted from the pane's own loctable in both
  languages, and it is looked up again rather than remembered.
- One 2 s poll while the window is up, owned by the window; a row that moves redraws its own trailing
  control, never the page.
- `NSApp.activate(ignoringOtherApps: true)` **to open** that window and Settings: measured on macOS 27,
  the cooperative `activate()` cannot bring an accessory app forward. Coming back afterwards is
  `makeKeyAndOrderFront` alone.
- The System and Health pages report each permission live while the window is open, from a 2 s poll the
  *window* starts and stops (`SystemStatus`), never a view's `onAppear`; Health's own readings are taken
  when the window shows it and on Check Again, never on a timer (`HealthCheck`).

## 7. Signing, notarizing, packaging, release

One pipeline, carried whole:

- `scripts/signing.env` — **the one place the app's identity is written**: `TEAM_ID` (`85F6AC5QZF`, the
  Wooflab team), `NOTARY_PROFILE` (`wooflab-notary`), `APP_NAME`, `BUNDLE_ID` (`dev.rubens.<App>` unless
  the app has a domain of its own), `GITHUB_REPO` (`bambidotexe/<folder>`), `DMG_ACCENT`. Tracked, holds
  no secret: the certificate's private key and the notary credentials are in the keychain, and the identity
  is looked up by team id. `make-app.sh` writes the name, the identifier and the repository into the built
  `Info.plist` (the repository as `AppUpdateRepository`), and `Core/AppIdentity` reads them back, so the
  app never spells its own name out.
- `scripts/version.sh` — **the version rule**: a local install always builds and installs exactly the
  tree's own version. `scripts/publish.sh <patch|minor|major>` is the only thing that moves it: it bumps by
  that level, commits and pushes the bump before it builds anything, then releases exactly that version.
  Nothing bumps it again afterward. The version lives in exactly one line, `VERSION="…"` in
  `scripts/make-app.sh`.
- `scripts/make-app.sh` — assembles the bundle, compiles the Icon Composer document with `actool` when full
  Xcode is there, writes `Info.plist` and the two `.lproj/InfoPlist.strings`, and signs innermost-first
  with `--options runtime --timestamp`. Refuses an ad-hoc build without `DEBUG_OK=1`.
- `scripts/make-dmg.sh` — `dmgbuild` in a throwaway venv, a backdrop drawn by
  `scripts/dmg-background.swift`, a volume icon taken from the built app by
  `scripts/dmg-volume-icon.swift`, the layout in `scripts/dmg-settings.py`.
- `scripts/release.sh` — build → verify the signature, the runtime flag and the entitlements → notarize
  the app → staple → image → sign and notarize the image → staple → `spctl` on both. Publishes nothing.
- `scripts/publish.sh <patch|minor|major> --notes=<file>` — refuses before the version bump without
  release notes, and publishes the file as the release's description, as it is.
- `scripts/install.sh` / `scripts/publish.sh` — **the only two ways a build reaches a Mac**, and neither
  leaves a `.app` or a `.dmg` anywhere under the repository, on any exit path (`scripts/no-leftovers.sh`).
  `install.sh` stops the running copy (`pkill`; an app with state to put back, or a launch agent, stops
  more gently and says so), writes the quiet-launch marker, `ditto`s the bundle out of the mounted image,
  verifies its signature, version and ticket, and opens it. A `Makefile` names them `make install` and
  `make release LEVEL=…`.
- **Not sandboxed**, Hardened Runtime on, `get-task-allow` never shipped. One-time setup by the Wooflab
  team's Account Holder: the Developer ID Application certificate in the keychain, and `xcrun notarytool
  store-credentials wooflab-notary --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>`.

## 8. Icon and assets

`Resources/AppIcon.icon`, an **Icon Composer** document (`icon.json` + `Assets/`), compiled by `actool`
into `Assets.car`, plus a flat `.icns` rasterised from a 1024 px master (`Resources/previews/`) with `sips`
and `iconutil`. Never hand-edit `icon.json` except to re-export. `docs/assets/icon.png` is the 256 px
rendering the README shows. `Resources/ICON-NOTES.md` says what replacing the icon means. The menu-bar mark
and the icon's mark are the same drawing.

## 9. Documents

`workflow.md` lists them. **Comments and documents state the present.** No dates, no versions, no
attributions, no account of what the code replaced; history belongs in git and, for traps only, in
`docs/pitfalls.md`.

## 10. Code style

- One type per file, named after it. `Core` holds the rules and `Platform` the single call that touches
  the system; a name says what the thing *is* to the user, not what pattern it uses.
- **Doc comments carry the reason**, often several sentences, and they state rules, invariants,
  measurements and platform constraints. A number in the code is accompanied by the evidence for it.
- **Every sentence the user reads** goes through a string table, in English **and** French, added
  together or not at all: `Core/Localization.swift` (`Language`, `Loc`) plus one
  `Core/Strings<Surface>.swift` per surface, with one accessor `switch`ing over `Language`.
  `LocalizationTests` reads every accessor and the tables off disk: no long dash, keys with their symbol,
  the app's name never spelt out.
- Errors fail safe and say so; nothing swallows a failure quietly.
- Every device, tab, window and process is known by identity (a bundle id and a pid, an inode), never by
  name or path.

## 11. Commits

Conventional commits, lower case, the subject saying **why** rather than what:
`feat(settings): a Support group with a Ko-fi button`, `fix(update): the launch after an install is the
helper's, whatever version wrote it`, `build(version): the tree moves to 1.1.1`. One commit per task,
**files staged by path, never `git add -A`**, and the attribution trailers from the session's system
reminder.

## 12. Where the older apps differ

The family's answer above is the template's. These are the exceptions the four existing apps keep, so
that an agent working in one of them is not surprised; a document in one of those apps describes its own
way where it differs.

| | koffeelid | snappy-snap | my-sidepulse | shiftpick |
|---|---|---|---|---|
| Build | **XcodeGen** (`project.yml`, never the xcodeproj) for the app and two helper tools; SwiftPM for the two libraries | SwiftPM | SwiftPM | SwiftPM |
| Swift | 5 mode, deployment target **macOS 15** | **6.2, strict concurrency**; swift-testing (`#expect`) | 5.10 | 5.10 |
| Scripts | `script/` (singular), **zsh** | `Scripts/` (capital), **zsh** | `scripts/`, sh | `scripts/`, sh |
| Version | three places kept in step by `script/version.sh` (`Info.plist`, `KoffeeLidCore.version`, a smoke test) | a tracked `Resources/Info.plist` | `VERSION=` in `make-app.sh` | `VERSION=` in `make-app.sh` |
| Strings | `L("key")` + `Localizable.xcstrings`, edited in place | `L("English")` + `.lproj/Localizable.strings` per target | `Strings*.swift` tables | `Strings*.swift` tables |
| Extra targets | a watchdog LaunchAgent and a hook tool, embedded | `Tools/axprobe` | a CLI in the same bundle | `Tools/axdump` |
| Launch at login | `SMAppService.mainApp` + a bundled agent for the watchdog | `SMAppService.mainApp` | **a plain launch agent plist** bootstrapped with `launchctl` (restart on crash) | `SMAppService.mainApp` |
| Stopping the running copy on install | refuses while quitting would sleep the Mac; restores the arm | `osascript … to quit`, then `pkill` | `launchctl bootout`, never a signal | `pkill` |
| Manual checklist | `docs/manual-test-checklist.md` | `docs/manual-test-checklist.md` | `docs/manual-test-checklist.md` | `docs/manual-test-checklist.md` |
| Update feed override | `KOFFEELID_UPDATE_FEED` | `SNAPPYSNAP_UPDATE_FEED` | `MYSIDEPULSE_UPDATE_FEED` | `SHIFTPICK_UPDATE_FEED` |
| Repository key in `Info.plist` | (the repository is a literal in the code) | (a literal) | (a literal) | `SPUpdateRepository` |
