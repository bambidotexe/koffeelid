# Pitfalls

Traps this codebase has evidence of, each with what the code does instead. Read the relevant section before
touching that area. Mechanisms are explained in `docs/macOS.md`; this file is only about what goes wrong.

Format: **Symptom** / **Why** (on current macOS, for this app) / **What the code does** / **Do not**.

## Sleep and the kernel flag

### powerd rewrites the lid-sleep flag under you
- **Symptom.** Armed, lid closed, the charger is plugged in (or a display comes or goes): the Mac sleeps within
  a millisecond of the event. The log shows nothing wrong before it.
- **Why.** Selector 12 sets a bit that powerd also owns. powerd recomputes its clamshell policy on every
  power-source change and on every raise or release of `UserIsActive` / `DisplayWake` / `PreventSystemSleep`,
  and writes 0 when its own answer is "sleep". The kernel evaluates the closed lid inside that write.
  Re-applying the flag afterwards is too late by construction.
- **What the code does.** `SleepLock` engages `pmset disablesleep 1` on every arm when the sudoers rule exists;
  the kernel checks `SleepDisabled` before every sleep request. Without the rule, `handleExternalSleep`
  recognises `Last Sleep Reason == "Clamshell Sleep"` with the lid closed, keeps mode, state and assertions
  (the `PreventSystemSleep` assertion holds the Mac in dark wake, on AC power), re-applies the flag at once and
  notifies. `SleepOverrideGuard` stops after 3 holds in 120 s.
- **Do not** treat every `willSleep` as an external sleep request. Do not force a full wake from the hold with
  `IOPMAssertionDeclareUserActivity`: raising it makes powerd recompute and write 0 again.

### `pmset disablesleep 1` survives a crash and a reboot
- **Symptom.** The Mac never sleeps again, lid open or closed, app not running.
- **Why.** The setting is stored in `/Library/Preferences/com.apple.PowerManagement.plist`.
- **What the code does.** `SleepLock.engage` writes the `sleep-lock` marker; `releaseIfMarkerPresent` runs at
  every launch; `disarm` and `shutdown` release; a failed release is logged and notified with the command to
  run. `pmset -g | grep SleepDisabled` must read 0 whenever nothing is armed.
- **Do not** add a path back to `.idle` that skips `releaseSleepLock()`. A failed release is not retried;
  if you add a retry, keep the notification.

### The kernel flag outlives the process
- **Symptom.** After a crash or `kill -9`, closing the lid no longer sleeps the Mac.
- **Why.** The flag belongs to the root domain, not to the user client that set it.
- **What the code does.** Every return to `.idle` attempts `setLidSleepDisabled(false)`; a failed clear turns
  the cup orange and retries every 30 s; quit tries three times; the pid file left by an unclean exit makes the
  next launch clear the flag; the watchdog relaunches the app so that launch happens.
- **Do not** put an early return between the flag attempt and `state = .idle` in `disarm`.

### Clearing a flag you did not set
- **Symptom.** Another lid-sleep utility, or a second KoffeeLid build, silently stops keeping the Mac awake.
- **Why.** One shared bit, no per-client tracking.
- **What the code does.** The launch clear needs a stale pid file or brightness-recovery file; the quit clear
  needs `wasArmed || flagClearPending || power.lidSleepDisabled`; `AppDelegate` exits a duplicate instance
  before `start()`.
- **Do not** make those clears unconditional.

### Re-applying the flag feeds itself
- **Symptom.** `re-applied lid-sleep flag` scrolls forever.
- **Why.** Root-domain interest notifications fire for the app's own write.
- **What the code does.** `reapplyFlag` returns when `AppleClamshellCausesSleep` already reads `No`.

### `AppleClamshellCausesSleep` lies for a while
- **Symptom.** `ioreg` says `Yes` right after an arm, or `No` after a clean disarm.
- **Why.** The property is refreshed only by the kernel's own clamshell notifications, not by a selector-12 write.
- **What the code does.** Tolerates an occasional redundant re-apply (`setClamShellSleepDisable(2->2)`).
- **Do not** diagnose from that value alone: use `koffeelid status`, the log and `pmset -g assertions`.

