# What KoffeeLid does

KoffeeLid is a macOS menu-bar app (bundle id `dev.rubens.koffeelid`, no Dock icon) that keeps a MacBook
running with the lid closed. It can be armed by hand, for one close with a lid gesture, or by itself while
Claude Code, Codex, Copilot, OpenCode or a terminal command is working. While armed it darkens the built-in panel when the lid shuts,
plays a sound, shows a closing-only "the desktop stays upright behind the glass" effect, and locks the screen
when the lid reopens. A `koffeelid` command line, `koffeelid://` URLs and App Intents drive the same modes.
English and French; it looks for a newer release on GitHub by itself and installs one on request; no licensing.

This document is the authority on behaviour: what it says is what the app does today. It changes in the same
commit as the code, an outdated rule is replaced rather than annotated, and a request that contradicts a rule
written here is put to the owner before anything is implemented (`CLAUDE.md` § Changing behaviour).

## Modes and arming

Three manual modes (`ArmMode`):

| Mode | Lid closed | Lid open |
|---|---|---|
| **Off** | the Mac sleeps (macOS default) | nothing |
| **Armed** | the Mac keeps running, panel dark | nothing extra |
| **Armed + screen on** (`caffeinate` in code and CLI) | same as Armed | the display never idle-sleeps, no screen saver, no auto-lock |

Independent of the manual mode there is an **auto level** (`ActivityArmPolicy.isOn`): on while Claude Code,
Codex, Copilot, OpenCode or a terminal command works, and through a hold-off afterwards. **The Mac is armed while either the manual mode or
the auto level holds it.** Neither changes the other.

| Way to arm | What it does |
|---|---|
| Menu (left-click the cup) | picks Off / Armed / Armed + screen on; the current one is checked |
| Right-click the cup | Off → Armed → Armed + screen on → Off; an armed mode that has stood 3 s or more goes straight to Off |
| ⌃⌥⌘L | toggles Armed (from Armed + screen on: switches to Armed) |
| ⌃⌥⌘K | toggles Armed + screen on (from Armed: switches to it) |
| `koffeelid arm \| off \| caffeinate \| toggle-armed \| toggle-caffeinate`, `koffeelid://<verb>`, App Intents | same transitions; `disarm` and `toggle` are accepted as aliases of `off` and `toggle-armed` |
| Fn (Globe) + close the lid | arms **one close** (below); Option can replace Fn |
| Claude Code, Codex, Copilot or OpenCode hooks / zsh snippet | raise the auto level (below) |
| An update's Install and Relaunch | the new version goes back to the manual mode that was on at the click (§ Updates) |

Every manual source stays in its mode until changed. Switching Armed ↔ Armed + screen on happens in place;
the kernel flag is not touched. Choosing a manual mode over an auto-only arm makes the arm manual as well.

**Off from the user** (menu, right-click, shortcut, CLI, URL, intent) sets the manual mode to Off. The session
ends unless the auto level is on, in which case the Mac stays armed by the auto level alone.

### Arming can be refused

`ArmingPolicy` refuses, in this order: the display list cannot be read; thermal pressure is serious or
critical; the low-battery option is on, the Mac is on battery and the charge is at or below the threshold. A
failed kernel-flag write refuses too. The user gets a "KoffeeLid did not arm" notification with the reason;
the CLI prints `did not arm: …` and exits 1. An external display does not refuse an arm.

### The lid gesture (one-close arm)

With the lid gesture on (Settings › Arming › Lid gesture) and a lid-angle sensor present:

- Hold the modifier and start closing. After "Arm after closing by" degrees of closing travel (default 4°) the Mac
  arms in Armed mode with source `gesture`. The modifier may be released up to 1 s before that travel is
  reached. The gesture is cancelled if the modifier is released for more than 1 s before the travel is
  reached, if the lid reopens by "Cancel when reopened by" degrees (default 4°), or if a started close stalls
  for 1.5 s.
- Before the lid shuts, the arm is cancelled by reopening the lid by "Cancel when reopened by" degrees from the
  lowest angle reached, or by holding the lid still for the effect's "Flatten again when still for" delay.
  Stillness does not count while the modifier is held.
- Once the lid has shut, the arm **survives the lid opening** and ends when the user logs back in. The reopen
  locks the screen; the lock landing starts the hold; the unlock releases it. Closing and reopening the lid in
  between keeps the Mac awake; those closes play the sound but no effect. If no lock ever takes (no login
  password), the arm ends at that reopen instead.
- A one-close arm switched in place to another mode (for example with ⌃⌥⌘K) becomes a manual arm.
- Fn + close while already armed from another source does not arm again: the effect follows the lid from the
  current angle as visual confirmation, and the mode is unchanged.
- The detector is off while an external display is connected, while the lid is closed, and during a one-close
  arm.

Arrow keys, F1–F12 used as function keys and an external keyboard's navigation keys carry the same modifier
flag as Fn; a reading counts as Fn only without the numeric-pad flag and with the physical Fn key (virtual key
63) down. With the Input Monitoring grant KoffeeLid also reads the built-in keyboard's own Fn key, and only that
key counts: an external keyboard's Fn/Globe key never arms. Without the grant any keyboard's Fn key counts.

### Auto-arm on activity

Off by default ("Arm while Claude Code, Codex, Copilot, OpenCode or a terminal command is running", Settings ›
Auto-Arm). Setting up any of the five hooks from that page or from the onboarding turns it on.

- **Claude Code**: 15 hook events in `~/.claude/settings.json` run the embedded `KoffeeLidHook hook`, which
  appends one trimmed line per event to `~/Library/Application Support/KoffeeLid/activity.jsonl`. A session
  counts as working from a prompt or tool event until its `Stop`, or until its turn closes (below). A session
  blocked on a question, a plan
  approval or a permission does not count. A `Stop` while helpers or background shells are still out keeps the
  turn running until they finish or fall silent (240 s per helper, 90 s grace, 30 min cap). A compaction is work
  while it runs and changes nothing once it ends: `PreCompact` counts as working, the `SessionStart` of source
  `compact` in between changes nothing, and `PostCompact` puts the session back to the state `PreCompact` found
  it in — working if the compaction ran inside a turn, idle or finished if it ran at the prompt; a compaction
  whose `PostCompact` never came is forgotten at the next prompt, `Stop`, `Interrupt` or new `SessionStart`.
- **Codex**: 12 hook events in `~/.codex/hooks.json` run `KoffeeLidHook hook codex`, which appends the same
  kind of line. Codex runs a hook of the user's only once it is trusted, so the set-up also writes each hook's
  trust (its key and the hash Codex computes for it) under `[hooks.state]` in `~/.codex/config.toml`; both files
  are backed up first (`hooks.json.backup-koffeelid`, `config.toml.backup-koffeelid`). The hook counts as set up
  only while all 12 events point at this copy **and** are trusted and not disabled there. A session counts as
  working from a prompt or tool event until its `Stop`, or until its turn closes (below); its `Interrupt` (Esc,
  Ctrl-C) closes the turn and ends its helpers at once. A session blocked on a permission or on `request_user_input`
  does not count. Helpers hold a `Stop` as they do for Claude Code.
