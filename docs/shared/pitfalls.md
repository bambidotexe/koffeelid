# Pitfalls every app of the family shares

What looked right on macOS and was not, with the measurement that settled it, gathered from the four apps.
**This is the only shared document that records approaches that failed.** Each entry says what you see,
why it fails, what the code does instead, and how not to repeat it; the app it was measured in is named.
An app's own `docs/pitfalls.md` holds only what is that app's own and points here for the rest.

Every number was measured on an M-series Mac running macOS 27.0 (build 26A428).

---

## Event taps and the grant

### E1. An enabled tap that can swallow, a grant taken away, and a callback that enables it again
- **Symptom.** No click and no key reaches anything, anywhere, until the power button is held down.
- **Why.** A `.defaultTap` sits in the path of every event it subscribes to, and the window server waits for
  its answer. When its owner loses the Accessibility grant while it is enabled, the callback stops being run
  and the events are still routed into it: each one waits, until macOS disables the tap and says so with
  `tapDisabledByTimeout`. That disable is the only net there is, and a callback that answers it by enabling
  the tap again cuts it.
- **What holds.** A tap that can swallow is enabled only for as long as it has to be (shiftpick: only while
  ⇧ Shift is held), a `.listenOnly` tap does the rest, a tap macOS disabled is never enabled by the event
  that says so, and a few timeouts inside a minute destroy the taps until the user asks for another try.
  Enabling a `.listenOnly` tap again from its callback is safe, and snappy-snap does it: the window server
  never waits for a listener. On a tap that can swallow, it is this entry.
- **Rule.** Never reproduce it by trying it. A walk that takes a grant away from an app holding a tap runs
  behind a dead-man's switch started first, which kills the app after a set time whatever happens (shiftpick's
  `scripts/drill.sh`): a process that dies takes its taps with it. An agent never takes a grant away. (shiftpick)

### E2. A tap its own app disables is told it was disabled "for user input"
- **Symptom.** A breaker counting the times macOS took a tap away opened within a millisecond of the first
  launch, with nothing wrong and nobody touching anything.
- **Measured.** `CGEvent.tapEnable(tap:enable: false)` delivers `tapDisabledByUserInput` to that tap's own
  callback, at every call, even on a tap already disabled: the reason macOS also gives when it turns a tap off
  itself.
- **What holds.** Only a timeout is a trip. A user-input disable heard while the app believes the tap is off is
  its own echo: nothing is done, above all not a second disable, which is heard back in turn. **The tap API's
  pseudo-events are not what their names say**: a rule built on one needs the event measured. (shiftpick)

### E3. A tap is born enabled
- **What holds.** `CGEvent.tapCreate` returns an enabled tap. One that must start off is disabled in the line
  after it is created, before its port is on any run loop. (shiftpick)

### E4. A tap served by the main run loop stalls input whenever the interface stalls
- **Why.** A callback is run by the run loop its source was added to. On the main one, every layout, alert,
  SwiftUI update and wait on the main thread is a wait for every event the tap holds up.
- **What holds.** Taps have a thread of their own that does nothing else, never calls Accessibility and never
  waits without a deadline. Work goes to a worker, and **the budget is kept by whoever waits**, not by the
  work: a worker that checks its own clock can be stuck in the one call that never returns. (shiftpick)

### E5. `AXIsProcessTrusted()` says yes for seconds after the grant has gone
- **Symptom.** A permission row reads *Granted* under a switch the user has just turned off, and anything gated
  on the answer stays on.
- **Measured.** It is an answer the system keeps for the process: right at launch, late after
  `com.apple.accessibility.api`, seen saying yes for seconds after the switch went off, and refilled by a round
  trip with no timeout.
- **What holds.** Nothing that can hold up input is enabled on it. A live question is asked instead, off any
  tap's thread: one attribute of the Dock with a 50 ms messaging timeout, where `apiDisabled` is a refusal,
  any answer is a grant and a timeout says nothing. A row shows the grant as missing from the moment the app
  has found it gone itself (`macos-building-onboarding`). (shiftpick)

## Onboarding

### O1. A window that floats to stay reachable covers what it sent you to
- **Symptom.** The wizard sits on top of the System Settings window and the administrator dialog its own
  buttons open, hiding the instructions it just gave.
- **Why.** `NSWindow.level = .floating` is above every other app, and `NSApp.activate(ignoringOtherApps:
  true)` pulls the app in front of whatever it has just launched. Both were there because an `LSUIElement`
  app is not reactivated when System Settings or a password dialog closes.
- **What holds.** The wizard is a normal window and the app is activated once, when it opens. It is
  reachable again three other ways: it comes forward on `didBecomeActiveNotification` while it is the app's
  only window, `applicationShouldHandleReopen` prefers it over Settings, and the rows follow System Settings
  by polling rather than by needing the window back in front. (koffeelid)
