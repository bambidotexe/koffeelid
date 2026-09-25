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

### Clearing the flag with the lid shut starts a clamshell sleep unless the lock still holds
- **Symptom.** A quit or a reinstall with the lid shut on an external display: the displays go dark for a
  second and the session comes back locked.
- **Why.** Clearing the bit makes the kernel evaluate the clamshell inside the same call, and the bit is also
  powerd's closed-display protection (an external display on AC power), so the evaluation finds nothing
  keeping the Mac awake and starts a `Clamshell Sleep`; loginwindow locks the session on the display sleep
  before the sleep is cut short. Only `SleepDisabled` (the sleep lock) makes the kernel refuse that sleep.
- **What the code does.** `disarm` and `shutdown` clear the flag first and release the lock after it;
  `script/install.sh` holds the lock across the relaunch when the sudoers rule exists and hands it to the new
  copy.
- **Do not** release the sleep lock before the flag, or add a return to `.idle` that does.

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

This is every app's trap: `docs/shared/pitfalls.md`, **O1**.

### `.moveToActiveSpace` costs the window its z-order

This is every app's trap: `docs/shared/pitfalls.md`, **O2**.

### Closing System Settings does not give a menu-bar app its window back

This is every app's trap: `docs/shared/pitfalls.md`, **O3**.

### A modal dialog of our own still leaves an accessory app deactivated

This is every app's trap: `docs/shared/pitfalls.md`, **O4**. Here the sleep lock is the one flow that owns a dialog (`PermissionItem.returnsFocus`).

### `NSScreen.main` is nil with no key window
- **What the code does.** Window sizing falls back to the first screen.

### A poll that rebuilds the page blanks it

This is every app's trap: `docs/shared/pitfalls.md`, **O5**.

### A grant named anything but what System Settings calls it

This is every app's trap: `docs/shared/pitfalls.md`, **O6**. The names this app quotes are in `macOS.md` § Permissions.

### A permission asked without a click

This is every app's trap: `docs/shared/pitfalls.md`, **O7**.

### A grant request and a System Settings pane, both at once

This is every app's trap: `docs/shared/pitfalls.md`, **O8**.

### A stepping button in a stack with an invisible spacer stops being where it is drawn

This is every app's trap: `docs/shared/pitfalls.md`, **O9**. Here the footer is `OnboardingWindowController.listPage`.

## Watchdog and launch

### `argv[0]` is useless under launchd
- **Symptom.** The watchdog stands down at once when launchd starts it.
- **Why.** A `BundleProgram` agent starts with a relative `argv[0]` and `/` as working directory.
- **What the code does.** Resolves its own path with `proc_pidpath`.

### Pids are reused
- **What the code does.** The watchdog compares `proc_pidpath(pid)` with the executable recorded in the pid
  file; the activity monitor keeps a replayed session only if its pid is alive, runs its agent **and**, for
  Claude Code, the pid's registry record, when one exists, names the same session (`pruneDead`);
  `ClaudeRegistryRecord` rejects a record whose pid does not match.

### launchd starts the agent before the app at login
- **What the code does.** The watchdog stands down on a missing or pre-boot pid file; the app runs
  `launchctl kickstart` on every start so a live watchdog observes the current pid. A relaunch attempt is
  recorded before `open` runs, so a bundle that cannot launch still trips `CrashLoopGuard`.

## Updates

### A helper started by the app dies with the app

This is every app's trap: `docs/shared/pitfalls.md`, **U1**.

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

This is every app's trap: `docs/shared/pitfalls.md`, **U3**.

### A new version that is gone two seconds later has crashed, or has been quit

This is every app's trap: `docs/shared/pitfalls.md`, **U4**.

### A helper that gives up while the app may still quit

This is every app's trap: `docs/shared/pitfalls.md`, **U5**. Here the clock is `UpdateInstallPlan.stallNotice`.

### `ps` lists the path the kernel ran, not the one the app was installed at

This is every app's trap: `docs/shared/pitfalls.md`, **U6**.

### `diskutil eject <folder>` names the volume the folder sits on

This is every app's fact: `docs/shared/macOS.md` § Updates.

## Privilege

### `sudo -n -l` says yes to anything once any NOPASSWD rule exists
- **What the code does.** Availability also requires `/etc/sudoers.d/koffeelid` to exist.

### A malformed sudoers file locks sudo out
- **What the code does.** The rule is staged as a dotted temp file inside `/etc/sudoers.d`, validated with
  `visudo -cf`, then renamed; absolute tool paths throughout; the user name is validated before it is written.