- **Copilot**: 7 hook events in `~/.copilot/hooks/koffeelid.json` run `KoffeeLidHook hook copilot <event>`;
  camelCase keys, `exec` (no shell), the event name riding in `args` since a camelCase payload carries none.
  The file is wholly KoffeeLid's own, so there is no backup and no merge: setting it up or removing it refuses,
  unchanged, a file already at that path that does not look like one of ours (removal also refuses one it
  cannot even parse, rather than guessing). Never `preToolUse` or `permissionRequest`:
  either denies the tool on a failing hook, so a hook file outliving the app would block every Copilot tool
  call. The hook counts as set up only while all 7 events point at this copy **and** neither
  `~/.copilot/settings.json` nor `~/.copilot/config.json` sets `disableAllHooks`. A session counts as working
  from a prompt or tool event until its `agentStop`, or until its turn closes (below, read from
  `events.jsonl`); Copilot has no `Interrupt` hook. A session blocked on a permission or a question does not
  count.
- **OpenCode** has no command hooks; KoffeeLid installs a plugin instead,
  `~/.config/opencode/plugins/koffeelid.js`, which a running server loads, reloads and unloads by itself
  within a second, no registration, no trust step. The file is wholly KoffeeLid's own, so there is no backup
  and no merge: setting it up or removing it refuses, unchanged, a file already at that path that does not
  look like one of ours (removal also refuses one it cannot even read as text, rather than guessing). The
  plugin forwards OpenCode's own events verbatim to `KoffeeLidHook hook opencode`; `ActivityTrim`
  maps them onto this vocabulary (`SessionStart`, `UserPromptSubmit`, tool events, `Stop`, `Interrupt`, …) on
  the way into the journal. A subagent's session (one with a `parent_id`) becomes helper events of its
  top-level ancestor, walking every link in between, not of its immediate parent. The hook counts as set up
  only while the installed file matches, byte for byte, what this copy of KoffeeLid would write today. A
  session counts as working from a prompt or tool event until its execution ends:
  `session.execution.succeeded` fires `Stop`; `session.execution.failed` fires `StopFailure`, which does not
  count as running, the way a permission wait does not; `session.execution.interrupted` fires `Interrupt`,
  which closes the turn and ends its helpers at once. Every busy period ends in exactly one of these three, so
  OpenCode needs no rescue for a quiet turn the way Claude Code, Codex and Copilot do.
- **A closed turn stays closed.** Every event of a turn carries the turn's id: Claude Code's `prompt_id`,
  Codex's `turn_id`. An `Interrupt`, or a verdict that the turn is over (§ Without an end event), closes the
  turn. Any event that arrives for a closed turn, but a prompt, a `SessionStart`, a `SessionEnd` or a tool call
  of a turn a verdict closed, only proves the hook alive and changes nothing, as the end of a tool Codex aborted
  does seconds or minutes later; a helper's events are among them. A main-agent tool call (`PreToolUse`) of a
  turn a verdict closed opens it again and counts, as a prompt does, since a new tool call is never the
  straggler of an aborted tool and the registry can close a Claude Code turn that waits on a dialog whose hook
  lines were lost; a turn an `Interrupt` closed opens again only with a prompt. A `Stop` ends the turn but does not close it: a Stop hook that blocks it keeps
  the turn running, and its later events count. The turn closed is the one named by the last main-agent event
  that carried an id. A prompt always opens a turn, whatever id it carries, a closed one included. For 120 s
  after an `Interrupt`, a tool or permission event without a turn id changes nothing either. A line without a
  turn id otherwise follows the rules above.
- **Terminal (zsh)**: a `preexec`/`precmd` snippet in `~/.zshrc` reports each command. A command counts once it
  has run longer than "Ignore commands shorter than" (default 5 s, `KOFFEELID_ARM_AFTER` per shell).
  Leading `VAR=value` words and the prefixes `sudo`, `time`, `command`, `builtin`, `exec`, `nice`, `nohup`,
  `env`, `noglob` and `caffeinate`, each with the `-` flags after it (and the argument of `sudo -u`, `-g`, `-h`,
  `-p`, `-C`, `-D`, `-T`, `-U`, `-r`, `-t`, `nice -n`, `env -u`, `-C`, `-S`), are skipped before the program's
  name is read; a line of prefixes alone (`sudo -i`, `sudo -s`) opens an interactive shell and begins nothing.
  Interactive programs listed in `KOFFEELID_SKIP` (editors, pagers, `ssh`, `tmux`, `top`, `tig`, `lazygit`,
  `su`, `login`, …) never count, and neither do the agents, which are followed through their own hooks
  (`claude`, `codex`, `copilot`, `opencode`). The shells in that list (`zsh`, `bash`, `sh`, `fish`) are
  skipped only when they run interactively, every word after the shell's name being a flag (`zsh`, `bash -l`,
  `zsh -f -i`); a shell that runs a script (`bash build.sh`, `sh -c '…'`, `zsh script.zsh`) counts. A shell
  that re-reads the snippet, or is replaced by `exec`, ends the job it was running; the snippet releases the
  shell's slot when it loads. While a command runs, its shell is asked every 15 s whether it still runs one: a
  shell gone ends the job at once (kqueue); a shell pid now held by a process started after the command began
  (a recycled pid) ends it at the next ask, within 15 s, and at launch before the first count; a shell back at its prompt with no child it started since the job began, for 5 s, ends it,
  the end having been lost (a child older than the job, such as Powerlevel10k's `gitstatusd` or an earlier `&`
  job, says nothing about it); a shell replaced by its program is kept until that program exits; a job without
  a shell pid is dropped after 2 h. At launch each replayed job's shell is asked once before anything counts:
  a job whose shell is gone never counts, and one whose shell sits at its prompt counts until the settle drops
  it (up to 5 s, then the 60 s hold-off).