- **Rule.** Reachability and z-order are different problems. Never raise a level or call
  `activate(ignoringOtherApps:)` to keep a window findable.

### O2. `.moveToActiveSpace` costs the window its z-order
- **Symptom.** The wizard opens in front of the terminal. Switch to another Space, come back, and it is
  *behind* the terminal.
- **Why.** The flag pulls the window to whichever Space is active and re-inserts it at the back of that
  Space's window list. `.fullScreenAuxiliary` is the same kind of exception.
- **What holds.** No `collectionBehavior` at all on any ordinary window. Only a desktop overlay that really
  belongs on every Space overrides it. (koffeelid)

### O3. Closing System Settings does not give a menu-bar app its window back
- **Symptom.** A grant button opens System Settings, the grant is made, System Settings is closed, and the
  wizard is now behind the terminal.
- **Why.** macOS hands the front back to whatever was in front before the app that quit, and skips
  `LSUIElement` apps doing it.
- **What holds.** `GrantItem.mayOpen` names the app a flow can send the user to, and `FocusReturnWatch`
  waits for that app's `didTerminateApplicationNotification` and brings the window back once, within
  `K.focusReturnWait` (300 s). **Set `mayOpen` on every macOS grant**, not only the ones whose button opens
  a pane: the system's own dialog carries a button to System Settings too. (koffeelid, snappy-snap)
- **Rule.** Not by activating when the flow reports back: it reports back while System Settings is still
  coming up, which is O1.

### O4. A modal dialog of the app's own still leaves an accessory app deactivated
- **Symptom.** The administrator dialog, the password accepted, and the wizard is behind the terminal.
- **Why.** `NSAppleScript … with administrator privileges` is drawn by SecurityAgent and blocks the main
  thread; when it closes macOS reactivates an ordinary app, not an `LSUIElement` one.
- **What holds.** `GrantItem.returnsFocus` marks a flow that puts up its own dialog and waits for it, and
  such a flow alone reclaims activation when it ends. Never give it to a flow that hands over to System
  Settings or a system prompt. (koffeelid)

### O5. A poll that rebuilds the page blanks it
- **Symptom.** The Permissions page goes blank and draws itself again, once every time a grant moves and
  once on every press.
- **Why.** The page was rebuilt wholesale; the replacement only appears at the next layout pass. Comparing
  the grants first and rebuilding "only when one moved" does not help: the flicker is the rebuild.
- **What holds.** A page is built on a change of step and at no other time. Each row owns its trailing
  control and swaps that alone, after comparing what it shows with what it should show. A row whose flow is
  still running keeps its loading state (the button disabled with a spinner beside it) until the flow
  reports back, or the next tick takes the spinner away underneath the user. (koffeelid)

### O6. A grant named anything but what System Settings calls it
- **Symptom.** The row says "Login Items", the user opens the pane, and it has *Open at Login* and
  *Background App Activity*, with the app listed under both.
- **Why.** The row was named after the pane, and after the pane's older name at that. A permission row is
  a pointer into a list the user has to scan.
- **What holds.** Every row is titled with the system's own string, quoted from the pane's loctable
  (`macOS.md` *Permissions* has the command and the table). `ACCESSIBILITY` reads **Device Control and Data
  Access** on macOS 27, and no key in that table answers "Accessibility" any more; the word the user came
  looking for goes in the line under the title. (koffeelid, shiftpick)
- **Rule.** Never name a grant from memory, and never pick between two loctable keys by guessing which is
  live: the API the app calls decides (`SCREEN_CAPTURE` versus `SCREENANDAUDIOCAPTURE`).

### O7. A permission asked without a click
- **Symptom.** The notification prompt appears at launch, with nothing on screen to explain it. The user
  refuses, and the app can never ask again.
- **Why.** The start-up path asked for authorization "once onboarding was done", or `UpdateNotifier` asked
  the first time an automatic check found a release. Anyone who reached the end of onboarding without
  granting still had the grant at `notDetermined`. macOS remembers a refusal for good.
- **What holds.** Nothing asks but a row's button. State is read with the preflight or check call, never
  with the request call, which also prompts: behind a 2 s poll that is a prompt every two seconds.
  (koffeelid, my-sidepulse)

### O8. A grant request and a System Settings pane, both at once
- **Symptom.** One press of "Allow…" and the user gets the system permission dialog *and* System Settings,
  one over the other.
- **Why.** `CGRequestScreenCaptureAccess()` shows the dialog and returns the state as it is *now*, still
  not granted, so `if !request() { openSystemSettings() }` opens the pane every single time.
- **What holds.** A grant action calls the request API and stops there; the dialog's own button is the way
  to System Settings. (koffeelid)