### `PreventSystemSleep` does nothing on battery
- **Why.** powerd disables that assertion type on battery power, so the dark-wake hold only works on AC.
- **What the code does.** The sleep lock is the complete answer; the low-battery rail bounds the rest.

### The display assertion does not stop the screen saver or auto-lock
- **Why.** Those run on the user-idle timer, which `PreventUserIdleDisplaySleep` does not reset.
- **What the code does.** Armed + screen on declares user activity every 30 s, only while the lid is open: a
  declaration wakes a sleeping display, and the closed lid's panel must stay dark.

## Lid, sensor, gesture, effect

### The Fn flag is not the Fn key
- **Symptom.** The lid effect stays folded after the lid stops; a one-close arm does not cancel when the lid is
  held still; `gesture: started … (fn via hardware)` appears in the log while nobody touches Fn; a lid
  adjustment arms the Mac or starts the fold. Seen mostly in Armed + screen on, the mode that stands for hours
  with the lid open and the detector listening.
- **Why.** `maskSecondaryFn` / `.function` is set on every arrow-key event (together with the numeric-pad
  flag), not only while Fn is down, and the session's flag state keeps it after the arrow key is released,
  until the next keyboard event: press ↑ once, touch nothing, and "Fn" reads held for as long as you like. `FoldTracker` and `ReopenCancelWatch` ignore stillness while the modifier
  reads held, so a false "held" starves the effect's reset, which is evaluated per lid-angle sample and has no
  timer behind it.
- **What the code does.** `FnKeyReading.isFnDown` rejects a reading that carries the numeric-pad flag or whose
  physical key 63 is up (`CGEventSource.keyState`, 1 for Fn and 0 for an arrow key on this Mac);
  `GestureController.readModifier` uses it for both flag sources.
- **Do not** test the Fn flag alone: function keys used as F1–F12 and an external keyboard's navigation keys
  carry it without the numeric-pad flag, and only the key state of 63 tells them from Fn. Do not gate the
  effect's reset on anything that can stay true without the user's hand on a key.

### An external Apple keyboard's Fn is the same flag, the same key code and the same HID element
- **Symptom.** The Globe key of a Magic Keyboard next to the MacBook arms the lid gesture, or holds the fold.
- **Why.** It sets the same secondary-Fn flag, presses the same virtual key 63, and (seen in `ioreg` on this
  Mac) carries the same input element, usage page `0xFF` usage 3, as the built-in keyboard. Nothing in the
  session-wide readings says which keyboard.
- **What the code does.** `BuiltInFnKeyReader` enumerates the keyboards, keeps the one whose `Built-In`
  property is set, opens that device and reads its Fn element; `FnKeyReading` requires that reading too when it
  exists. It needs the Input Monitoring grant; without it the session-wide rule stands and any keyboard's Fn
  counts (logged at start).
- **Do not** put `Built-In` in the HID matching dictionary: the kernel ignores keys it does not match on, and a
  dictionary carrying it matched both keyboards on this Mac. Do not try to tell keyboards apart from `CGEvent`
  flags or key codes, and do not trust the HID value alone: a missed key-up would leave it down, which is why
  the session key state is still ANDed in.

### A cached modifier state sticks
- **Symptom.** Every close arms, then the detector goes dead after 20 s.
- **Why.** `NSEvent.addGlobalMonitorForEvents` never delivers the active application's own events: a key
  released while a KoffeeLid window is active is never seen as released.
- **What the code does.** Reads the modifier fresh on every sample from two live sources; caches nothing.

### A gesture detector that latches
- **Symptom.** Fn + close does nothing until the Mac is armed once from another source.
- **Why.** A one-shot "activated" state that only an external `reset()` clears, plus a path that never calls it.
- **What the code does.** `LidProgressDriver` resets itself when the modifier is released after `.armed`;
  `arm`, `disarm` and every change of `gestureWanted` reset the detector; `arm` sets `armSource` before
  `refreshGestureSampling` so `gestureWanted` reads the right source.