- **Without an end event**: a Claude Code process or a shell that exits drops its sessions and jobs at once
  (kqueue). A Claude Code turn ended with Esc or Ctrl-C fires no hook; Claude Code's own
  `sessions/<pid>.json` record going `idle` ends it within about 35 s, and an `idle_prompt` or
  `agent_needs_input` notification after 50 s of main-agent quiet ends it too. The registry's verdict closes
  the turn; the notification, a timer rather than proof, does not. The registry is found from the session's
  transcript path (`<config>/projects/…`), so a relocated `CLAUDE_CONFIG_DIR` is found; `~/.claude` is the
  fallback. The app records its own verdicts (a turn over, from the registry, a rollout, Codex's daemon or a
  Copilot `events.jsonl`, and a dialog answered) in the journal, stamped when the turn ended or the answer was seen, so a relaunch replays
  them; a verdict older than the session's last main-agent event changes nothing, and a verdict about a
  session the journal does not hold is ignored. At launch,
  after the 2 h rule below, a replayed session is kept only while its pid is alive, runs its agent and, when a
  Claude Code registry record exists for the pid, names the same session; then the registry, the rollouts and
  Copilot's `events.jsonl` files are read before the first arm, whatever the turn's quiet, and a session
  already over is never counted.
  A Codex session of the TUI is hosted by Codex's managed daemon, one per user, alive across every TUI: the
  pid its hooks record is the daemon's, so only the daemon's death drops its sessions. The desktop app's own
  `codex` is a shared host too, alive across its threads: its pid proves nothing either, and only its death
  drops its sessions. `codex exec` records its own process, and its death drops its sessions. Every Codex hook names the
  session's rollout file (`transcript_path`), and a working Codex session quiet for 20 s with nothing out is
  checked against it every 15 s, and once at launch before anything counts: a
  `task_complete` or `turn_aborted` that is stamped after the last main-agent event, or that names the turn
  that event belonged to, ends the turn, however it ended, and closes it (the late `PostToolUse` of a tool
  Codex aborted arrives after the `turn_aborted`, under the same turn id); an end of an earlier turn stamped
  before that event decides nothing; a `task_started` with no end keeps it alive while Codex still writes to
  the rollout; a rollout silent for 2 h no longer does; a rollout that cannot be read decides nothing, and a
  rollout that decided nothing is read again 15 s later at the earliest, however much else the journal
  receives, and only a path under `~/.codex/sessions/` that names the session's own rollout is
  read. When Codex's managed daemon is running, it is asked first (`thread/read`): a thread it has not
  loaded, or has idle, has nothing running; an active one keeps the session alive; the rollout decides when
  the daemon does not answer. Only a session the managed daemon hosts is asked: the desktop app's `codex` is
  never asked, and its sessions are decided by the rollout alone; a status other than these three decides
  nothing either, and every question has 1 s to be answered. At launch the managed daemon is asked which
  threads it holds (`thread/loaded/list`): a working session it hosts whose thread is not among them has
  nothing running, and nothing counts before that answer, or before 2 s without one (an answer later than
  that is dropped). An answer about a thread other than the one asked about decides nothing. A Copilot turn ended with Ctrl+C
  or a double Esc fires no hook, and a failed turn fires no `agentStop`: a working Copilot session quiet for
  20 s with nothing out is checked against its `events.jsonl` every 15 s, and once at launch before anything
  counts. An `abort` (the turn was aborted), a `session.error` (it failed), a `session.shutdown` (the session
  closed) or the start of the session's own `agentStop` hook (it finished), stamped after the last main-agent
  event, ends the turn and closes it; Copilot names no turn, so an end stamped before that event is an earlier
  turn's and decides nothing. A subagent's `agentStop`, written into its parent's file under the subagent's
  id, is not the parent's end. A step of a turn with no end after it (a prompt taken, a model call, a message,
  a tool, a permission) keeps the session alive while Copilot still writes the file; a file silent for 2 h no
  longer does; a file that cannot be read decides nothing, and a file that decided nothing is read again 15 s
  later at the earliest. Only `<session-state>/<session id>/events.jsonl` is read, where `<session-state>` is
  `$COPILOT_HOME/session-state` when the app's own environment sets `COPILOT_HOME`, else
  `~/.copilot/session-state`: a `COPILOT_HOME` set only in the shell that runs `copilot` is not seen by the
  app, which reads its own environment's `~/.copilot`, so such a Ctrl+C'd or failed turn is invisible to the
  check and ends only at Copilot's own exit or the 2 h staleness. The launch checks only end turns, but for a
  Claude Code dialog the registry says was answered, which counts again as it would at the first check. A
  session silent for 2 h is dropped; a command is asked of its shell instead (Terminal, above).
- **The level rises** the moment something counts and the feature is on: an idle Mac arms (Armed, source
  `activity`); an already armed Mac is unchanged.
- **The level falls** after the longest hold-off among the kinds that ran during the stretch: 30 min after
  Claude Code, Codex, Copilot or OpenCode, 1 min after a command (Settings › Auto-Arm). Work that resumes inside the
  wait cancels it. Keyboard, trackpad or mouse input at the Mac after the work ended drops the level at once:
  the wait exists for a remote user. When the level falls the Mac disarms only if the manual mode is Off.
- **"Disarm once finished"** (menu item, present when a hook is set up): the wait becomes one minute and the
  manual mode is released with it. It stays pending until it fires, is clicked again, or a safety rail fires.
- After a safety rail or a refused auto-arm, the level stays off until the running work stops and something
  starts again.
- `KOFFEELID_DISABLE=1` in a process's environment silences the hook binary; `KOFFEELID_DISABLE_ACTIVITY=1`
  in the app's environment turns the whole feature off.

## Lid closed, lid open

| Event while armed | What happens |
|---|---|
| Lid closes | the effect stops; the built-in panel's brightness goes to zero (previous level saved first; fallback `pmset displaysleepnow`); the lid-close sound plays if enabled (below); Armed + screen on stops declaring user activity |
| Lid opens | brightness restored; the display list is re-read; the screen locks (`SACLockScreenImmediate`, retried after 0.5, 1, 2, 4 and 8 s until macOS reports the session locked, then a notification if it never does); the effect is prepared again; the arm stands |
| Lid opens, not armed | a saved brightness is restored |

The lock on reopen is not a preference.

**The lid-close sound** always plays on the Mac's speakers. When the user listens on something else (AirPods
or any Bluetooth, USB or AirPlay output), it plays there too, and the speakers wait for that output's delay so
both are heard as one sound. Headphones in the jack silence the speakers, so it plays only in them. With
"Play it at a set volume" on, both are unmuted for the sound: the speakers at the set volume, the other output
at half of it (`VolumeOverridePolicy.listeningShare`), or at the user's own volume when that is louder, and
every volume and mute is put back 0.25 s after the sound ends, at once if the default output changes or the
app quits, and, should the audio system never report the end, no later than the clip's length plus the
speakers' wait plus one second after the sound started (`VolumeOverridePolicy.restoreDeadline`).
Unmuting is deliberate: a Mac shut in a bag has to be heard staying awake. Off, each output plays at its own
volume and a muted one stays silent.