### O9. An `NSStackView` spacer with no intrinsic height absorbs every point of a page's slack
- **Symptom.** The wizard's stepping button, at the bottom right of a list page, looking perfectly
  ordinary, and **unclickable for ever**. It starts the moment a permission is granted.
- **Why.** The footer was `NSStackView(views: [spacer, primary])` with a width constraint and no height
  constraint. A bare `NSView` has no intrinsic size, so the enclosing vertical stack handed the footer every
  point the page was not using. Granting a permission swaps a row's 26 pt button for an 18 pt "Granted"
  label, the list shrinks by 36 pt, and the slack goes into the footer: measured at **460 × 186 instead of
  460 × 24**, the button floating in the middle of it. No constraint breaks, `AXFrame` names a plausible
  rectangle, `AXPress` works; only a real click misses.
- **What holds.** The footer is a plain `NSView` with the button pinned to its trailing edge **and to both
  its top and bottom**; the slack goes to a view of its own between the list and the footer, with vertical
  hugging and compression resistance at **priority 1**. `OnboardingMetrics` decides sizes, and a stack view
  left free to decide one will. (snappy-snap; shipped in koffeelid, my-sidepulse and shiftpick from the
  skill's reference file)
- **Rule.** A trap fixed in a window and not in the reference copy is a trap that ships again. The
  template is the reference copy. The instrument: `swift run axprobe elements <app>` and `axprobe hit x y`;
  a frame that names a rectangle where the hit test finds nothing is this bug. The `onboarding` log
  category at `--level debug` prints `DOES NOT CONTAIN` up the chain.

### O10. SwiftUI text in a hosting controller does not wrap on its own
- **Symptom.** A hand-written window came out 460 × 205 with three one-line texts, two truncated.
- **Why.** A hosting controller sizing itself is free to propose a width no window has, and a `Text` with
  no `fixedSize(horizontal: false, vertical: true)` will take it.
- **What holds.** The settings kit does this on every row; the AppKit wizard sets
  `preferredMaxLayoutWidth` on every label. The trap belongs to any new SwiftUI window built outside the
  kit. (shiftpick)

## The Settings window

### S1. A `Toggle` is a switch inside a grouped `Form` and a checkbox outside one
- **Why.** On macOS a bare `Toggle` has no fixed appearance: `.formStyle(.grouped)` gives its descendants
  the switch style and the trailing placement, and outside that context AppKit's default is a checkbox.
- **What holds.** No page depends on a `Form`'s context. Every switch is the kit's `ToggleRow`, which
  fixes both halves itself. (snappy-snap)
- **Rule.** A control's appearance is a property of where it is, and the only way to know is to look at it
  in the running app beside the one it must match.

### S2. A `MenuBarExtra`'s `isInserted` binding is read once, at launch
- **Symptom.** *Show in menu bar* changed the setting and the icon stayed.
- **Why.** `isInserted` is read when SwiftUI re-evaluates the scene, and an `App` whose whole body is one
  `MenuBarExtra` has no reason to rebuild.
- **What holds.** A plain AppKit `@main`, and an `NSStatusItem` added to and removed from
  `NSStatusBar.system` in the same sink every other followed setting uses. (snappy-snap)
- **Rule.** A SwiftUI `Scene` is not a view: never put a value that has to change at runtime into one.

### S3. A SwiftUI `Settings` scene cannot bring an accessory forward
- **Why.** `.onAppear` fires once per scene, not per open, so there is no hook to activate from; centring
  in `init` measured x = 756 on a 1512 pt display, before the first layout.
- **What holds.** `SettingsWindow` is an ordinary `NSWindow` the delegate owns; every `show()` activates
  with `ignoringOtherApps: true`, sizes, then centres. (snappy-snap)

### S4. A persisted default is not a default
- **Symptom.** A default raised in code reached nobody whose file already held the old value, and the
  migration written to fix it re-ran on every launch, because `didSet` does not fire in `init`.
- **What holds.** `SettingsStore` loads and never rewrites; every number that is not a user's choice is a
  constant that was never persisted. (snappy-snap)
- **Rule.** A control the user can move, or a constant that was never persisted. Never a rule that
  rewrites their file.

### S5. An accessory app has no menu, and its activation policy does not always stick
- **Symptom.** ⌘C / ⌘V / ⌘W do nothing in the settings window; the Dock icon sometimes fails to appear or
  disappear.
- **What holds.** A minimal App / Edit / Window menu is installed at launch; an app that switches policy
  at runtime checks it after setting it and retries. (my-sidepulse)

## Updates

### U1. A helper started by the app dies with the app
- **Symptom.** The app quits for an update and nothing happens: the helper that was to swap the bundles is
  gone.
- **Measured.** Three throwaway launchd jobs, each spawning `sh -c 'sleep 4; echo > marker'` and exiting at
  once. The plain `posix_spawn` child never wrote its marker; the one spawned with `POSIX_SPAWN_SETPGROUP`
  and group 0 did. An app opened through LaunchServices is a launchd job too.
- **What holds.** `DetachedProcess`: a process group of its own, no inherited descriptors, an environment
  of the app's making. Never a plain `posix_spawn`, never a shell `&`. (snappy-snap)

### U2. Everything that can refuse an update has to happen before the quit
- **Symptom.** An updater that quits first and installs after ends with no app running and nothing on
  screen to say why.
- **What holds.** The release is fetched, held against GitHub's length and SHA-256, unpacked, checked
  (`StagedUpdateCheck`, `CodeSignature`) and the folder tried (`UpdateInstaller.obstacle`) while the app is
  up, where a failure is a sentence in the window. What is left for after the quit is two renames on one
  volume and a launch, each with its way back: a failed second rename undoes the first, and a new version
  not seen running within 15 s, or gone 2 s after it was seen, is moved out and the previous one moved
  back and opened. The helper touches nothing until the pid is gone, and gives up untouched after 20 s.

### U3. The outcome has to be written before the new version starts
- **Why.** The new version reads `updates/result` as it launches, while the helper is still watching it
  start.
- **What holds.** The helper writes `installed` before `open` and overwrites it if it rolls back. The app's
  own tidying at launch never removes `updates/previous/`: only the helper deletes it, once it has seen the
  new version running.

### U4. A new version that is gone two seconds later has crashed, or has been quit
- **Symptom.** The update is rolled back because the user quit the new version as soon as it appeared.
- **What holds.** The launch that reads the outcome renames it to `result.read`. Gone with that mark in
  place, the version had started and its quit is the user's; gone without it, the helper looks again for as
  long as it first looked (an app changing hands with launchd is gone for that moment), and only then puts
  the previous one back. `UpdateController.start()` runs last in `applicationDidFinishLaunching`, so the
  mark means the launch got that far.

### U5. A helper that gives up while the app may still quit
- **Why.** Two clocks, the helper's limit and the app's "did not quit" notice, leave a gap in which the app
  quits with no helper left.
- **What holds.** One clock decides. After `K.updateStallNotice` the app stops the helper (`SIGTERM`; while
  the app runs the helper can only be in its wait) and then says so. The helper's own, longer limit serves
  only an app too hung to do that.

### U6. `ps` lists the path the kernel ran, not the one the app was installed at
- **What holds.** The helper looks for the executable under the installed path and under `pwd -P` of it;
  it counts an exited, unreaped app (state `Z`) as gone, and anything `ps` cannot say as still running.

### U7. GitHub answers 404 for "no release" and for "not yours to see" alike
- **Symptom.** *No release published yet* for ever, although a release exists.
- **Why.** The check is anonymous, and to an anonymous caller a private repository does not exist. Drafts
  and pre-releases read the same.
- **Rule.** Only 404 reads as "nothing there". 403 and every other status are failures and say so; a
  failure must never read as *Up to date*. A token in the app is not the way round it. (my-sidepulse)

### U8. A download task succeeds on a 404
- **Why.** `URLSession.downloadTask` reports no error for an HTTP error status: it hands over the error
  page as the downloaded file.
- **What holds.** `UpdateDownload` checks the status before it moves anything, and the file is held
  against the length and digest GitHub stated before anything opens it. (my-sidepulse)

### U9. Swapping the bundle under a running app wakes a watchdog
- **Why.** A watchdog that compares the app's executable path with a recorded one reads a bundle moved
  aside as a dead app, and relaunches.
- **What holds.** Nothing moves until the app has quit cleanly. (koffeelid)

## Uninstall

### X1. `cfprefsd` writes the domain back out as the process exits
- **What holds.** The preferences and the support folder go to a detached helper that waits for the pid
  (`UninstallPlan.helperScript`). `defaults delete` runs before the file is removed, or the cache is written
  back over the gap.

### X2. `tccutil reset` needs the bundle to still exist
- **What holds.** Grants are given back first, while the bundle is still where they name it. It exits
  non-zero when it had nothing to reset as well as when it failed, so the sentence the user reads names
  where to look either way.

### X3. Nothing puts a notification grant back to "not asked"
- **What holds.** The app's entry is dropped from `group.com.apple.usernoted`'s `apps[]` and `usernoted`
  and `NotificationCenter` are restarted. Its failure is not worth a sentence.

### X4. `Process.waitUntilExit()` on the main thread runs the main run loop
- **Symptom.** Settings › General › Uninstall froze under a spinning wheel for a minute. The grant had been
  reset and nothing else had happened: the bundle, the login item and the preferences were all still there.
- **Measured.** `waitUntilExit` runs the calling thread's run loop until the tool is done: thirteen timer
  ticks during a 64 ms wait for `/usr/bin/true`. In the middle of the wait for `tccutil`, the Settings
  window's two-second refresh ran, read the grant and the login item, and one of its calls never came back.
- **What holds.** Nothing waits on another process on the main thread. A bounded wait blocks the calling
  thread and nothing else (a termination handler and a semaphore with a deadline, the tool terminated past
  it), and the uninstall runs its steps on a global queue through it, each within a deadline and logged with
  what came back and how long it took, then hops back for its last alert. **Whatever the grant gates stops
  before the reset**: an enabled tap whose owner loses the grant stalls every click (E1). (shiftpick)

## Launch, login items and launch agents

### L1. A reinstall opens a window nobody asked for
- **What holds.** `QuietLaunch`: the installer writes a marker before anything can start the app, the
  first launch that finds it opens nothing, and the marker lapses after two minutes. The update's install
  helper writes it too. (snappy-snap)

### L2. `SMAppService.agent` pins a launch constraint to the job
- **Symptom.** Crashes go unrecovered while `status` reports `.enabled`. Logs: `Launch Constraint
  Violation`, `Unable to get updated LWCR`; after deleting the bundle, `Invalid or missing Program`.
- **Why.** launchd checks that requirement on every spawn, and Background Task Management stores the agent
  against the bundle, so removing the bundle first leaves a record that resolves to nothing. Neither
  re-registering nor `bootout` clears it.
- **What holds.** A plain plist in `~/Library/LaunchAgents`, bootstrapped with `launchctl`. Even that job
  gets an LWCR on macOS 26: the first respawn after an install is killed once and recovers after one ~10 s
  throttle cycle. Harmless. (my-sidepulse)

### L3. Bootstrapping an agent does not put the running app under it
- **Symptom.** After a drag install, `launchctl list` shows the job loaded with no pid.
- **Why.** `RunAtLoad` spawns the job at once, that spawn finds the hand-launched instance already up and
  terminates itself, and `SuccessfulExit = false` correctly declines to restart something that exited zero.
- **What holds.** The app hands itself over: a detached helper waits for the pid and runs `launchctl
  kickstart`. `kickstart` cannot run from inside the app, because the job is what would replace the process
  running it; and it is the app's job, not the install script's, because a copy dragged out of the disk
  image has no script behind it. (my-sidepulse)

### L4. Killing a `KeepAlive` job is asking launchd to restart it
- **Why.** `killall` is SIGTERM, a non-zero exit, exactly what `SuccessfulExit = false` restarts: launchd
  brings the app back from the old bundle while the script is still replacing it.
- **What holds.** `launchctl bootout gui/<uid>/<label>` unloads the job and takes its process with it.
  Anything the app must read at its next launch is written before the app is stopped. (my-sidepulse)

### L5. `launchctl disable` is permanent, and nothing ordinary undoes it
- **Symptom.** Every `bootstrap` fails with `Bootstrap failed: 5: Input/output error`, across reinstalls and
  a reboot.
- **Why.** `disable` writes an override into `/var/db/com.apple.xpc.launchd/disabled.<uid>.plist`. Only
  `launchctl enable` clears it.
- **Rule.** Never write `launchctl disable` anywhere: not in a script, not in the app, not at a terminal.
  `bootout` is the only verb an uninstall or a takeover uses. (my-sidepulse)

### L6. `launchctl bootout` kills the process running as the job
- **What holds.** When the app is the agent's own process, removing the plist is the whole operation.
  (my-sidepulse)

### L7. `argv[0]` is useless under launchd, and pids are reused
- **What holds.** A tool resolves its own path with `proc_pidpath`; anything that remembers a pid also
  remembers the executable path it belonged to, and compares both. (koffeelid)

### L8. TCC and Login Items approvals are per bundle path and per team id
- **What holds.** A DerivedData or `build/` copy and the `/Applications` copy are different apps to macOS;
  changing the signing team asks for every grant again; a Login Items approval survives an uninstall, so a
  reinstalled bundle re-registers silently. (koffeelid)

### L9. A second copy that asks the first through `NSWorkspace.open` and exits asks nobody
- **Symptom.** `open -n /Applications/<App>.app` did nothing: the second copy left, and the first never showed
  its window.
- **Why.** The request is handed to LaunchServices asynchronously, and a process that exits right after
  making it never has it delivered.
- **What holds.** The second copy posts a distributed notification the first observes (shiftpick's
  `AppDelegate.openedAgain`), then exits, before it has created anything: two copies of an app that holds an
  event tap are two taps on the same events. (shiftpick)

## Signing and the build

### B1. An ad-hoc signature loses every grant
- **Why.** The grant is per code identity, and an ad-hoc build gets a new one every time it is built. The
  owner grants again after every build and ends up with a privacy list full of dead entries.
- **What holds.** `scripts/make-app.sh` refuses an ad-hoc build without `DEBUG_OK=1`, and one is never
  installed. (shiftpick, snappy-snap)

### B2. `get-task-allow` in a development-signed Release build
- **Why.** The Apple Development identity injects it; a same-user process can then take the app's task
  port and act under its grants.
- **What holds.** Release builds never carry it, and `release.sh` refuses one that does. Check with
  `codesign -d --entitlements - <app>`. (koffeelid)

### B3. SwiftPM records the deployment target as the SDK, and Liquid Glass follows it
- **Symptom.** Built with the macOS 27 SDK and a macOS 15 target, the settings toolbar drew its selected
  page as a flat tinted rectangle where the same window in another app drew the glass pill.
- **Why.** `swift build` writes the deployment target into the binary's `LC_BUILD_VERSION` as both `minos`
  and `sdk`, and AppKit gates the Liquid Glass design on that recorded SDK.
- **Rule.** The target is macOS 26; do not lower it to widen compatibility. (my-sidepulse)

### B4. Two names that differ only by case are one file in `Contents/MacOS`
- **What holds.** A CLI named like the app in lower case sits beside a GUI binary that keeps its
  build-product name. Only `CFBundleExecutable` has to match. (my-sidepulse)

### B5. `set -e` reaches inside command substitutions
- **Symptom.** `install.sh` exited 1 with no output at all.
- **Why.** A command substitution is a subshell that inherits `set -e`, so `tag="$(gh release list …)"`
  with a `gh` that exits non-zero (no repository, no login, no network) took the function's own fallback
  down with it and handed the caller an empty version.
- **Rule.** A command that may fail inside `$(…)` ends in `|| true`. (shiftpick)

### B6. The notary credential check fails spuriously
- **Symptom.** `no notarytool keychain profile 'wooflab-notary'` between two installs ten minutes apart,
  then success with nothing changed.
- **Why.** Notarizing talks to Apple over the network, and the keychain lookup answers nothing for a
  moment. The credential is there: the owner has said so, and it is not a session's to doubt.
- **Rule.** Run the install script again before you diagnose anything, and diagnose nothing after: never
  look the credential up, store one, or build another way. Refused twice, tell the owner in one line and
  stop. (koffeelid, my-sidepulse)

### B7. The app's name is an identity in several places
- **Symptom.** After a rename, two apps drive the same hardware, hooks fail, macOS asks for every
  permission again.
- **Why.** The name is the bundle id (grants, `UserDefaults`), the agent's label, the Application Support
  directory, any hook command written into the user's files, the environment variables in the user's
  shell.
- **Rule.** A rename is a migration. That is why `scripts/signing.env` is the one place the name is
  written, and why `new-app.sh` renames everything at once, before the first build. (my-sidepulse)

## The icon

### I1. Splitting an Icon Composer stack into one group per layer renders it black
- **Why.** A group is the unit Icon Composer applies glass, shadow and translucency to, and the groups
  composite against each other.
- **Rule.** Re-export from Icon Composer to change the stack. Never restructure `icon.json` by hand, and
  never take a clean `actool` run as evidence that the icon renders. (my-sidepulse)

### I2. The bundled `.icns` is a flat stand-in, not the icon
- **Why.** `actool`'s `.icns` carries 16 px and 128 px only; the real icon exists only as the system's
  rendering of `Assets.car`.
- **What holds.** `scripts/dmg-volume-icon.swift` asks `NSWorkspace` how macOS renders the built app and
  builds the disk image's volume icon from that. A clean run of `make-app.sh` is not evidence the icon looks
  right: check the rendered bundle by eye. (my-sidepulse)

## Tooling and tests

### T1. `swift build` is the truth; editor diagnostics are stale
- **Rule.** Build. (snappy-snap)

### T2. `swift test` prints one summary line per bundle, and a crashed bundle prints none
- **Symptom.** A crashed bundle prints `Note: Some test targets reported failures:` with no summary line,
  so a grep finds the other bundle's green line and the crash reads as a pass.
- **Rule.** Count the lines: one per bundle. A filter that matches nothing in a bundle means that bundle
  prints no line either. XCTest's summary has also undercounted; when in doubt count the per-case `passed`
  lines. (snappy-snap, koffeelid)

### T3. `#expect` does not abort, and it boxes `CGFloat` against `Double`
- **Rule.** In swift-testing, `try #require` where the next line indexes; compare whole `CGPoint`/`CGRect`
  values or make both sides the same type. (snappy-snap)

### T4. A test that reads the live desktop is nondeterministic
- **Rule.** Treat a one-off failure there as environmental; rerun before investigating. (snappy-snap)

### T5. The sandbox
- `swift build`, `swift test`, `codesign`, `open` (LaunchServices −600) and the privacy database
  (`AXIsProcessTrusted()` answers false) all fail inside Claude Code's Bash sandbox. Every app turns it off
  in `.claude/settings.local.json`. (all four)

### T6. `log show` returns nothing where `log stream` does
- **Rule.** Start `/usr/bin/log stream --predicate 'subsystem == "<bundle id>"' --level debug` before
  reproducing. `log` alone is a zsh function in the owner's profile. (snappy-snap, koffeelid)

### T7. A number read off a screenshot by eye is not a measurement
- **Symptom.** Four builds of a drawing rejected as looking nothing like the reference.
- **Rule.** Fit, then build: extract the numbers from a capture with a script, render the app's own drawing
  offline (`ImageRenderer`) and compare. An agent's shell has no Screen Recording grant, so nothing it builds
  is looked at before the owner does; say so. (snappy-snap)

### T8. A pipette on a translucent surface reads a composite, not a colour
- **Rule.** Before fitting a colour to a system surface, establish whether that surface is opaque. If it is
  not, sample it over two backgrounds, or one with a channel pinned at 0 or 255, and solve for the colour
  and its alpha together. (snappy-snap)

### T9. A Claude turn that dies when the Thunderbolt dock is unplugged is a network event
- **Rule.** `configd` logs `interface detach`; `pmset -g log` has no sleep line. Do not read it as the
  app's doing. (koffeelid)

### T10. A test that makes a preferences domain of its own leaves a file behind every run
- **Symptom.** 129 `.plist` files in `~/Library/Preferences`, one per test ever run.
- **Why.** `UserDefaults(suiteName:)` with a fresh name per test creates a domain, and `cfprefsd` keeps a
  domain's plist even once `removePersistentDomain` has emptied it (X1 is the same daemon).
- **What holds.** One fixed suite name for the whole test class, emptied before and after each test.
  (shiftpick)

### T11. Code that no test can run can still be pinned where it stands
- **Why.** An event tap cannot be created in a test, because the runner has no Accessibility grant, so the
  code that creates, enables and tears one down runs nowhere but the owner's Mac.
- **What holds.** A test that reads the source, the way the purity tests read the imports: one place that
  enables the tap, nothing enabled from a callback, the order of a teardown. Each check is shown to fail
  against a copy of the code with its net removed, and one that fails because code moved is moved with the
  code, never loosened (shiftpick's `SafetyNetTests`). (shiftpick)

## Agent hooks and the shell

### H1. A hook can fire for a turn that is already over
- **Symptom.** A Codex session read as working after Ctrl-C, until Codex was quit: the Mac stayed armed, the
  strip kept rolling.
- **Why.** Codex reports a tool's end when its process really ends, which can be seconds or minutes after the
  turn was aborted; the `Interrupt` had already closed the turn, and a state machine that maps any
  `PostToolUse` to "working" reopened it with nothing left to close it, because `Stop` runs only on a
  completed turn.
- **What holds.** Every event carries its turn's id (Claude Code `prompt_id`, Codex `turn_id`); an
  `Interrupt` or a verdict closes the turn; an event that names a closed turn only proves the hook alive. A
  `Stop` ends a turn without closing it, since a Stop hook that blocks it keeps the same turn running.
  (koffeelid, my-sidepulse)

### H2. A long-lived host pid proves nothing about one session
- **Why.** Codex's TUI runs its sessions through a managed daemon (`codex app-server --managed-daemon`, one
  per user, parented by launchd, alive across every TUI) and the desktop app through its own shared
  app-server: the pid a hook records is the host's, so watching it for death, or keeping a session because
  it is alive, says nothing about that session. Only `codex exec` records a process of its own.
- **What holds.** Ask the source of truth instead: the session's rollout file (`transcript_path`, whose
  `task_complete` / `turn_aborted` markers name the turn) and, for the managed daemon only, `thread/read` on
  its control socket. A pid on a shared host is kept by the launch prune and decided by those.
  (koffeelid, my-sidepulse)