- **Do not** add a gesture state that survives a state change of the coordinator.

### The lid sensor is integer, flickers, and updates at 10 Hz
- **Symptom.** The fold never returns to flat at certain angles; the fold moves in steps.
- **Why.** The value flips between neighbouring degrees at rest, and changes at most every ~100 ms.
- **What the code does.** Stillness is "less than 1.5° from the last movement" in `FoldTracker` and
  `ReopenCancelWatch`. `LidAngleObserver` polls at 120 Hz while the value changes to time each change to ~8 ms,
  delivers at 30 Hz (the gesture filters count samples) and stamps each sample with the time its value first
  appeared; `AngleSmoother` fits a line through 0.25 s of change events, reads it in the past, bounds any
  prediction and fades it once events stop.
- **Do not** interpolate between raw 30 Hz reads, and do not use equality as "still".

### The effect's reset has no timer behind it
- **Why.** The settle is computed inside `FoldTracker.update`, so it advances only when a sample arrives.
- **What the code does.** The sampler delivers every tick while a consumer is registered, changed value or
  not. A failing sensor read delivers nothing (logged after 30 consecutive failures).
- **Do not** stop delivering unchanged samples, and do not remove the `"effect"` consumer while a fold shows.

### A capture that outlives its session
- **Symptom.** The screen-recording indicator stays lit until quit.
- **Why.** The still image's `await` can outlast a cancelled fold; starting the stream afterwards streams into
  a capture nobody owns.
- **What the code does.** `EffectController.beginSession` re-checks ownership after the still;
  `DesktopCapture.start` takes its `CaptureStartGate` token before the first `await`, so a stop landing during
  a start wins.

### A shader error shows up only at the next arm
- **Why.** `PlaneShader.source` is compiled at runtime; `xcodebuild` cannot see a typo.
- **What the code does.** `effect: no built-in display or Metal unavailable` in the log. Check the shader with
  `xcrun metal` after every edit (`docs/development.md`), and keep `PlaneRemap` and its tests in step.

### Template image and the warning tint
- **Why.** AppKit tints template images only. Switching the status image off template to colour it draws black.
- **What the code does.** The glyph stays a template; `contentTintColor` carries the orange.

## Displays and the lock

### A display that vanishes behind a closed lid is reported late
- **Symptom.** Armed in clamshell on a charger-fed monitor, the charger is unplugged, the lid reopens: no lock.
- **Why.** macOS posts no screen-parameter change while the lid is shut and nothing is left to reconfigure; the
  disconnect arrives about 130 ms after the lid-open notification, so the reopen decision reads a stale
  "external display present".
- **What the code does.** `handleLid(.opened)` re-reads the display list before anything uses `standingBy`, and
  `ReopenLockDecision` keeps a skipped lock pending for 2 s.
- **Do not** trust a cached topology at a lid transition.

### A lid that reopens on a locked screen posts no lock edge
- **What the code does.** `handleLid(.opened)` reads `CGSSessionScreenIsLocked` directly after requesting the
  lock, in addition to the two distributed notifications.

### The lock can silently fail
- **Why.** `SACLockScreenImmediate` is private, and an account without a login password never locks.
- **What the code does.** Retries five times (0.5 to 8 s apart) until macOS reports the session locked, then
  notifies; a one-close arm that
  never sees a lock ends at that reopen rather than being held over a visible desktop.

## Windows and permission grants

### A window that floats to stay reachable covers what it sent you to
- **Symptom.** The onboarding wizard sits on top of the System Settings window and the administrator dialog its
  own buttons open, hiding the instructions it just gave.
- **Why.** `NSWindow.level = .floating` is above every other app, and `NSApp.activate(ignoringOtherApps: true)`
  pulls the app in front of whatever it has just launched. Both were there because an `LSUIElement` app is not
  reactivated when System Settings or a password dialog closes, which leaves its windows behind everything.