**The same sound with the lid already closed.** While armed with the lid closed, the sound plays again, the same
clip through the same outputs at the same volumes, when the charger is unplugged or the displays change (a display
plugged or unplugged, and also one going to sleep or waking up), so a Mac taken off the desk is heard staying awake
before it goes in a bag. Each has its own switch, both on by default, independent of the lid-close switch. They play
while standing by on an external display too: behind a closed lid macOS keeps listing a display that is gone until
the lid opens, but it does report that the displays changed. After any sound, the lid-close one included, nothing
plays for 5 s (`ClosedLidReminder.quietSeconds`), so a dock unplugged with its displays and its charger plays once;
display changes in the 5 s after the lid closes (`lidCloseSettleSeconds`) are the close itself and play nothing. Only
the switch from the charger to the battery counts, not the charge dropping on battery. A low-battery disarm on the
unplug plays nothing. The log says `closed-lid reminder: charger unplugged` or `… displays changed`.

## External display

An arm is allowed and the kernel flag stays set, but darkening, the lid-close sound, the effect, the lock on reopen
and the gesture **stand by** while any external display is online (the sound's closed-lid reminders do not, § Lid
closed, lid open); the menu header and the tooltip say "Standing
by: external display". Connecting a display while the lid is closed locks the screen at once. Connecting one
ends a one-close arm that has not closed yet. Disconnecting restores the lid behaviours. A display that went
away behind a closed lid still locks the reopen (the list is re-read at lid open, and a lock skipped for a
display that disappears within 2 s is issued after all).

## Power and safety rails

| Condition | Effect |
|---|---|
| Low-battery option on, on battery, charge ≤ threshold (default 10 %, 5–50 %) | nothing arms; an armed session disarms with a notification. On AC everything is allowed; unplugging below the threshold disarms at once. A missing battery reading with the option on disarms too |
| Thermal pressure serious or critical | nothing arms; an armed session disarms with a notification |
| Another app or the user sleeps the Mac (`pmset sleepnow`, Apple menu) | the session disarms with a notification |
| macOS starts a lid sleep behind the arm (charger plugged, display change) | with the sleep lock set up this never starts. Without it the session is held in dark wake, the flag is re-applied and a notification explains; more than 3 such holds in 120 s disarms |
| Kernel flag cannot be cleared on disarm | the cup turns orange, a notification is posted, the clear is retried every 30 s |
| Crash or kill | the watchdog relaunches the app (at most 3 times in 10 min); the launch clears the flag, restores brightness and releases the sleep lock |
| Quit | the flag is cleared (three attempts) while the sleep lock still holds, then the lock and the assertions are released; the order is what keeps a closed lid on an external display from being slept and the session from being locked by the quit |

There is no maximum arm duration. The rails end the manual mode and the auto level together.

## The lid effect

Available with a lid-angle sensor, the Screen Recording grant and the effect switched on (Settings › Lid
Effect). It plays only while the
lid closes, only on the built-in display, and captures nothing while the lid rests.

- **Start.** While armed with the lid open, the effect is prepared (invisible overlay, paused renderer). A fold
  begins when the lid has closed "Arm after closing by" degrees past its rest angle; for arms that did not come
  from the gesture it also waits until the lid is below "Otherwise, start below" (default 75°), so
  adjusting the screen while working starts nothing. A still image appears at once, then a 60 fps capture.
- **Shape.** The desktop behaves like an inner screen standing upright at "With the lid gesture, start below"
  (default 95°): the fold shown is that angle minus the lid angle, capped at 80°. A fold that begins lower
  catches up with that curve over at most 30° of travel. Reopening plays it backward.
- **Reset.** A lid left part-way closed and still (less than 1.5° of movement) for "Flatten again when still
  for" (default 0.5 s) eases back to flat over 0.6 s; its position becomes the new rest angle, and the capture
  stops 0.75 s later. The reset is evaluated on every lid-angle sample (30 Hz), in every mode. While the
  gesture modifier is physically held, stillness does not count: the fold stays until the key is released.
- **End.** The lid shutting, a disarm or switching the effect off stops it at once. An external display
  connecting and a cancelled one-close arm retract the plane over 0.3 s (at once if no fold is showing).
- Settings › Lid Effect › Preview › "Simulate a Fold" previews a 35° fold over 2 s, armed or not
  (`EffectController.previewFoldDegrees`, `previewFoldSeconds`).

## User interface

