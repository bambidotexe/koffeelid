# macOS mechanisms KoffeeLid relies on

Source of truth for "why does the code do that". Verified on this Mac (Mac16,8, macOS 26) with `ioreg`,
`pmset`, the unified log (`/usr/bin/log show`; the kernel's `PMRD:` debug lines and powerd's are both in it),
the app's own diagnostics log, the XNU sources and the PowerManagement (powerd) sources.

## Kernel lid-sleep flag

- `IOPMrootDomain` user client (`IOServiceOpen`, type 0), external method 12 with one scalar input: `1`
  disables lid-close sleep, `0` restores it. XNU `iokit/IOKit/pwr_mgt/IOPMLibDefs.h` lists selector 12 as
  `kPMSetClamshellSleepState` (11 is `kPMGetSystemSleepType`). The flag is process-independent: a crashed
  process leaves it set until something clears it or the Mac restarts.
- Observable as `AppleClamshellCausesSleep` on the root domain (`No` = lid sleep currently disabled);
  `AppleClamshellState` is the lid (`Yes` = closed). The first value is refreshed only by the kernel's own
  clamshell notifications (`sendClientClamshellNotification`), never by a selector-12 write, so after a set it
  can read `Yes` until the next lid or power event. `reapplyFlag` therefore sometimes re-applies an already
  set bit (log `re-applied lid-sleep flag after power-source change` on a battery-percentage tick, kernel
  `setClamShellSleepDisable(2->2)`): harmless. Trust `koffeelid status`, the log and `pmset -g assertions`.