- **What the code does.** The wizard is a normal window and the app is activated once, when it opens. It is
  reachable again three other ways: it comes forward on `NSApplication.didBecomeActiveNotification` while it is
  the app's only window, `applicationShouldHandleReopen` prefers it over Settings, and the grant rows follow
  System Settings by polling rather than by needing the window back in front.
- **Do not** raise a window's level, or call `activate(ignoringOtherApps:)`, to keep it findable. Reachability
  and z-order are different problems; the second fix covers the user's own work.

### `NSScreen.main` is nil with no key window
- **What the code does.** Window sizing falls back to the first screen.

### A grant request and a System Settings pane, both at once
- **Symptom.** One press of "Allow…" and the user gets the system permission dialog *and* System Settings, one
  over the other.
- **Why.** `CGRequestScreenCaptureAccess()` shows the dialog and returns the state as it is *now*, which is
  still not-granted, so a `if !request() { openSystemSettings() }` opens the pane every single time.
- **What the code does.** Each grant action calls the request API and stops there (`PermissionCatalog`); the
  dialog's own button is the way to System Settings. The pane openers were deleted so the branch cannot come
  back.
- **Do not** read a request API's return value as "the user refused": it is the state before the user has
  answered.

## Watchdog and launch

### `argv[0]` is useless under launchd
- **Symptom.** The watchdog stands down at once when launchd starts it.
- **Why.** A `BundleProgram` agent starts with a relative `argv[0]` and `/` as working directory.
- **What the code does.** Resolves its own path with `proc_pidpath`.

### Pids are reused
- **What the code does.** The watchdog compares `proc_pidpath(pid)` with the executable recorded in the pid
  file; the activity monitor keeps a replayed session only if its pid is alive **and** looks like Claude;
  `ClaudeRegistryRecord` rejects a record whose pid does not match.

### launchd starts the agent before the app at login
- **What the code does.** The watchdog stands down on a missing or pre-boot pid file; the app runs
  `launchctl kickstart` on every start so a live watchdog observes the current pid. A relaunch attempt is
  recorded before `open` runs, so a bundle that cannot launch still trips `CrashLoopGuard`.

## Updates

### A helper started by the app dies with the app
- **Symptom.** The app quits for an update and nothing happens: the helper that was to swap the bundles is gone.
- **Why.** launchd kills what is left in a job's process group when the job's main process exits, and an app is
  a launchd job.
- **What the code does.** `DetachedProcess` spawns the helper with `POSIX_SPAWN_SETPGROUP` (a group of its own),
  no inherited descriptors and an environment of the app's making.
- **Do not** start it with a plain `posix_spawn` or a shell `&`.

### The new version exits at once if the old one is still there
- **Why.** `AppDelegate` exits a duplicate instance, and an app that has been asked to quit is still a running
  application for a moment.
- **What the code does.** The helper waits for the old pid to be gone before it touches or opens anything, and
  gives up untouched after 20 s.

### Swapping the bundle under the running app wakes the watchdog
- **Why.** The watchdog compares the app's executable path with the one in the pid file; a bundle moved aside
  while the app runs no longer matches, which reads as a dead app with a pid file, and it relaunches.
- **What the code does.** Nothing moves until the app has quit cleanly: the pid file is gone and the watchdog
  has stood down.

### The outcome has to be written before the new version starts
- **Why.** The new version reads `updates/result` as it launches, while the helper is still watching it start.
- **What the code does.** The helper writes `installed` before `open` and overwrites it if it rolls back. The
  app never deletes `updates/previous/`: the helper may still need to put it back.

### A new version that is gone two seconds later has crashed, or has been quit
- **Symptom.** The update is rolled back, and the previous version comes back, because the user quit the new
  one as soon as it appeared: the relaunch shows the update window saying the install worked, with a Done
  button and the menu bar a click away.