- **Menu-bar cup.** Three glyphs: empty (Off), closed eyes (Armed), round eyes (Armed + screen on). Auto-armed
  is the closed-eyes cup wearing, hung off its bottom-right corner and clear of the eyes, without widening the
  item or moving the cup, the icon of each app at work:
  the Claude desktop app for Claude Code, the OpenAI desktop app for Codex, GitHub Copilot.app for Copilot,
  OpenCode.app for OpenCode, and for a command the terminal app hosting its shell (Terminal, iTerm, an editor's
  terminal…; Terminal's icon when no app hosts it, as over ssh). Several stack up and to the right, front to
  back Claude Code, Codex, Copilot, OpenCode, then the terminals, three at most. The icons are the installed apps' own, nothing is bundled: an app that is not installed gives no
  badge. An app that stops while another still works loses its badge at once; once nothing runs, the apps
  that last ran stay through the hold-off, so the cup still says why the Mac is armed, and go when the level
  drops. A manual mode always wins over the auto cup. Orange = the
  kernel flag could not be cleared. Optional lid angle next to it. "Show in menu bar" off hides the cup and
  nothing else: every arming path that does not go through it (the gesture, the two shortcuts, auto-arm, the
  CLI, URLs, App Intents) and every armed behaviour work exactly as before; right-clicking to arm and the lid
  angle simply have no icon left to use.
- **Menu.** Header with the mode; a greyed line while the auto level holds, built from the kinds at work
  rather than one string per combination: "Auto-armed while %@ works/work" (one/several agents), "…
  runs/run" when a command is among them, the names in `ActivityKind`'s order (Claude Code, Codex, Copilot,
  OpenCode, a command) joined ", " and a final " and "/" et " — "Auto-armed while Claude Code works", "Auto-armed
  while Claude Code, Copilot and a command run" — or "Auto-armed, off in N min" while nothing runs but the
  hold-off has not ended; in French, "que" before a name starting with a vowel elides to "qu'" ("tant
  qu'OpenCode travaille", "tant qu'une commande tourne"). Followed by the same app icons the cup wears; the
  three modes, each followed by its cup in grey; "Disarm once finished" (present while any of the five hooks
  is set up and, for Copilot, not disabled in `~/.copilot/settings.json` or `~/.copilot/config.json`);
  Settings…; Quit.
- **Opening the app.** KoffeeLid has no Dock icon. Opening it again from Finder, Spotlight, the Applications
  folder or `open -b dev.rubens.koffeelid` while it runs opens Settings — the way back in when the menu-bar
  cup is hidden, alongside `koffeelid settings`. A launch that starts the app (at login, from the watchdog,
  from the CLI) opens nothing, and neither does an open request that arrives while an install's outcome is
  still unread: that one is the update helper's, not a person's (§ Updates).
- **Settings.** One window with eight pages, picked from a toolbar that draws each page's symbol above its
  title; the window's title is the shown page's. It is 640 pt wide and as tall as the shown page: it resizes
  around its top-left corner, animated, on a page switch and whenever a page gains or loses a line, never past
  the display's visible height less 140 pt (beyond that the page scrolls). It opens on General, sized then
  centred, and is built once and re-shown. Every change is written as it is made; there is no Apply.

  | Page | Groups |
  |---|---|
  | General | the app icon; Startup (launch at login, show in menu bar, and a note naming the way back to this window once the icon is hidden); Updates; Quit ("Quit KoffeeLid" is the menu's Quit: disarms, clears the kernel flag, releases the sleep lock, then exits); Uninstall (see below) |
  | Arming | Lid gesture (the switch, the key to hold, the two travels); Menu bar and shortcuts (right-click, the two shortcuts); Low battery (the switch and its level) |
  | Auto-Arm | While you work (the switch, what counts as running right now); Claude Code, Codex, Copilot (a warning while `disableAllHooks` turns its hooks off), OpenCode and Terminal (each hook's state, the button that sets it up or removes it, its waits) |
  | Lid Effect | Effect (the switch, and the Screen Recording grant while it is on); Lid angle (the live angle, the angle in the menu bar); When it starts; Look; Preview (reset to defaults, simulate a fold) |
  | Sound | Lid-close sound (the switch, the charger and display switches of the closed-lid reminders, and the clip as a pop-up menu: picking one plays it); Volume (the forced volume and its level) |
  | System | Staying awake safely (sleep lock, Background App Activity, each with its button while missing); Permissions (Screen Recording, Input Monitoring, Notifications, each with its Allow button and a warning naming its switch in System Settings while denied); Diagnostics (the log's switch, open the log); Start over (show the onboarding again, reset everything). Only states with a control beside them: a bare verdict is on Health |
  | Health | whether KoffeeLid works, at a glance: a table of checks and a table of readings (below) |
  | Tip | a card with no title: the app icon beside the sentence saying every feature is free and stays free, and that a coffee is how the project is supported; One-time tip (the Ko-fi cup on its own red wash, "A cup of coffee" and what it is, and a button naming the smallest tip the page takes, `SupportLink.smallestTip`, 5 €). The button opens https://ko-fi.com/bambidotexe in the browser; the app sets nothing and reads nothing back, and nothing is paid inside it |

  A group is a title, a card of rows, and under the card a grey hint, then orange warnings, present only while
  something is to be fixed, then blue notes. A row is a control and its label and nothing else, and nothing
  explanatory goes inside a card. **The Tip page is the one exception, and the owner asked for it**: its first
  card has no title and holds a picture and a sentence, and its second holds a picture, two sentences and a
  button. A control that
  depends on a switch that is off is disabled and its label dims with it: the gesture's key and travels under the
  gesture switch, the battery level under its switch, the five auto-arm waits under the auto-arm switch, the
  effect's start and look under the effect switch, the clip and the volume while none of the three sound switches is on. The gesture
  and effect switches are disabled on a Mac without a lid-angle sensor; right-click arming and the angle in the
  menu bar are disabled while the menu-bar cup is hidden. A number is a slider with its value beside it.
- **States in Settings.** A state is one row: what is reported on the left, and on the right a symbol and a word
  in the state's colour. Green (a check): as it should be. Blue (an i): a reading, nothing to judge. Orange (a
  triangle): not as it should be, and KoffeeLid still keeps a closed Mac awake.
  Red (a stop sign): not as it should be, and because of it KoffeeLid cannot keep a closed Mac awake, or cannot
  do it safely. A spinner: still happening. The colour follows whether the state is what it should be, and is
  the same on every page (`SettingsStatus`, `HealthRules`): **a grant that is missing is red when the onboarding
  marks it required and orange otherwise, never blue.** The sleep lock (Available / Missing) and Background App
  Activity (Enabled / Disabled) are required, so red while missing; Screen Recording, Input Monitoring and
  Notifications (Granted / Denied) are optional, so orange while missing, whatever the switches. Each of the
  five hooks (Enabled / Disabled) is optional too, but unlike a permission it is on Health only once something
  of it is set up (below): the user may never run the agent it is for, and orange for a setup nobody has made
  is misleading, not a thing to fix. Auto-arm switched on with no hook set up also puts a warning under its switch. A
  state the user can fix has a button under it only while it is wrong; once it is right the button goes and the
  row stays. A state with nothing to press beside it is on the Health page alone, unless it is the context of what
  its page holds (a grant above its button, the lid angle beside the angle sliders, the work running now beside
  the auto-arm switch). While the window is open it re-reads the grants, the hooks and the login item every 2 s
  and the lid angle and the activity counts four times a second, and it is a consumer of the lid-angle sensor.
- **The Health page.** One question, at a glance: does KoffeeLid work, and if not, what is wrong. Two tables and
  nothing else. It reports and changes nothing but itself.
  - **Health** (Santé): the checks, each green, orange or red and never blue, then **Check Again** (a spinner
    beside it while a check runs, at least half a second). Every orange or red line puts a sentence under the
    table saying where it is put right. A check is something that has to be in place or running for KoffeeLid to
    work; a preference never is, and neither are the battery, the heat, the displays, the version or the memory.
    Always there, in this order: **Sleep lock** (Available green; Missing red; Failed red when it did not engage
    for an arm; Failed orange when it could not be released), **Crash recovery** (Background App Activity and the
    watchdog it runs, one line: Running green; Disabled red while Background App Activity is off; Stopped orange
    while it is on and the watchdog is not running), **Screen Recording permission**, **Input Monitoring
    permission** (also Failed orange while the lid gesture uses 🌐 Fn and this Mac's own keyboard cannot be read),
    **Notifications permission** (Granted green, Denied orange), and **Lid angle sensor** (Available green,
    Missing orange).

    Each of the five hooks is a line only once something of KoffeeLid's is set up for it; the user may not run
    every agent, and a setup nobody has made is not a thing to fix, so it is neither a line nor a warning under
    the table. In page order, between Notifications and the lid sensor: **Claude Code hooks** (a line while an
    event of `~/.claude/settings.json` carries KoffeeLid's marker, whatever bundle wrote it, or the file could
    not be read; Enabled green while every one of the 15 events points at this copy, Disabled orange otherwise;
    the tooltip says how many do, or that the file could not be read), **Codex hooks** (the same test against
    `~/.codex/hooks.json`, whatever `config.toml` currently trusts; Enabled green while every one of the 12
    events points at this copy and is trusted, Disabled orange otherwise; the tooltip counts the trusted ones,
    or says either file could not be read), **Copilot hooks** (a line while `~/.copilot/hooks/koffeelid.json`
    exists, ours or not, readable or not; Enabled green while every one of its 7 events points at this copy and
    `disableAllHooks` is not set, Disabled orange otherwise; the tooltip says how many events point here, or
    that they are turned off by `disableAllHooks`, or that the file could not be read), **OpenCode plugin** (a
    line while `~/.config/opencode/plugins/koffeelid.js` exists; Enabled green while it is exactly what this
    bundle would write today, Disabled orange otherwise; the tooltip says when the plugin is ours but belongs
    to another copy of KoffeeLid), **Terminal hook (zsh)** (a line, always green, only once `~/.zshrc` sources
    the snippet: unlike the four files above, sourcing it is all it takes, so there is no broken state of its
    own to show orange).

    Only while wrong: **Lid sleep**, second (Enabled red while armed, Disabled orange while a clear is being
    retried), and **Crashes in the last 7 days**, last (the count, orange, the last one's date in the tooltip,
    from `~/Library/Logs/DiagnosticReports`). At most thirteen lines, with every hook set up and broken and
    everything else wrong at once.
  - **Information** (Informations): at most eight readings, blue. **State** (Off, Armed, Armed + screen on,
    Auto-armed, Armed for one close; the tooltip is the command line's status line); **Lid angle now** (with the
    sensor); **Last Claude Code event**, **Last Codex event**, **Last Copilot event** and **Last OpenCode
    event** (each while its hook is set up: how long ago, or "None yet"; the tooltip names the event and its
    time); **Last terminal command** (the same); **Last turned itself off** (the safety rail and how long ago,
    once one has ended an arm since launch).

  Its own readings (whether the watchdog runs, the Claude Code settings file and whether anything of ours is in
  it, Codex's hooks file and its trust in `config.toml` and whether anything of ours is in it regardless, how
  many of Copilot's hooks point here and whether `disableAllHooks` is set and whether the file exists, whether
  the OpenCode plugin is current or stale and whether it exists, crash reports) are taken off the main thread
  when the page is shown and on Check Again, never on a timer; the grants and the lid come from the window's
  poll, and KoffeeLid's own state from the coordinator as the page draws. The version and updates are not
  health: they stay on General.
- **Onboarding.** Four pages in an ordinary window: pitch, Permissions, "Arm while you work" (the five hooks), All set.
  Shown at first launch and from Settings › System › "Show Onboarding Again". It opens in front because it is
  the last window to open, and from then on it behaves like any other window: a permission dialog, the
  administrator dialog and System Settings all open over it and stay there until the user leaves them, and the
  wizard keeps its place underneath. It gets the front back at the two moments an ordinary app's window would,
  and at no other: when a dialog of KoffeeLid's own is answered, which today is the administrator-password
  dialog behind the sleep lock, and when the user closes the System Settings window a grant button sent them
  to. macOS does the second by itself for an ordinary app and leaves a menu-bar app out of it, which is why
  the app has to. It belongs to the Space it opened in and keeps
  its place in it across a Space switch. It comes forward again when the app is activated and it is the app's only
  window, and opening KoffeeLid again (Finder, Spotlight, `open -b`) brings it back rather than Settings. The
  two list pages re-read the grants and the hooks every 2 s while the window is up, so a grant made in System
  Settings ticks the row over to "Granted" on its own. Only that row changes, never the page: while a grant is
  being set up its row keeps the button that started it, disabled, with a spinner beside it, and the page is
  built again only when the user moves to another page.
  Closing the window gives the frontmost app back to whoever had it, unless another KoffeeLid window is up.
- **Notifications.** Arm refused; disarmed by battery, thermal or external sleep; held awake after a charger
  or display change; lock failed; lid sleep restoration pending or failed; sleep could not be re-enabled; a
  newer release found by an automatic check, the only one with a button (§ Updates).
- **CLI.** `koffeelid arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings |
  install-hooks [claude|codex|copilot|opencode] | uninstall-hooks [claude|codex|copilot|opencode] | shell-init
  zsh`. The hook verbs take the agent as an optional word, Claude Code when none is given. The arming verbs
  launch the app if needed and print the status line. `status` with the app not running prints `mode: off
  (KoffeeLid is not running)`. Exit codes: 0, 1 (`did not …`, no answer), 2 (usage). The status line reads,
  for example,
  `mode: armed + screen on · auto-armed (activity) · lid: open · sleep lock: on · activity: 1 session working (Claude Code 1, Codex 0, Copilot 0, OpenCode 0), 0 commands`.
- **App Intents.** Arm, Arm + screen on, Turn Off, Toggle, Toggle screen on, Status.

## Settings and defaults

| Page › group | Control | Key | Default | Range |
|---|---|---|---|---|
| General › Startup | Launch at login | `launchAtLogin` (mirror of `SMAppService.mainApp`) | on | |
| General › Startup | Show in menu bar | `showInMenuBar` | on | |
| Arming › Lid gesture | Hold 🌐 Fn and close the lid to arm for one close | `armWithOption` | on | |
| Arming › Lid gesture | Key to hold | `gestureModifier` | `fn` | `fn`, `option` |
| Arming › Lid gesture | Arm after closing by / Cancel when reopened by | `gestureActivationDegrees` / `gestureReverseCancelDegrees` | 4° / 4° | 2–20° / 2–15° |
| Arming › Menu bar and shortcuts | Right-click the menu bar icon to arm | `armWithRightClick` | on | |
| Arming › Menu bar and shortcuts | Press ⌃⌥⌘L to arm, or to turn off / Press ⌃⌥⌘K to arm with the screen on, or to turn off | `armWithShortcut` / `armWithCaffeinateShortcut` | on / on | combos fixed: `hotKeyCode`, `hotKeyModifiers`, `caffeinateHotKeyCode`, `caffeinateHotKeyModifiers` have no UI |
| Arming › Low battery | Turn off when the battery runs low, Battery level | `lowBatteryDisarm`, `lowBatteryDisarmPercent` | on, 10 % | 5–50 % |
| Auto-Arm › While you work | Arm while Claude Code, Codex, Copilot, OpenCode or a terminal command is running | `armOnActivity` | off | |
| Auto-Arm › Claude Code / Codex / Copilot / OpenCode / Terminal | Stay armed after Claude Code finishes / Stay armed after Codex finishes / Stay armed after Copilot finishes / Stay armed after OpenCode finishes / Stay armed after a command finishes | `activityHoldOff.claude` / `activityHoldOff.codex` / `activityHoldOff.copilot` / `activityHoldOff.opencode` / `activityHoldOff.terminal` | 30 min / 30 min / 30 min / 30 min / 60 s | 1–120 min / 1–120 min / 1–120 min / 1–120 min / 10–600 s |
| Auto-Arm › Terminal | Ignore commands shorter than | `activityJobArmAfterSeconds` | 5 s | 0–30 s |
| Lid Effect | Show the desktop folding away as the lid closes, every slider of When it starts and Look, Show the lid angle in the menu bar | `effectParameters` (JSON) | enabled; start below 95° with the gesture / 75° otherwise; flatten again 0.5 s; zoom 80 %; perspective 40 %; blur 0.15×; soft edges 100 %; shading 100 %; responsiveness 70 %; angle in menu bar off | 30–120° / 30–90° (the second never above the first); 0.25–10 s; 0–200 %; 0–2×; 0–100 % |
| Sound › Lid-close sound | Play a sound when the lid closes, Sound | `lidCloseSoundEnabled`, `lidCloseSoundName` | on, `blip-pop` | six clips; an unknown name falls back to the first |
| Sound › Lid-close sound | Play it when the charger is unplugged / Play it when the displays change | `chargerUnplugSoundEnabled` / `displayChangeSoundEnabled` | on / on | armed, lid closed only |
| Sound › Volume | Play it at a set volume, Volume | `forceVolumeEnabled`, `forceVolumeLevel` | on, 60 % | 0–100 % |
| System › Diagnostics | Keep a diagnostics log | `diagnosticsEnabled` | on | |
| (internal) | | `gestureAngleOpen`, `onboardingCompleted` | 120°, false | |

## Permissions and what breaks without them

| Grant | Needed for | Without it |
|---|---|---|
| Sleep lock (administrator password once, a sudoers rule for `pmset disablesleep`) | a closed armed Mac surviving a charger or display change | every arm logs `sleep lock unavailable`; only the dark-wake hold protects the session |
| Background App Activity (KoffeeLid on under that heading in System Settings › General › Login Items) | the crash-recovery watchdog and launch at login | no relaunch after a crash; a crashed armed app leaves the flag set until the next launch |
| Screen Recording | the lid effect | `effect: screen recording not granted; effect stays off`; arming works |
| Input Monitoring | reading the built-in keyboard's Fn key, so only it arms the lid gesture | `built-in Fn reader: Input Monitoring not granted`; any keyboard's Fn/Globe key counts |
| Notifications | every message above | silent failures; the log still has them |
| Lid-angle sensor (hardware) | the gesture and the effect | both unavailable; other arming paths work |

**Every grant is named as System Settings names it**, because the user has to find it in a list there: Background
App Activity, Screen Recording, Input Monitoring, Notifications. The names are quoted from the
system's own tables (`macOS.md` § Permissions), never invented and never a remembered older name. The sleep
lock is the one row with a name of its own, having no system switch behind it.

**No permission prompt ever appears unless the user clicked for it.** Nothing asks at launch, when a window
opens, or when a feature that needs a grant is switched on: the onboarding's rows and Settings > System are
the only two places that ask, each with the reason beside it. A state is read with the preflight or check
call, never with the one that requests, because the windows re-read every 2 s while they are open.

**A grant button asks macOS, and does nothing else.** Screen Recording, Input Monitoring and Notifications each
show the system's own dialog, which carries its own button to the right pane of System Settings; the app never
opens a pane beside that dialog, and never instead of it once the grant has been refused. Login Items is the
one exception, and the button says so ("Open Login Items"): macOS offers no dialog for it, so the pane is that
grant's whole flow. The sleep lock's button shows the administrator-password dialog.

Settings › System › "Reset KoffeeLid…" asks for confirmation, then disarms, removes the sudoers rule, unregisters the
login items, resets Screen Recording, Input Monitoring and notifications, removes the Claude Code hooks, the Codex
hooks, Copilot's hooks file, OpenCode's plugin and the zsh block, clears the preferences and whatever an update left
in Application Support, and reopens onboarding.

## Uninstall

Settings › General › Uninstall takes KoffeeLid off the Mac. The group always shows a warning, because what it warns
about is not a state that can be put right but the hazard of the other way out: **dragging the bundle to the Trash is
not an uninstall.** It removes the app and nothing else, and what is left goes on running against an app that is gone,
the Claude Code and Codex hooks, Copilot's hooks file and OpenCode's plugin each calling a binary that is not there
once per event for ever.

"Uninstall KoffeeLid" asks for confirmation, then, in this order:

1. disarms, so the kernel lid-sleep flag is clear, the assertions are released and the brightness is back
   before anything else moves;
2. releases the sleep lock, while the sudoers rule that releases it still exists, and whether or not this
   instance is the one that engaged it: `pmset disablesleep 1` survives the process that set it and a
   reboot, so a lock left behind by a crashed instance goes here or not at all. A kernel flag that could
   not be cleared is reported, with the one thing that always puts it back, which is a restart;
3. resets the Screen Recording, Input Monitoring and notification grants, while the bundle they name is still where
   they name it (`tccutil reset` against a bundle identifier with no bundle behind it fails, and nothing puts that
   right afterwards);
4. unregisters the watchdog agent and launch at login, and registers neither back;
5. removes the Claude Code hooks, the Codex hooks with their trust, Copilot's hooks file, OpenCode's plugin, the
   zsh block and the backups the hooks left;
6. removes `/etc/sudoers.d/koffeelid` and `/usr/local/bin/koffeelid` in one administrator-password dialog, and only
   if one of them is there (`UninstallPlan`);
7. clears the preferences;
8. removes `~/Library/Application Support/KoffeeLid/`, once the diagnostics log has been silenced so that nothing
   writes the folder back;
9. moves the bundle to the Trash, not to a delete: what was just removed is still there to put back.

**Steps 7 and 8 are done twice, and the second time is the one that holds.** Removing either while the app is
still running is not enough: the way out through `shutdown()` recreates the activity journal, and so the
Application Support folder with it, and `cfprefsd` writes the preferences domain out again as the process
exits, leaving an empty plist where a Mac that never had KoffeeLid has no file at all. Both were seen on a
real uninstall. So a detached helper waits for the pid to go, for at most a minute, then deletes the domain,
removes the folder, and removes the preferences file, the ByHost preferences, the caches, the HTTP storage
and the saved window state, all of which are named after the bundle identifier and belong to nothing else.

It then says what it could not remove, if anything, and quits. Reset, in Settings › System, is the other thing:
it puts the app back to a first launch and keeps it installed.

## Updates

KoffeeLid looks for a newer release on GitHub on its own: once 10 s after launch, then a week after the last
check that got an answer, whoever asked (`UpdateSchedule`). The question is put on a 30-minute tick and at every
wake rather than on one week-long timer, so a Mac asleep on the date is asked as soon as it is awake. A check
that could not reach GitHub is silent and tried again at the first tick an hour or more later, so 60 to 90
minutes on. Nothing is fetched or installed without a click.

An automatic check that finds a strictly newer release shows it in Settings and posts one notification,
"Version `<version>` is available", with an **Update** button; a later check's notification replaces it. The
button, and a click on the notification itself, do what Update does in Settings. A notification left by an
earlier run asks GitHub first, then opens the update window on the answer, or Settings when nothing is newer.

Settings › General › Updates is two rows: the running version ("KoffeeLid `<version>`"), which carries the
last answer as its mark, and one button (`UpdatePanel`).

| The moment | The version row's mark | The button |
|---|---|---|
| before the first answer | none | Check for Updates |
| asking GitHub's anonymous API because the button was pressed | a spinner, "Checking" | disabled |
| nothing newer, whoever asked | green, "Up to date" | Check for Updates |
| a strictly newer release, whoever asked | blue, "Version `<version>` is available" | **Update**, prominent and blue |
| a press could not ask | orange, "Could not check: `<reason>`" | Check for Updates |
| the last Install and Relaunch did not end with the new version running | orange, "Update failed: `<reason>`" | Check for Updates, and Update again once a check has found the release |

An automatic check shows no spinner and its failure changes nothing here. A press while an automatic check is
in flight adopts that check's answer instead of starting a second request.

**The update window.** Update opens one small window titled "Software Update" and starts fetching at once: the
app icon, "KoffeeLid `<version>`", one status line, a bar, Cancel and **Install and Relaunch**, which stays
disabled until the update is ready. Pressing Update again, anywhere, shows that same window (`UpdateSession`).

| Phase | The status line | The bar | The buttons |
|---|---|---|---|
| fetching | "Downloading: `<received>` of `<total>`"; "Downloading" when no total is known | follows the bytes | Cancel · Install and Relaunch, disabled |
| making it ready | "Preparing the update" | indeterminate | the same |
| ready | "Ready to install. KoffeeLid will quit and reopen." | full | Cancel · **Install and Relaunch** |
| it cannot replace itself | "KoffeeLid cannot replace itself where it is installed. Open the disk image and drag KoffeeLid to Applications, then quit and reopen it." | none | Cancel · **Open Disk Image** |
| installing | "Installing" | indeterminate | both disabled; the window does not close |
| failed | "Update failed: `<reason>`" | none | Close · **Try Again**, which fetches again |

Everything that can refuse an update happens while making it ready, with the app still running: the fetched
file is held against the length and the SHA-256 GitHub states for the asset; the disk image is mounted
read-only and hidden; the app in it that carries KoffeeLid's bundle identifier is copied to
`<Application Support>/KoffeeLid/updates/staged/`; that copy must be strictly newer than the running version,
ask for no newer macOS than this one, and carry a valid signature from the same team as the running app (a
running app with no team, an ad-hoc build, only asks for a valid signature). KoffeeLid cannot replace itself
when it does not run from an `.app`, runs translocated, cannot write to its folder or its bundle, or sits on
another volume than its Application Support folder; the window then offers the disk image, which macOS mounts
and shows with its Applications link. Cancel and the window's close button stop the fetch and delete what was
fetched.

**Install and Relaunch.** It is refused, with an orange line in the window, while KoffeeLid is armed with the
lid closed and no external display: "Open the lid first. With the lid closed, the Mac goes to sleep when
KoffeeLid quits." Otherwise KoffeeLid starts a helper (`UpdateInstallScript`, a shell script in a process group
of its own) and quits the way the menu's Quit does: it disarms, clears the kernel flag and releases the sleep
lock. The helper touches nothing until the app is gone. If the app is still there 20 s after the click, it
stops the helper, so that a quit that comes later is only ever a quit, and the window says "KoffeeLid did not
quit. Close its open dialogs, then try again." with the update still ready; the helper's own limit, 30 s, only
serves an app too hung to do that. Once the app is gone the helper moves the installed bundle to
`updates/previous/`, moves the new one into its place (a failed move puts the previous one back), writes the
outcome, opens the app, and looks for the new executable among the running processes for 15 s, by the path it
was installed at or by the one the system knows that folder by. Seen, it looks once more 2 s later: still
there, or gone after having read the outcome (the user quit it, which is their business), the previous copy is
deleted. Gone without that mark it is looked for again, for as long as the first look lasted, because an app
that hands itself to launchd quits so that the job's own copy can take its place and nothing runs in between.
Never seen, not openable, or still gone at the end of that second look (it crashed on its way up), the new
copy is moved out, the previous one moved back and opened. Nothing is ever deleted to make room: when the
previous copy cannot be moved back it stays in `updates/previous/`, and the outcome says so.

The next launch reads the outcome, leaves `result.read` in its place for the helper, and says how it ended in
the update window, which is the whole news: after an install, "KoffeeLid 1.0.0" and "The update is installed.
KoffeeLid is running the new version." with one button, Done; after a failure, the version that is still
running and "Version 1.0.0 was not installed." followed by the reason, with one button, Close, and the Updates
group of Settings carries the same reason as its orange mark. **Nothing else opens**: Settings is not shown
behind it, and the launch is otherwise the launch it would have been. The three reasons are "The new version
could not be put in place.", "The new version did not start, so the previous one was put back." and "The new
version did not start and the previous one could not be put back. Download KoffeeLid again." An outcome older
than 10 min was left behind by an install nobody is waiting on any more: it is logged and opens nothing. Quitting
disarms, as every quit does, so the quit leaves a note of the manual mode that was on (`UpdateResume`; never a
one-close gesture arm) and the new version goes back to that mode as it starts, through the same entry point
and the same rails as an arm from the menu. The note is read once and removed; one older than 2 min (the Mac
slept in between, the helper was held up) arms nothing. The auto level needs no note: it arms again by its own
rule if work is running.

## What KoffeeLid does not do

- It does not arm twice: a second instance exits at launch without touching shared state.
- It does not clear a kernel flag it has no evidence of having set (another lid-sleep utility may own it).
- It never signals its own processes by name; it only uses pids from its own pid file. The only processes it
  signals by name are `usernoted` and `NotificationCenter`, restarted by the Settings reset to drop the
  notification grant.
- The hook binary never launches the app, never blocks an agent's turn and always exits 0 from the `hook`
  verb (only a malformed `job` command line, which the snippet never produces, exits 2).
- It does not record prompts, tool input or output: the activity journal holds event names and identifiers only.
- It does not fetch or install an update by itself: an automatic check only announces a release.

## Unconfirmed — ask the owner

- Whether macOS's purple screen-recording indicator is hidden by the effect's overlay.
- Whether the Input Monitoring grant takes effect without relaunching the app (the reader retries when the app
  becomes active; `built-in Fn reader: open FAILED` in the log means it did not).
- The dark-wake hold and the one-close hold have been exercised through logs on this Mac; the manual
  checklist (`docs/manual-test-checklist.md`) is the record of what has been verified on hardware.