- **Do not** trust `PATH` or `TMPDIR` in a script that runs as root.

### `get-task-allow` in a development-signed Release build

This is every app's trap: `docs/shared/pitfalls.md`, **B2**. Here `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` for Release in `project.yml` is what keeps it out.

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
- **Symptom.** Under a relocated `CLAUDE_CONFIG_DIR` (an account switcher such as cswap), every Claude Code turn
  ended with Esc or Ctrl-C stays working for 2 h, and the log carries `activity: no registry record for pid …`.
- **Why.** macOS withholds it from a same-user reader, so a per-session `CLAUDE_CONFIG_DIR` is invisible, and
  the registry is not in `~/.claude`.
- **What the code does.** Reads the directory from the transcript path the hooks name
  (`<config>/projects/<slug>/<session>.jsonl`, kept on the session as `transcriptPath`):
  `ClaudeRegistryRecord.configDir(fromTranscriptPath:)` gives `<config>`, and the registry rescues and the
  launch prune read `<config>/sessions/<pid>.json`. `~/.claude` is the fallback for a session no line has
  named a path for (lines from before the field, tracking begun on a tool line); the `no registry record` line
  is then the sign it missed, and only staleness (2 h) ends such a session.
- **Do not** read the process's environment for it (`ProcWalk.environmentValue` returns nil for another
  process), and do not take the folder from a fixed depth: a helper's transcript sits deeper in the same folder.

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

### `exec zsh` and `source ~/.zshrc` end the running job
- **Symptom.** Right after `exec zsh` or `source ~/.zshrc` (the natural thing to type after Set Up Terminal),
  the Mac arms 5 s later and stays armed with nothing running, until the next command in that shell.
- **Why.** `preexec` began a job (labelled `exec` or `source`); then the snippet ran again, mid-command or in
  the new image, and an assignment at load emptied the job variable, so `precmd` ended nothing. The shell is
  alive and watched, so the kqueue never fires.
- **What the code does.** The snippet declares `_koffeelid_job` without assigning it, and an interactive
  shell loading it sends `job end --id zsh-$$` before registering its hooks, which ends the job the pid's
  earlier image began. `exec` is a skipped prefix and an interactive `zsh` a skipped program, so `exec zsh`
  begins nothing. `ShellInitTests` re-source the snippet and `exec` a shell in a real `zsh -f -i`.
- **Do not** assign any of the snippet's state at load, or drop the load's `job end`.

### A shell at its prompt is the truth about a job, not the journal
- **Symptom.** A `job end` that never reached the journal (the hook binary missing during an install or an
  update, a failed write) keeps the Mac armed until the next command in that shell; a timer on the job, the
  other way round, disarms the Mac under a three-hour build.
- **Why.** The journal holds only what the hooks said. The shell knows whether it runs a command: at its
  prompt it owns its terminal's foreground group, while a command runs that group is the command's
  (`docs/macOS.md` § zsh).
