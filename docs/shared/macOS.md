# The macOS every app of the family runs on

The platform facts every app leans on, as measured on the owner's Mac (Apple silicon, macOS 27.0, build
26A428). An app's own `docs/macOS.md` holds only what is that app's own and never repeats this file.
`pitfalls.md` is the companion: the facts that look otherwise until measured.

## Process model

- One process, an `LSUIElement` accessory: no Dock icon and no main window. The entry point is a plain
  AppKit `@main` that sets `.accessory` and calls `NSApplication.run()`; the status item is an
  `NSStatusItem` the app adds to and removes from `NSStatusBar.system`. A main menu is installed and never
  shown, purely so ⌘Q and ⌘W keep working while a window is key.
- **An accessory application is re-opened, not re-launched.** Opening the bundle again while it runs
  delivers `applicationShouldHandleReopen(_:hasVisibleWindows:)` rather than starting a second process. A
  cold launch delivers `applicationDidFinishLaunching` instead, and the open-application Apple event it can
  read there carries `keyAELaunchedAsLogInItem` under `keyAEPropData` when `SMAppService` is the launcher
  and nothing when a person is. `NSAppleEventManager.shared().currentAppleEvent` holds that event only
  until the app handles one of its own, so it is read first or not at all. A cold user open cannot
  otherwise be told from launchd's: both get no arguments and the same `XPC_SERVICE_NAME`; only
  LaunchServices' `parentASN` differs, and it has no public API. Reopen is the one reliable "the user asked
  for the app" signal.
- A second instance terminates itself at launch.
- No sandbox: the one entitlement is `com.apple.security.app-sandbox = false`. The things these apps do
  (event taps, the Accessibility API, IOKit user clients, private frameworks, `sudo`, a removable volume)
  are not things a sandbox allows. Hardened Runtime is on; an app that sends Apple events also needs
  `com.apple.security.automation.apple-events`, which the runtime refuses them without whatever the user
  allowed under Automation.

## Windows and activation

- **An accessory app is not brought forward by the cooperative `NSApp.activate()`**: measured on macOS 27,
  it left the window behind the one it opened over. Every window these apps show uses
  `activate(ignoringOtherApps: true)` **to open**, and nothing but that: once a window is up, coming back
  to the front is `makeKeyAndOrderFront` alone. Activating after a button has handed the user over to
  System Settings is what drops a window on top of the pane it just opened.
- **macOS gives an ordinary app the front back when the app it handed over to quits, and skips
  `LSUIElement` apps doing so.** There is no flag for it. The onboarding wizard watches for System Settings
  quitting itself (`FocusReturnWatch`, `NSWorkspace.didTerminateApplicationNotification`; System Settings
  quits when its window closes), and the wait is bounded so that an unrelated visit there an hour later does
  not pull the window forward. A dialog of the app's own (an administrator password through `NSAppleScript`)
  is drawn by SecurityAgent and blocks the main thread; when it closes an accessory app is not reactivated
  either, so a flow that owned such a dialog takes activation back itself when it ends.
- An accessory app with **no window left is still the active application**, which sends the user's
  keystrokes nowhere. Every window hands activation back on close *and* on miniaturise, which never fires
  `windowWillClose`.
- A `MenuBarExtra` scene cannot be added and removed as a setting changes: it re-reads `isInserted` only
  when SwiftUI re-evaluates the scene. The status item is `NSStatusItem`, released back to
  `NSStatusBar.system` to hide it, because an item merely hidden keeps its slot.
- A SwiftUI `Settings` scene cannot bring an accessory forward (`.onAppear` fires once per scene, not per
  open); the Settings window is an ordinary `NSWindow` the delegate owns.
- `NSScreen.main` is nil with no key window; sizing falls back to the first screen.
- `NSWindow.level = .floating` sits above every app, including System Settings and the administrator
  dialog the app's own buttons open; `.moveToActiveSpace` re-inserts a window at the **back** of the new
  Space's window list. Neither is set on any ordinary window of these apps.