- **What the code does.** The launch that reads the outcome renames it to `result.read`. Gone with that mark in
  place, the version had started and its quit is the user's; gone without it, the helper looks again for as long
  as it first looked (an app changing hands with launchd is gone for that moment), and only if it is still
  nowhere is the previous one put back. `UpdateController.start()` runs last in `applicationDidFinishLaunching`,
  so the mark means the launch got that far.

### A helper that gives up while the app may still quit
- **Why.** Two clocks, the helper's limit and the app's "did not quit" notice, leave a gap in which the app
  quits with no helper left: nothing installed, nothing running, nothing said.
- **What the code does.** One clock decides. After `UpdateInstallPlan.stallNotice` the app stops the helper
  (`SIGTERM`; while the app runs the helper can only be in its wait, having touched nothing) and then says so.
  The helper's own, longer limit serves only an app too hung to do that.

### `ps` lists the path the kernel ran, not the one the app was installed at
- **Why.** An app reached through a symbolic link (`/tmp` is one) runs under its resolved path.
- **What the code does.** The helper looks for the executable under the installed path and under `pwd -P` of it;
  missing a running version would roll back a good install. It also treats an exited, unreaped app (state `Z`
  in `ps`) as gone: `kill -0` still answers for one.

### `diskutil eject <folder>` names the volume the folder sits on
- **Why.** A plain folder's path resolves to its volume, which is the Mac's own.
- **What the code does.** `UpdateStager` only detaches a folder whose device differs from its parent's.

## Privilege

### `sudo -n -l` says yes to anything once any NOPASSWD rule exists
- **What the code does.** Availability also requires `/etc/sudoers.d/koffeelid` to exist.

### A malformed sudoers file locks sudo out
- **What the code does.** The rule is staged as a dotted temp file inside `/etc/sudoers.d`, validated with
  `visudo -cf`, then renamed; absolute tool paths throughout; the user name is validated before it is written.
- **Do not** trust `PATH` or `TMPDIR` in a script that runs as root.

### `get-task-allow` in a development-signed Release build
- **Why.** The Apple Development identity injects it; a same-user process can then take the app's task port
  and act under its Screen Recording grant.
- **What the code does.** `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` for Release. Check with
  `codesign -d --entitlements - /Applications/KoffeeLid.app`.

## Claude Code hooks and the shell

### Esc and Ctrl-C fire no hook
- **Symptom.** A session stays "working" forever; the Mac never auto-disarms.
- **What the code does.** A working session quiet for 20 s is checked against Claude Code's
  `sessions/<pid>.json` every 15 s; `idle` stamped after the last hook ends the turn.

### `SubagentStop` is often missing
- **Why.** Measured on recorded sessions: 19 of 44 helpers never sent one; the longest real gap between two
  events of a live helper was 202 s.
- **What the code does.** A helper is live for 240 s after its last event; a held `Stop` is released 90 s after
  everything cleared, or 30 min after the last event.

### `idle_prompt` is a timer, not a request
- **What the code does.** It counts only as a lost `Stop`: state still `working`, no held `Stop`, and 50 s of
  main-agent quiet.

### A dialog can be answered without any hook
- **What the code does.** A `waiting` session whose registry record says `busy`, stamped at least 2 s after the
  wait began, goes back to `working`.

### Another process's environment cannot be read
- **Why.** macOS withholds it from a same-user reader, so a per-session `CLAUDE_CONFIG_DIR` is invisible.
- **What the code does.** Falls back to `~/.claude/sessions/<pid>.json`; the log line
  `activity: no registry record for pid …` is the sign that a relocated registry was missed, and only staleness
  (2 h) ends such a session.

### Hooks fire while the app is down
- **What the code does.** The hook appends to a file with one `O_APPEND` write; the app replays this boot's
  events at launch and tails from the byte offset it consumed. The hook never launches the app, never blocks,
  always exits 0.
- **Do not** replace the journal with a socket.