- **What the code does.** `ActivityMonitor.probeJobs` asks each job's shell at every pass, at least every
  15 s while a job with a shell exists, and once at replay before the first count: `ShellJobLiveness.probe`
  reads the pid (`ProcWalk.info`, `childStartTimes`), `ShellJobLiveness.judge` decides. A pid gone, or held
  by a process forked after the job began (a recycled pid), drops the job; a process that is no longer a shell
  (it `exec`'d into the program) keeps it for the kqueue; a shell at its prompt with no child it started since
  the job began, seen so twice 5 s apart, drops it; anything else keeps it, with no time limit. Each drop logs `activity: job <id> ended
  without a hook (<reason>)`. Only a job without a shell pid is dropped after 2 h.
- **Do not** time out a job whose shell can be asked, trust a bare pid at replay, or drop a job on one
  sighting of the prompt: the shell owns its terminal for milliseconds between `preexec` and the fork. **Do
  not** count every child of the shell: Powerlevel10k keeps a `gitstatusd` child beside every interactive
  shell on this Mac, so "has a child" is always true and a lost end would hold until the shell exits. Only a
  child forked after the job began counts. Known false negative: a builtin that blocks (`wait`, `read`) looks
  like the prompt, and its job ends after 5 s. Known false positive: a lost end in a shell that has started a
  background child since the job began holds until that child exits.
- **Do not** put a shell's name on the skip list as a plain skip: `bash build.sh` and `sh install.sh` are real
  work. The snippet skips `zsh`, `bash`, `sh` and `fish` only when every word after the name is a flag.

### `precmd` must read `$?` first
- **Why.** Later `precmd` hooks (prompts) expect the command's status.
- **What the code does.** `local code=$?` is the first statement and the function returns it.

### Installing hooks from a Debug build
- **Why.** `install-hooks` writes the absolute path of the binary that ran it; a DerivedData path disappears at
  the next rebuild.
- **Do not** run it from anywhere but `/Applications/KoffeeLid.app`. A Debug app shares the journal and the
  preferences with the installed one: launch it with `KOFFEELID_DISABLE_ACTIVITY=1`.

## Codex hooks

### A hook in `~/.codex/hooks.json` alone never runs
- **Symptom.** The file holds the 12 entries, Codex's `/hooks` screen lists them as untrusted, and no line
  ever reaches the journal.
- **Why.** Codex runs a user hook only once it is trusted: a `[hooks.state."<key>"]` table in
  `~/.codex/config.toml` whose `trusted_hash` equals the hash Codex computes for the entry.
- **What the code does.** `install-hooks codex` writes that table for each of the 12 hooks with the key and
  the hash Codex would compute (`CodexHookTrust`, `docs/macOS.md` § Codex), and the row reads Enabled only
  while all 12 are installed **and** trusted. `CodexHookTrustTests` pins the hash to the ones Codex 0.157.0
  reported over `hooks/list`.
- **If Codex changes its hash.** The row still says Enabled (KoffeeLid wrote what it computed), Codex's
  `/hooks` screen says modified, and the Health page's *Last Codex event* stays at *None yet*. That reading is
  the tell. Re-derive the hash from `codex-rs/hooks/src/engine/discovery.rs` and
  `codex-rs/config/src/fingerprint.rs`, or ask a running `codex app-server` over `hooks/list`, and fix the test.

### The trust key moves with the entry's index
- **Why.** The key ends in the group's index in the event's array. An entry of ours added before a stranger's
  would shift the stranger's key and untrust their hook.
- **What the code does.** Ours is appended after every existing group, and removed from the end. A table of
  ours left under an old key (the file was rearranged by hand) is recognised by its hash and dropped.

### `config.toml` is edited as text, not parsed
- **Why.** A TOML rewrite would lose the user's comments and layout, and Core takes no TOML library.
- **What the code does.** Only `[hooks.state."<key>"]` tables are read, added and removed, the one shape Codex
  writes itself (checked on this Mac through `config/batchWrite`). A `state` written any other way (an inline
  table) is left alone and the install refuses, saying to trust the hooks from Codex's `/hooks` screen,
  because a second definition of the same key would make the file invalid for Codex.

### `SessionEnd` and `Interrupt` timeouts are capped at 3 s
- **What the code does.** Those two entries are written with `timeout: 3`, the others with 5. A larger value
  would draw a warning on every Codex start and be hashed as 3 anyway.

### Codex reports a tool's end after the turn was aborted
- **Symptom.** A Codex session stays working after Ctrl-C (or Esc) until Codex is quit: `koffeelid status`
  counts it, and no `activity: idle` line follows the `Interrupt`.
- **Why.** The `Interrupt` hook fires at the abort, but the tool's process ends later, and Codex fires
  `PostToolUse` for it then, 13 s later in the journal of 2026-09-25, under the aborted turn's `turn_id`. That
  line looks like work, and nothing ends it again: Codex runs `Stop` only when a turn completes normally, never
  after an abort.
- **What the code does.** Every line keeps its turn id (`ActivityEvent.turnId`, from `turn_id` or Claude Code's
  `prompt_id`). The `Interrupt` closes the turn the last main-agent event carrying an id named, and any event
  naming a closed turn but a prompt or a `SessionStart`, a helper's included, only refreshes the session's
  liveness (`ActivitySessionStore.changesNothing`); a prompt opens its turn, even under a closed id. For 120 s
  after an `Interrupt`, a tool or permission line without a turn id is set aside the same way.
- **Do not** forget to un-close an id when a prompt reuses it: every later event of that turn, its `Stop` and
  `Interrupt` included, would be set aside, and the session would stay working with nothing able to end it.
- **Do not** make a `Stop` close the turn: a user's Stop hook that blocks the Stop keeps the same turn running
  under the same id, and that work must count. Do not end the quarantine at the next tool event, or drop the
  turn id to save bytes: the late line is indistinguishable from real work by anything else it carries.

### The daemon outlives every TUI, so the pid proves nothing
- **Symptom.** A Codex session whose end event was lost (an `Interrupt` past its 3 s cap, a hook switched off
  in `/hooks`, the hook binary missing during an install) stays working for 2 h, and a relaunch of the app
  counts it again, though the TUI was quit long ago.
- **Why.** Codex's TUI runs its threads in the managed daemon (`codex app-server --managed-daemon`, one per
  user, parented by launchd, alive across every TUI), so the hook's nearest `codex` ancestor is the daemon and
  every TUI session records its pid. The desktop app does the same in its own long-lived `codex app-server`,
  without `--managed-daemon`. The kqueue on either pid fires only when that host dies, and the launch prune
  finds it alive and running `codex`: neither can ever end one session.