### H3. A shell snippet's state does not survive its own re-reading
- **Symptom.** `source ~/.zshrc` or `exec zsh` while a command was recorded left a job that never ended.
- **Why.** `typeset -g var=` is an assignment: re-reading the snippet mid-command empties it, and `precmd`
  then ends nothing.
- **What holds.** Declare without assigning (`(( ${+var} )) || typeset -g var=`), release the shell's slot
  when the snippet loads in an interactive shell, and let the app ask the shell itself: a shell at its
  prompt owns its tty's foreground process group (`e_tpgid == e_pgid`) and has no child it started since the
  job began (Powerlevel10k keeps a `gitstatusd` child under every shell). (koffeelid, my-sidepulse)

### H4. A hook Copilot cannot run is a denial, and a stale one denies everything
- **Why.** Copilot runs a failing hook as its verdict: any non-zero exit, a crash or a missing binary denies
  the tool for `preToolUse` (fail-closed), and exit 2 denies for `preToolUse` and `permissionRequest` alike. A
  hook file left behind by an app removed without its uninstall blocks every Copilot tool, forever.
- **What holds.** Subscribe to neither call an app has no use for; every `hook …` form of the binary exits 0,
  unrecognised arguments included, after reading stdin to the end; the uninstall removes the whole file (each
  app owns one file under `~/.copilot/hooks/`). (koffeelid, my-sidepulse)