## Launch, login and reinstall

- **Launch at login** is `SMAppService.mainApp`. Its state lives there and nowhere else: the user can
  remove the app in System Settings without opening it, so a copy kept in the settings file could only
  disagree. `register()` can fail (an unsigned or un-bundled build), so the switch is read back rather than
  assumed. It needs the user's approval in System Settings › General › Login Items
  (`SMAppService.Status.requiresApproval` until then). Approval lives in Background Task Management, keyed
  by bundle id **and** team id; there is no per-app reset (`sfltool resetbtm` wipes every app's), and an
  approval survives an uninstall, so a reinstalled bundle re-registers silently.
- **A reinstall is not a person asking for a window.** `scripts/install.sh` writes a marker
  (`~/Library/Application Support/<App>/quiet-launch`) before anything can start the app, and the first
  launch that finds it opens nothing (`Core/QuietLaunch`). It lapses after two minutes, so one left behind
  by an install that died cannot silence a launch by hand.
- **A launch agent** (my-sidepulse) is a plain plist in `~/Library/LaunchAgents`, `RunAtLoad`,
  `KeepAlive.SuccessfulExit = false`, bootstrapped with `launchctl bootout` then `bootstrap`; that one
  registration is both "open at login" and "restart on crash". launchd restarts a dead process, not a hung
  one. An app started by `open` is nobody's job: `KeepAlive` supervises only the instance launchd spawned,
  so the app hands itself over (a detached helper waits for the pid and runs `launchctl kickstart`). The
  running instance is stopped with `bootout`, never a signal: SIGTERM is a non-zero exit, which is exactly
  what `SuccessfulExit = false` restarts. `launchctl disable` is permanent and is never written anywhere.
  `SMAppService.agent` pins a launch constraint to the bundle and leaves a record that goes stale on
  reinstall; the plist carries neither. `pitfalls.md` has the incidents.
- launchd starts a `BundleProgram` agent with a relative `argv[0]` and `/` as working directory; a tool
  resolves its own path with `proc_pidpath`.
- When a launchd job's main process exits, launchd kills whatever is left in the job's process group. Apps
  opened through LaunchServices are launchd jobs too. A helper that must outlive the app is spawned with
  `POSIX_SPAWN_SETPGROUP` and group 0, no inherited descriptors and an environment of the app's making
  (`DetachedProcess`); never a plain `posix_spawn`, never a shell `&`.

## Permissions

- **A grant is called, in the app, exactly what System Settings calls it**, quoted from the pane's own
  `Localizable.loctable` in both languages. The user has to find the switch in a list, so a name of the
  app's own is a dead end however accurate it reads. As of macOS 27:

  | The app calls | The row is titled | French | Quoted from |
  |---|---|---|---|
  | `AXIsProcessTrustedWithOptions` | Device Control and Data Access | Contrôle de l’appareil et accès aux données | `SecurityPrivacyExtension.appex`, key `ACCESSIBILITY` |
  | `SMAppService.mainApp.register()` | Open at Login | Ouvrir avec la session | `LoginItems.appex` |
  | `SMAppService.agent(...).register()` | Background App Activity | Activité des apps en arrière-plan | `LoginItems.appex` |
  | `CGRequestScreenCaptureAccess` | Screen Recording | Enregistrement de l’écran | `SecurityPrivacyExtension.appex`, key `SCREEN_CAPTURE` |
  | `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` | Input Monitoring | Surveillance de l’entrée | the same, key `LISTEN_EVENT` |
  | `UNUserNotificationCenter.requestAuthorization` | Notifications | Notifications | |
  | a sudoers rule, a privileged helper, anything of the app's own | the app's own name for it | | there is no system switch to match |

  ```bash
  ls /System/Library/ExtensionKit/Extensions | grep -i -E 'login|privacy|security|notification'
  F=/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable
  plutil -extract en xml1 -o - "$F" | grep -A1 '<key>ACCESSIBILITY</key>'
  plutil -extract fr xml1 -o - "$F" | grep -A1 '<key>ACCESSIBILITY</key>'
  ```

  Two traps in the lookup: a pane holds several switches (Login Items shows *Open at Login* **and**
  *Background App Activity*), and a loctable keeps retired names (`SCREEN_CAPTURE` and
  `SCREENANDAUDIOCAPTURE` are two grants; the API the app calls decides which). Read the table again after
  a macOS release: `ACCESSIBILITY` stopped reading "Accessibility" once already.
- **Reading a grant and asking for it are two different calls, and they are never swapped.** Readers:
  `AXIsProcessTrusted()`, `CGPreflightScreenCaptureAccess()`, `IOHIDCheckAccess(...)`,
  `getNotificationSettings`, `SMAppService…status`. Askers: `AXIsProcessTrustedWithOptions([prompt: true])`,
  `CGRequestScreenCaptureAccess()`, `IOHIDRequestAccess(...)`, `requestAuthorization(...)`, `register()`.
  A request API returns **the state at the moment of the call**, still not-granted while the user is
  looking at the dialog, so its result says nothing about an answer and nothing branches on it. Once a
  grant is explicitly denied macOS shows no dialog at all and the call returns the denial; the refusal is
  remembered for good. Login Items has no dialog: `SMAppService.openSystemSettingsLoginItems()` is the only
  flow there is.
- The system's dialog carries its own button to the right pane, so the app never opens a pane beside it,
  and never instead of it once the grant has been refused. Panes are opened by URL only from a Settings
  button while the grant is missing: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`,
  `x-apple.systempreferences:com.apple.Desktop-Settings.extension`.
- **`com.apple.accessibility.api`** is posted on the distributed notification centre when the privacy
  database changes: how a grant given or taken away reaches a running app with no timer. It can arrive a
  moment before the process is really trusted, which is why the wizard also polls while it is up.
- **Grants are per code identity and per bundle path.** A stable Developer ID signature keeps them across
  reinstalls; an ad-hoc signature gives the app a new identity on every build and loses every grant. A
  DerivedData or `build/` copy and the `/Applications` copy are different apps to TCC and to Background Task
  Management. Changing the signing team asks for every grant again.
- A **command-line tool inherits the Accessibility grant of the terminal that starts it**, which is how a
  probe under `Tools/` reads the app's own windows, or Finder's, before the app itself is allowed to.
- Resets: `tccutil reset Accessibility|ScreenCapture|ListenEvent <bundle id>`, which must run while the
  bundle still exists and exits non-zero when it had nothing to reset; the notification grant lives in
  `group.com.apple.usernoted`'s preferences (`apps[]`, `bundle-id`) and no public API puts it back, so the
  entry is dropped and `usernoted` and `NotificationCenter` restarted; preferences with `defaults delete`.
- A usage string (`NS…UsageDescription`) is read by macOS from the bundle, not from the running app, so it
  ships in `Info.plist` and in each `.lproj/InfoPlist.strings`: the one piece of user-facing text the
  Swift string tables cannot hold. Accessibility has no such key.

## Updates: disk images, signatures, the helper

- GitHub's anonymous `GET /repos/<owner>/<repo>/releases/latest` lists each asset with `size` and
  `digest: "sha256:<hex>"`, and `browser_download_url` answers 302 to a 200 that carries `content-length`.
  A repository that is private, or has no release, or only drafts and pre-releases, answers 404. 403 (rate
  limit) and every other status are failures and say so; only 404 reads as "nothing there".
- `URLSession.downloadTask` reports no error for an HTTP error status: it hands over the error page as
  the downloaded file. The status is checked before anything is moved, and a saved file is held against
  the length and the SHA-256 GitHub stated before anything opens it.
- A file the app fetches itself is not quarantined (the bundle does not set `LSFileQuarantineEnabled`), so
  the copy taken out of its disk image opens without a Gatekeeper prompt whether or not the release is
  notarized. Releases are notarized and stapled anyway, for a copy fetched by a browser, which does
  quarantine.
- `hdiutil attach <dmg> -nobrowse -readonly -noautoopen -mountpoint <folder>` mounts a release's one
  volume on a folder of our choosing, so nothing of its output is parsed. On macOS 27 it still works and
  prints a deprecation notice naming `diskutil image attach --readOnly --nobrowse --mountPoint <folder>`,
  which the stager falls back on. `hdiutil detach <folder> -force` unmounts; `diskutil eject` is the
  fallback, and `diskutil eject <plain folder>` names the volume the folder sits on, which is the Mac's
  own, so only a folder whose device differs from its parent's is detached.
- `FileManager.copyItem` out of the mounted image keeps the bundle's signature valid.
  `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSCheckNestedCode |
  kSecCSStrictValidate` is what `codesign --verify --deep --strict` checks. The requirement `anchor apple
  generic and certificate leaf[subject.OU] = "<team>"` holds for an Apple Development and for a Developer
  ID certificate of one team alike; a copy from another signer fails with `errSecCSReqFailed`, a tampered
  one with `errSecCSBadResource`. `SecCodeCopySigningInformation` gives the running app's team, and none
  for an ad-hoc build, which then has no signer to compare with. **An update from the same team keeps
  every grant.**
- Moving a bundle is one `rename(2)` when source and destination are on the same volume, which is why
  the update is unpacked under Application Support and refused when the app lives on another volume.
- `ps -axo comm=` prints each process's full executable path, which `grep -Fx` matches exactly: that is
  how the helper sees the new version running without matching by name. An app reached through a
  symbolic link (`/tmp` is one) runs under its resolved path, so the helper looks under the installed path
  and under `pwd -P` of it. `kill -0` still answers for a process that has exited and not been reaped
  (state `Z`).
- `UNUserNotificationCenter.current()` traps in a process with no bundle, which a binary run out of
  `.build` is. A notification's action button belongs to its `UNNotificationCategory`; with `.foreground`
  the click brings the app forward. Both the button and a click on the notification reach
  `userNotificationCenter(_:didReceive:withCompletionHandler:)`, the second as
  `UNNotificationDefaultActionIdentifier`, off the main actor. A centre with no delegate shows nothing while
  its app is frontmost; with one, `willPresent` decides per notification. The permission is kept per
  bundle identifier.

## The uninstall

- `tccutil reset <Service> <bundle id>` gives a grant back, and it has to run **while the bundle it names
  still exists**.
- **`cfprefsd` writes a preferences domain back out as the process exits, whatever happens.** Removing the
  plist from inside the app leaves an empty one where a Mac that never had the app has no file at all. The
  removal goes to a detached helper that waits for the pid, along with the Application Support folder, the
  caches, the HTTP storages and the saved window state named after the bundle identifier.
- The bundle goes to the Trash (`NSWorkspace.recycle`), not to a delete.

## Language

- The preferred languages are read once, at launch (`Locale.preferredLanguages.first`); changing them
  while the app runs changes nothing until it is reopened. The tag is BCP-47, so the primary subtag decides:
  `fr`, `fr-FR` and `fr-CA` are French, `fry` is not.
- **`CFBundleLocalizations` in the main bundle, and one `.lproj` directory per language, are what put the
  app in System Settings › General › Language & Region › Applications.** Without them the per-app override
  is not offered. A per-app override is stored as `AppleLanguages` in the app's own defaults domain, so
  `defaults write <bundle id> AppleLanguages '("en")'` forces one language for the next launch and
  `defaults delete` returns the app to following the system.
- A `.xcstrings` String Catalog is compiled by an Xcode build step; with no Xcode project it would be
  copied into the bundle uncompiled and resolve to nothing. The family's answer is Swift string tables; the
  one app on `.strings` catalogues passes `bundle: .module`, never `.main`, because SwiftPM puts resources
  in per-target bundles, and a missing translation there reads as English silently.

## Bundle and signing

`scripts/make-app.sh` assembles:

```
Contents/Info.plist                              generated; name, identifier, version, repository
Contents/PkgInfo                                 APPL????
Contents/MacOS/<App>                             the one executable (a CLI beside it, if any)
Contents/Resources/AppIcon.icns                  flat icon, behind CFBundleIconFile
Contents/Resources/Assets.car                    Liquid Glass icon, behind CFBundleIconName
Contents/Resources/{en,fr}.lproj/InfoPlist.strings
```

- `Info.plist` carries `LSUIElement`, `LSMinimumSystemVersion 26.0`, `NSHighResolutionCapable`,
  `NSPrincipalClass NSApplication`, `CFBundleLocalizations` (`en`, `fr`), and `CFBundleShortVersionString`
  = `CFBundleVersion` = `VERSION`.
- `actool` lives in full Xcode, not the Command Line Tools; without it the app still builds with the flat
  icon and no glass. `actool`'s own `.icns` carries 16 px and 128 px only, so the `.icns` is rasterised
  from the 1024 px master, which bakes in the rounded mask an `.icns` needs and macOS does not apply.
- `Contents/MacOS` sits on a case-insensitive volume: `MySidepulse` and `mysidepulse` are one file, which
  is why that app's GUI binary keeps its build-product name. Only `CFBundleExecutable` has to match.
- Signing is innermost first (a nested binary, then the bundle with its entitlements), with
  `--options runtime --timestamp` for a real identity; ad-hoc (`SIGN_IDENTITY="-"`) gets neither and cannot
  be notarized. `get-task-allow` (injected by an Apple Development identity) lets any same-user process take
  the app's task port and act under its grants; Release builds never carry it, and `release.sh` refuses one
  that does.
- `xcrun notarytool history --keychain-profile <profile>` is the credential check; it has failed spuriously
  between two runs ten minutes apart with nothing changed. Run it again before diagnosing.

## The release disk image

Finder does not scale a disk image's background: it draws it at natural size from the top-left of the
icon view's content area, and its own bars (title, tab, status/path) can cover up to about 120 points at
the bottom of the window. The canvas `scripts/dmg-background.swift` renders is 660×480 with every mark
inside the top 340 points and a plain field below, matching the window `scripts/dmg-settings.py` lays out
(660×480 at (200,200), 128 px icons, the app at (165,246) and `Applications` at (495,246), labels at the
bottom, no sidebar, toolbar or status bar). The background is rendered at 1× and 2× and combined into one
Retina TIFF with `tiffutil -cathidpicheck`, the one file Finder reads a Retina background from. The
Finder/AppleScript way of setting a layout needs an Automation grant and fails silently without one, which
is why `dmgbuild` writes the layout straight into the image's `.DS_Store`. The volume's icon is not the
bundled `.icns` (a flat stand-in) but what `NSWorkspace` renders for the built app.

## Working on the owner's Mac

- **Claude Code's sandbox** breaks `swift build`, `swift test`, `codesign`, anything that asks the privacy
  database (`AXIsProcessTrusted()` answers false inside it), `open` (LaunchServices error −600), and system
  image and video decoders. Every app ships `.claude/settings.local.json` with the sandbox off. `$TMPDIR`
  differs inside and outside it.
- **`log` is a shell function in the owner's zsh profile.** `log show …` fails with `too many arguments`;
  call `/usr/bin/log`. `log show` has returned nothing for an app at any level where `log stream` did:
  start the stream before reproducing.
- **A Claude turn that dies when the Thunderbolt dock is unplugged is a network event, not a sleep.** The
  dock carries the primary Ethernet interface; an API stream in flight cannot migrate to Wi-Fi.
- Never `open` a folder from an agent shell: it navigates the user's own frontmost Finder window.