### A hook payload is untrusted input
- **What the code does.** `ActivityTrim` accepts only Claude Code's event names (a payload cannot forge
  `JobBegin`/`JobEnd`), keeps identifiers only, caps stdin at 8 MB, identifiers at 200 characters, labels at
  60, the raw prefix of an unparseable payload at 300, and the line at 4 KB.

### `~/.claude/settings.json` and `~/.zshrc` belong to the user
- **What the code does.** Strict load (any ambiguity is an error, never a guess), backup to
  `settings.json.backup-koffeelid`, entries recognised by the hook path suffix, other tools' entries and
  unrecognised shapes left alone. In `~/.zshrc` only the block between the two KoffeeLid header lines, the
  marker comment and uncommented KoffeeLid `shell-init zsh` lines are removed; another tool's `shell-init zsh`
  line is neither detected nor touched.

### `precmd` must read `$?` first
- **Why.** Later `precmd` hooks (prompts) expect the command's status.
- **What the code does.** `local code=$?` is the first statement and the function returns it.

### Installing hooks from a Debug build
- **Why.** `install-hooks` writes the absolute path of the binary that ran it; a DerivedData path disappears at
  the next rebuild.
- **Do not** run it from anywhere but `/Applications/KoffeeLid.app`. A Debug app shares the journal and the
  preferences with the installed one: launch it with `KOFFEELID_DISABLE_ACTIVITY=1`.

## Working on this Mac

- **The installed app is the daily driver.** `AppleClamshellCausesSleep = No` is usually its arm. Run
  `koffeelid status` before quitting, reinstalling or sending `off`; never send `off` while the lid is closed
  with no external display. `script/install.sh` refuses only while quitting would sleep the Mac at once
  (`status` carries the warning `quitting would sleep the Mac`: armed, lid shut, no external display) — an
  armed Mac with the lid open, or an external display connected, is installed over and the mode put back.
- **Process commands** are scoped to `KoffeeLid.app/Contents/MacOS/` or to the pid file; never by bare name.
- **Claude Code's sandbox** breaks `swift test`, `xcodebuild` and system image/video decoders; run them with
  the sandbox off. `$TMPDIR` differs inside and outside it.
- **The string catalog's key order is not a plain sort.** Edit `Localizable.xcstrings` in place; loading and
  re-serialising it turns a two-key change into a full-file diff.
- **XCTest's summary undercounts here**; count the per-case `passed` lines.
- **A Debug build can print one `warning:` from `appintentsmetadataprocessor`** (`Metadata extraction skipped,
  no AppIntents.framework dependency found`); the bundle it produces then has no `Metadata.appintents`, so its
  App Intents do not reach Shortcuts. Seen on the first Debug build of a session; the next build, which relinked
  `KoffeeLid.debug.dylib`, wrote the metadata. It is not a compiler warning, and the installed Release build has
  the metadata. Check with `ls DerivedData/Build/Products/Debug/KoffeeLid.app/Contents/Resources/Metadata.appintents`.
- **TCC and Login Items are per bundle path and per team id.** The DerivedData build and the installed build
  are different apps; changing the signing team asks for every grant again.
- **A Claude turn that dies when the Thunderbolt dock is unplugged is a network event, not a sleep.** The dock
  carries a USB Ethernet adapter (`en7`); while docked it is the primary interface, and an API stream in flight
  is bound to its address. Unplugging detaches it, Wi-Fi takes over within a second, but the stream cannot
  migrate: Claude Code reports `API Error: Connection lost mid-response` about a minute later and fires
  `StopFailure`. Signature: `configd` logs `interface detach: en7`, `pmset -g log` has no `Sleep` or `Wake`
  line in that window, and the app's assertions and sleep lock are still listed. Do not read it as a failed
  arm. Seen 2026-09-19 12:49 with the lid closed and the auto-arm on: powerd cleared the kernel flag on the
  power-source change, the sleep lock held, the Mac never slept.
- **`log` is a shell function in this account's zsh profile.** `log show …` fails with `too many arguments`;
  call `/usr/bin/log show …`.