### H5. Copilot's Ctrl+C fires no hook, not even at an open permission prompt
- **Why.** The only interrupt Copilot exposes fires nothing at all, and a failed turn fires only
  `errorOccurred` (also fired on an error Copilot itself retries), never `agentStop`.
- **What holds.** Ask the source of truth instead, H2's rule again: the session's own
  `~/.copilot/session-state/<id>/events.jsonl`, whose `abort` / `session.error` / `session.shutdown` lines and
  the `hook.start` mirror of the session's own `agentStop` say how the turn ended. A subagent's events are
  mirrored into the parent's file with the subagent's id in `data.input.sessionId`. (koffeelid, my-sidepulse)

### H6. Copilot's lifecycle does not run in the order, or the shape, a hook expects
- **Symptom.** A state machine that resets on `sessionStart` loses the very turn it fires for; a payload with
  nothing in it that names the event.
- **Why.** `sessionStart` fires with the first prompt, *after* `userPromptSubmitted`. A subagent's own
  `userPromptSubmitted` / `agentStop` carry the subagent's id, which owns no session-state directory of its
  own. Event keys are camelCase with no field naming the event: it rides in the hook's arguments instead.
- **What holds.** Never reset a turn on `sessionStart`; drop an event whose session id has no directory;
  read the event name off the hook's own arguments. (koffeelid, my-sidepulse)