- **What the code does.** `ProcWalk.isSharedCodexHost` recognises both hosts (any `codex` with an
  `app-server` argument, or under `/app-server-daemon/`) and `ProcWalk.isManagedCodexDaemon` the daemon alone
  (its path or its `--managed-daemon` argument); the monitor marks the sessions `hostedBySharedCodex` and
  `hostedByManagedDaemon`. `pruneDead` keeps every session on a shared host without asking about the pid. The session's rollout decides instead: the hook lines keep `transcript_path`
  (`SessionStart`, `UserPromptSubmit`, `Stop`, `Interrupt`), and `ActivityMonitor.checkCodex` reads its last
  64 KB (`CodexRollout`, `CodexRolloutTail`) for a working session quiet for 20 s, every 15 s, and for every
  working Codex session once at launch before anything counts. A `task_complete` or `turn_aborted` stamped
  after the last main-agent event, or naming that event's turn, is `turnOver` (`CodexRolloutTail.decision`);
  a `task_started` with no end is `noteBusy`; anything else decides nothing. The kqueue stays: a host's own
  death still drops every session it hosted.
- **Do not** treat every `codex app-server` as the managed daemon: the desktop app's `codex` carries the same
  argument, and the managed daemon, asked about a desktop-app thread, answers `notLoaded` and would end a live
  turn. Only `hostedByManagedDaemon` sessions are asked; the others are decided by their rollout.
- **Do not** judge an end marker by its stamp alone: when the `Interrupt` hook is lost, the aborted tool's
  late `PostToolUse` becomes the last main-agent event, stamped after the `turn_aborted` it belongs to, and
  the session would stay working for 2 h. Its turn id is the same as the marker's.
- **Do not** read the rollout's modification time as an end: a tool that sleeps for half an hour writes
  nothing for half an hour. **Do not** count an `item_completed` as a turn marker: Codex writes one for an
  aborted call after the abort. **Do not** keep, log or return anything of a rollout line but its type, its
  stamp and its turn id: the file is the conversation. **Do not** let the launch check start anything: it
  only ends turns the replay counted.

### The daemon's protocol is undocumented and versioned
- **Symptom.** After a Codex update, a quiet TUI session is decided by its rollout only, and the log carries
  `activity: Codex daemon not answering; using the rollout` (once per launch) or `activity: Codex daemon
  reports an unknown thread status …` (once per status value).
- **Why.** The control socket is Codex's app-server `v2` protocol over a WebSocket on a unix socket, meant for
  Codex's own clients, with no documentation or stability promise; a token, a renamed method, a reshaped
  answer or a new status would each break the reading. It also runs only the TUI's threads: a `codex exec`
  or desktop-app thread runs in its own process, and the daemon, which reads any thread from disk, would call
  it `notLoaded` or leave it out of its list while it works.
- **What the code does.** Fails closed. `CodexDaemonClient` sends only `initialize`, `initialized`,
  `thread/read` and `thread/loaded/list`, each call with 1 s overall from the moment it is asked, on a
  utility queue, non-blocking, the deadline checked before every read however many frames keep arriving. A
  ping or pong is read past; a refusal, a timeout, an `error`, a close, a masked frame, a fragment, an
  over-long frame, an `initialize` answer without `userAgent`, a list with a `nextCursor`, or an answer of any
  other shape is nil (`WebSocketFrame`, `CodexDaemonRPC`, `CodexThreadRecord` pin the shapes), and the rollout
  decides. Only `notLoaded`, `idle` and `active` decide; any other status is the rollout's. Only a
  `hostedByManagedDaemon` session is asked, and an answer that arrives after the session changed is dropped.
- **Do not** call any other method: the same socket starts turns, answers approvals and writes config. **Do
  not** block the main thread on it, or wait longer than 1 s. **Do not** read a partial loaded list, or a
  thread outside the daemon's, as proof that a thread is not running: the turn would be ended under a live
  session.

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