- **powerd owns the same bit.** xnu keeps a two-bit mask, `clamshellSleepDisableMask`: `Internal = 0x01`
  (the kernel sets it while waking and clears it once full wake completes) and `Powerd = 0x02`. Selector 12
  sets or clears the *powerd* bit for every caller (`RootDomainUserClient.cpp`), there is no third bit and no
  per-client tracking. powerd recomputes its own policy (`setClamshellSleepState` in `PMAssertions.c`: desktop
  mode with AC, or an active `UserIsActive` / `DisplayWake` / `PreventSystemSleep` assertion carrying
  `AppliesOnLidClose` — a property that needs the private `com.apple.private.iokit.assertonlidclose`
  entitlement, so no third-party app can hold one) on every power-source change and every raise/release of
  those assertion types, and writes the bit whenever its result flips. Plugging the charger makes PowerChime
  hold a `DisplayWake` assertion for the chime (~1 s); its release flips powerd's result 1 → 0, powerd writes
  0, the kernel sees the mask reach 0 with the lid closed (`setClamShellSleepDisable` →
  `kLocalEvalClamshellCommand` → `shouldSleepOnClamshellClosed`) and starts a `Clamshell Sleep` inside that
  same call. Verified 2026-09-11 in the unified log, all within one millisecond: powerd `EvaluateClamshell.
  Disable :  0 because {DesktopMode with AC: 0, assertions 0`, kernel `PMRD: setClamShellSleepDisable(2->0)`,
  `PMRD: sleep reason Clamshell Sleep`; `pmset -g log` shows `Entering DarkWake state due to 'Clamshell
  Sleep'`. Display hot-plug (WindowServer's `PreventSystemSleep` + `ProcessingHotPlug`) and leaving desktop
  mode do the same. Re-applying the flag afterwards is too late by construction.
- What that sleep is: full wake → dark wake, with `kIOMessageSystemWillSleep` (hence
  `NSWorkspace.willSleepNotification`) sent on that first step, then `checkSystemCanSleep(reason)` in
  `evaluatePolicy`, which honours the CPU assertion bit powerd raises for every active `PreventSystemSleep`
  (on AC only; powerd disables that type on battery). Holding ours keeps the Mac in dark wake instead of
  sleeping — the "lid-sleep override" hold in `KoffeeLidController.handleExternalSleep`. The kernel
  re-evaluates the clamshell 20 s after every full wake (`fullWakeDelayedWork`), which is why the hold
  re-applies the flag at once. Forcing a full wake from there (`IOPMAssertionDeclareUserActivity` →
  `kPMActivityTickle`) was left out on purpose: raising or releasing that assertion makes powerd recompute
  again and, after a dark wake, powerd always sends its next result to the kernel — another write of 0 and
  another sleep. HID input or opening the lid brings full wake back.
- The complete answer is `SleepDisabled` on the root domain (`pmset disablesleep 1`, `userDisabledAllSleep`
  in xnu): checked first in `checkSystemSleepAllowed`, before every sleep request, clamshell evaluations
  included. `IORegistryEntrySetCFProperties` on the root domain needs the private
  `com.apple.private.iokit.rootdomain-set-property` entitlement, and powerd's path needs root — hence
  `SleepLock` runs `sudo -n /usr/bin/pmset disablesleep 1|0` under the sudoers rule in `SleepLockSetup`
  (`docs/development.md`). It persists across reboots in `/Library/Preferences/com.apple.PowerManagement.plist`
  (`SystemPowerSettings.SleepDisabled`), so the app records it in `~/Library/Application Support/KoffeeLid/sleep-lock`
  and launch recovery releases a stale one.
- Around real sleep/wake and display changes the root domain still drops the bit on its own; `PowerManager`
  re-applies it after each notification while armed (log: `re-applied lid-sleep flag after …`).
- Assertions while armed: `PreventUserIdleSystemSleep` "KoffeeLid: keeping Mac awake" and
  `PreventSystemSleep` "KoffeeLid: protecting closed-lid power transitions". Armed + screen on adds
  `PreventUserIdleDisplaySleep` "KoffeeLid: keeping the display on" plus an `IOPMAssertionDeclareUserActivity`
  every 30 s while the lid is open (the screen saver and "require password after…" run on the user-idle
  timer, which a display assertion alone does not reset).

## Lid-angle sensor

IOHIDManager matching `VendorID 0x05AC, ProductID 0x8104, PrimaryUsagePage 0x20, PrimaryUsage 0x8A`; on this
Mac an `AppleSPUHIDDevice`. Feature report id 1; degrees = `UInt16(report[1]) | UInt16(report[2]) << 8`,
valid 0…180, integer resolution, and it flickers between neighbouring degrees while the lid rests (hence
the 1.5° stillness bands in `FoldTracker` and `ReopenCancelWatch`). **The value updates at 10 Hz**: polled at
250 Hz while the lid moved (2026-09-11, `script/lid-sensor-rate.swift`, 34 changes in 6 s), consecutive
changes were never closer than 95.5 ms (median 99.6 ms), with steps of 1–10° depending on speed; one
`IOHIDDeviceGetReport` costs ~0.5 ms (median 520 µs, max 1.6 ms). Polled only while someone needs it
(`LidAngleObserver` consumers): 30 Hz at rest, 120 Hz while the value has changed in the last 0.7 s (to time
each change to ~8 ms), delivered at 30 Hz.

## Built-in display and lock

- Brightness: `DisplayServices.framework` (private), `DisplayServicesGetBrightness/SetBrightness`. The
  previous level is written to `display-brightness-recovery.json` before darkening and the app refuses to
  darken if it cannot persist it; the zero read-back is verified; fallback `/usr/bin/pmset displaysleepnow`.
  Brightness is restored on lid open, disarm, quit and at the next launch if the file survived a crash.
- Lock on reopen: `SACLockScreenImmediate` from the private `login.framework`, retried until
  `CGSessionCopyCurrentDictionary` reports `CGSSessionScreenIsLocked`.

## Process supervision

`koffeelid.pid` (pid line + executable path line) in `~/Library/Application Support/KoffeeLid/`;
`KoffeeLidWatchdog` LaunchAgent (`BundleProgram Contents/MacOS/KoffeeLidWatchdog`, `KeepAlive.SuccessfulExit
false`, `RunAtLoad`) registered through `SMAppService`; `CrashLoopGuard(maxRelaunches:window:)` with a
`RelaunchHistoryStore`; stands down on clean exit, missing pid file, pid file predating boot, crash loop,
relaunch failure or no fresh pid within 30 s. Diagnostics in `diagnostics.log` + `diagnostics.1.log`,
guarded by `diagnostics.lock`.

## Other lid-sleep utilities on the same Mac

Any app that sets the same kernel flag will fight KoffeeLid: one arm undoes the other's disarm and
vice-versa. That is why the launch/quit clears in `KoffeeLidController` are conditional (only when this
instance set the flag or left evidence of an unclean exit), and why `docs/manual-checks.md` asks for such
apps to be quit before testing. Vorssaint, a keep-awake utility, holds only `PreventUserIdleSystemSleep` and
`PreventUserIdleDisplaySleep` and coexists fine; Armed + screen on replaces it.

## Permissions and how they are reset

- **Sleep lock** = a sudoers rule (`/etc/sudoers.d/koffeelid`, 0440) written as root through
  `NSAppleScript` `do shell script … with administrator privileges` (`SleepLock.installRule/removeRule`,
  script from `SleepLockSetup`, validated with `visudo -cf` in a temp file before the move). `sudo -n -l
  /usr/bin/pmset disablesleep 1` tells whether it exists without a password.
- **Login Items** (watchdog agent) = Background Task Management, keyed by bundle id **and team id**
  (`sfltool dumpbtm` shows Disposition and Team Identifier). No per-app reset exists; `sfltool resetbtm` wipes
  every app's approvals. Changing the signing team makes the agent a new item that needs approval again.
- **Screen Recording** = TCC (`tccutil reset ScreenCapture dev.rubens.koffeelid` works as the user).
- **Notifications** = usernoted's group preferences
  (`~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist`,
  `apps[]` entry with `bundle-id` and `auth`); dropping the entry and `killall usernoted` returns the app to
  "not determined". `~/Library/Preferences/com.apple.ncprefs.plist` does not hold it on macOS 26. The app only
  calls `requestAuthorization` at launch once onboarding is completed, so the first prompt comes from the
  Permissions row.
- **Preferences** = the `dev.rubens.koffeelid` UserDefaults domain (`defaults delete`).
- Gatekeeper on other Macs: Apple Development-signed builds are rejected (`spctl -a -vv`); distribution needs a
  Developer ID Application signature, hardened runtime and notarization (`script/release.sh`).

## Claude Code hooks and registry

Three externally-owned surfaces the activity feature depends on, all undocumented upstream and verified
through MySidepulse (`~/Projects/my-sidepulse`, v1.5.2) on 2026-08-26:

- **Hook events and payload keys** — the 15 event names in `ActivityEventName.claudeCodeEvents` and the
  payload fields `hook_event_name`, `session_id`, `agent_id`, `tool_name`, `notification_type`, `source`,
  `background_tasks` (`ActivityTrim.event(fromHookPayload:)` reads only these; tool input/output, prompts
  and assistant messages are dropped at ingestion, never journaled).
- **`<config>/sessions/<pid>.json`** — Claude Code's own per-process registry record
  (`ClaudeRegistryRecord`): `pid`, `sessionId`, `status` (`busy` while a turn runs, `idle` at the prompt) and
  `statusUpdatedAt` (epoch milliseconds). The one signal about a turn that does not travel through hooks —
  Esc and Ctrl-C fire neither.
- **`CLAUDE_CONFIG_DIR`** — the environment variable that relocates the registry directory away from
  `~/.claude`, read from the Claude process itself (not the hook's own environment) so a per-session
  redirection is still found.

On this Mac the third one does not actually work: `ProcWalk.environmentValue` cannot read another process's
environment — macOS withholds it from a same-user reader without extra entitlement, confirmed with `ps -E`,
which prints no environment for a live Claude Code process either — so the read always returns `nil` and
`ClaudeProcessRegistry.read` always falls back to `~/.claude/sessions/<pid>.json`. A `CLAUDE_CONFIG_DIR`
redirection (the way SidePulse itself can run under `cswap`) would not be found this way; the log line
`activity: no registry record for pid …` is the canary that the fallback path missed. The other canary,
`activity: hooks look dead for …`, fires when the registry says `busy` but no hook has landed for 5 minutes:
not a wrong path, but a session whose hook delivery died mid-turn.

## Sounds

The six lid-close sounds (blip pop, bloop, chime blip, enter, notification, tick) live in
`App/Resources/Sounds/close-sound-<name>.mp3`; provenance is listed in `SoundEffects-LICENSE.txt` next to them.
Adding one: drop the mp3 there (folder reference, no project regeneration), append the name to
`LidCloseSoundPlayer.soundNames`, add its label to the popup in `SettingsViewController` and to the string catalog.