### H7. OpenCode 2.x refuses the plugin API its own docs describe, and one instance answers for every directory
- **Why.** 2.x has no command hooks: a plugin is `export default { id, setup(ctx) }` reading
  `ctx.event.subscribe()`; `session.idle` / `session.status` are never published, only
  `session.execution.started` followed by exactly one of `succeeded` / `failed` / `interrupted`. One instance
  of a global plugin loads per open directory and every instance receives every directory's events; every
  session, in every directory, runs inside one shared background server (`opencode serve --service`, parented
  by launchd), so H2 holds here too.
- **What holds.** De-duplicate by event id through `globalThis`; give each app its own plugin id, since a
  duplicate id fails to load; ask a session's own state, never the server's liveness, for how a turn ended.
  (koffeelid, my-sidepulse)

### H8. Answering a Copilot permission prompt fires no hook
- **Symptom.** A command the user approved runs for minutes while the session still reads as waiting on the
  user: the `notification` (`permission_prompt`) was the last hook, and the next one, `postToolUse`, fires
  only when the approved tool ends.
- **Why.** Copilot writes the answer to the session's `events.jsonl` (`permission.completed`) and tells no
  hook; the hooks that would see it, `preToolUse` and `permissionRequest`, are the ones H4 rules out.
- **What holds.** While a Copilot session waits, read its `events.jsonl`: with the turn still at work, a latest
  permission line that is `permission.completed`, stamped after the wait began, is the prompt answered, and the
  session is working again as of the check; journal that verdict so a replay agrees. A latest
  `permission.requested` is a prompt still open (a second one opens right after the first is answered), and no
  other step is an answer: a tool called beside the prompt can finish while it waits. A question needs none of
  this: its answer ends the `ask_user` tool, and `postToolUse` fires. (koffeelid, my-sidepulse)

### H9. An agent's tool shell loads the zsh snippet
- **Symptom.** A command an agent runs counts as the user's terminal command, and outlives the agent: Codex's
  shell tool runs an interactive zsh under its app-server daemon, and OpenCode's server keeps a tool's
  process running after a Ctrl+C in its window.
- **Why.** An interactive zsh reads `~/.zshrc`, whoever starts it; the snippet cannot tell who did.
- **What holds.** Walk the shell's process chain: a Claude Code, Codex (CLI or daemon), Copilot or OpenCode (CLI
  or server) process on it makes the shell the agent's. The hook writes no `job begin` for it, and the app drops
  one it reads anyway (from an older hook, or replayed). Never filter on environment variables, none is
  promised, and never count a desktop app's window process as the agent, or a terminal pane opened in that app
  stops being the user's. (koffeelid, my-sidepulse; `activity-detection.md` rule 28)
