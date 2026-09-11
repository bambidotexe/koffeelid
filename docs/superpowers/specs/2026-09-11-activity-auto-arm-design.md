# Auto-arm on activity — design

Date: 2026-09-11. Status: approved in discussion, awaiting owner review of this document.

KoffeeLid arms itself while a Claude Code session or a terminal command is running, and disarms itself
when nothing runs any more, so closing the lid mid-task keeps the Mac awake and the Mac goes back to
sleeping normally once the task is over. The detection is KoffeeLid's own: it installs its own Claude
Code hooks and its own zsh hooks, and depends on nothing else running on the Mac.

The truth-keeping rules are ported from MySidepulse (`~/Projects/my-sidepulse`, v1.5.2), which spent
five versions learning how Claude Code's hooks fail. Every constant below that came from there keeps its
value and the evidence that sized it; do not retune from taste.

## 1. Owner rulings (functional, fixed)

1. **Independent.** KoffeeLid does not read SidePulse's socket, journal or hooks. Both tools may be
   installed side by side; both sets of hooks fire on every Claude turn.
2. **Own your arm.** Activity may arm only from Off, and may disarm only an arm it made itself. A mode
   the user chose by any other means is never touched. A manual change while auto-armed hands the arm
   to the user.
3. **Waiting is not running.** A session blocked on a question, a permission or a plan approval is not
   running. Nothing timer-driven and nothing inferred from prose can turn "waiting" into "running".
4. **Never disarm under another session.** The disarm decision is taken on the aggregate over every
   session and every job, not on the session that just finished.
5. **A finish can be a pause.** A turn that looks over can resume a second later; the same debounces
   SidePulse uses for its "working" verdict apply, plus a KoffeeLid hold-off before the disarm.
6. **When activity ends with the lid closed, the Mac may sleep.** That is the feature working.
7. `koffeelid run -- cmd` is out of scope. The zsh hooks cover the terminal case.

## 2. Vocabulary

- **Session**: one Claude Code `session_id`. Has a state (§4), a Claude pid, a set of live helper
  agents and a snapshot of background shell ids.
- **Job**: one terminal command reported by the zsh hooks, keyed by `zsh-<shell pid>`.
- **Running**: `any session is working` **or** `any job is running and past its arm-after`.
- **Held**: a session whose Stop arrived while helpers or background shells were still out; it stays
  working until they clear.
- **Auto-armed**: `mode != .off && armSource == .activity`.

## 3. Architecture

Dependency direction unchanged: Core ← Hook tool, Core ← App.

```
KoffeeLidCore (Foundation only, tested)
  ActivityEvent          one trimmed journal line (Codable, snake_case keys)
  ActivityTrim           hook payload → ActivityEvent; caps and clamps; capped line encoder
  ActivitySessionStore   per-session state machine + tick(now:) + nextDeadline
  ActivityJobStore       per-shell job slots + tick(now:)
  ActivityArmPolicy      aggregate edges → arm / disarm decisions with ownership and hold-off
  ActivityConstants      every timing, with its evidence
  HookConfig             pure transform of the `hooks` object of ~/.claude/settings.json
  ShellInit              the zsh preexec/precmd snippet (template + substitution)
  ProcWalk               sysctl ancestor chain, Claude-process identification, CLAUDE_CONFIG_DIR read

KoffeeLidHook (Hook/Sources/main.swift, Xcode tool target, Core only, embedded in the bundle)
  verbs: hook | job begin | job end       — never launches the app, always exits 0 (hook)

KoffeeLid app (App/Sources)
  ActivityMonitor        owns the stores; tails the journal; kqueue on Claude/shell pids; registry
                         checks; wall-clock tick scheduling; one closure: onRunningChanged(Bool, summary)
  ActivityJournalTailer  vnode DispatchSource on activity.jsonl, follows rotation
  ActivityProcessWatcher kqueue EVFILT_PROC → onExit(pid)
  ClaudeProcessRegistry  reads <config>/sessions/<pid>.json (status busy/idle, sessionId, stamp)
  KoffeeLidController    ArmSource.activity; consumes onRunningChanged through ActivityArmPolicy
  CommandLineClient      new verbs: install-hooks | uninstall-hooks | shell-init zsh (run in-process,
                         no app launch); `status` gains an activity summary
  UI                     Settings switch + install controls; Advanced sliders + live activity line
```

Why a separate hook binary: the app binary links AppKit, Metal and ScreenCaptureKit, costing on the
order of 100 ms of dyld work per launch; the hook runs on every Claude event and every shell command.
The existing CLI path also launches the app when it is not running, which a hook must never do. The
watchdog is the precedent for a Core-only tool embedded in `Contents/MacOS/`.

Why a journal file and not a socket: the app may be down or mid-relaunch (watchdog) while hooks fire.
Replaying the journal at launch rebuilds "running" and re-arms, which is precisely the moment that
matters after a crash. Jobs ride the same journal (SidePulse keeps them on its socket) so there is one
writer and one tailer.

## 4. Session state machine (`ActivitySessionStore`)

States: `idle`, `working`, `waiting`, `done`. Only `working` counts as running. The store is pure:
driven by event timestamps and explicit `tick(now:)`, so journal replay and live events share one path.

Per session: `state`, `stateSince`, `lastEventAt`, `lastMainEventAt` (main agent only: not helpers,
not `Notification`), `claudePid`, `liveAgents: [agentId: lastSeen]`, `backgroundIds: Set<String>`,
`pendingDone`, `holdReleasedAt`, `waitingFromAgent`.

| Incoming | Effect |
|---|---|
| `SessionStart`, source ≠ compact | helpers and background set cleared (process boundary); `idle` |
| `SessionStart(compact)`, `PreCompact`, `PostCompact` | `working` |
| `UserPromptSubmit` | `working`; helpers **kept** (Claude Code 2.1 accepts a prompt over a running helper) |
| `PreToolUse(AskUserQuestion)` / `PreToolUse(ExitPlanMode)` | `waiting` |
| `PreToolUse(other)`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | `working` |
| `PermissionRequest` (any tool) | `waiting` |
| `Notification(permission_prompt \| elicitation_dialog \| elicitation_url_dialog)` | `waiting` unless already waiting |
| `Notification(idle_prompt \| agent_needs_input)` | rescue only: if `working`, not held, and main agent quiet ≥ 50 s → apply the Stop verdict; otherwise ignored |
| `Notification(other)` | ignored |
| `StopFailure` | `waiting` (the turn died; not running) |
| `Stop` | Stop verdict: `done` if no live helper and no background id; else `pendingDone` + `working` (held) |
| `SessionEnd` | session removed |
| Helper event (has `agent_id`): `SubagentStop` | helper removed |
| Helper event: `PermissionRequest` | helper stamped; `waiting`, `waitingFromAgent` |
| Helper event: anything else | helper stamped; if `waiting` from agent → `working`; if `done` → `pendingDone`, `working` |
| `background_task_ids` on a main-agent event | replaces the background set (only `type == "shell"` or untyped entries, first 16, 40 chars each) |
| Claude pid exits (kqueue) | every session with that pid removed |

Time rules (`tick`): a held session releases when no helper reported for **240 s** and the background
set is empty, then `done` after a **90 s** grace, or unconditionally after **30 min** since the last
event; `done` becomes `idle` after 20 min (bookkeeping only, both are not running); a session with no
event for **2 h** is removed.

Quiet-turn rescue (Esc and Ctrl-C fire no hook, and a Ctrl-C can kill hook delivery for the session):
a `working`, not held session with a pid and no event for **20 s** is checked every **15 s** against
Claude Code's registry record `<config>/sessions/<pid>.json` (config dir from the process's
`CLAUDE_CONFIG_DIR`, else `~/.claude`; record ignored unless its `pid` and `sessionId` match).
`idle` stamped after `lastMainEventAt` → the turn is over → `done`. `busy` → liveness extended
(`lastEventAt` refreshed, `lastMainEventAt` not), so a session whose hooks died stays running as long
as Claude says so; log once per session after 5 min of hook silence. No record → log once, leave it
to staleness. SidePulse's transcript-tail read is not ported: it tells a finish from an interrupt,
and both are "not running" here.

Answered-dialog rescue: a `waiting` session whose registry goes `busy` stamped more than **2 s** after
the wait began was answered without a hook → `working`. Checked on the same 15 s cadence.

## 5. Jobs (`ActivityJobStore`)

Keyed by id; one slot per shell pid — a new `begin` in the same slot evicts the previous job. Fields:
`ownerPid`, `label`, `armAfter: Date?`, `stateSince`.

| Signal | Effect |
|---|---|
| `begin` | job running, invisible until `armAfter`: the `--arm-after` the hook passed when `KOFFEELID_ARM_AFTER` is set, else the app's `activityJobArmAfterSeconds` preference (default **5 s**) |
| `end` (any status) | job removed |
| owner pid exits | job removed |
| **2 h** still running | removed |

A job counts toward *running* only once `armAfter` has passed. Exit status is not recorded.

## 6. Arm policy (`ActivityArmPolicy`)

> **Superseded on 2026-09-12 (evening).** The edge/ownership model below could never re-arm on a Mac where
> something is always running (a Claude Code session plus a wrapper command kept the level high all day, so a
> manual Off stuck). The auto-arm is now an independent *level* ORed with the manual mode: see
> `docs/architecture.md` § Auto-arm on activity and `CLAUDE.md` invariant 11. The rest of this section is
> kept as history.

Pure value type; injected clock. Inputs: `update(running: Bool, now:)`, `modeChanged(to:, source:, now:)`,
`tick(now:)`. Output: `.arm`, `.disarm` or `nil`. State: `lastRunning`, `ownsArm`, `suppressed`,
`disarmAt: Date?`.

- **Rising edge** (not running → running): if `mode == .off`, not `suppressed`, and the preference is
  on → `.arm`. `disarmAt` is cleared on any rising edge, owned or not.
- **Falling edge** (running → not running): if `ownsArm` → `disarmAt = now + holdOff` (default **60 s**,
  Advanced slider 10–300 s). `tick` returns `.disarm` when `disarmAt` passes and `running` is still
  false.
- **Ownership**: the coordinator reports every mode change with its source. `source == .activity`
  and `mode != .off` → `ownsArm = true`. Any other source → `ownsArm = false`, `disarmAt = nil`.
  A manual `.off` while `running` → `suppressed = true` until the next rising edge.
- **Blocked arms** (low battery, thermal, disabled, flag failure) are reported back as
  `armFailed(now:)`: no ownership, and no retry until the next rising edge — the same edge discipline
  as the suppression, so a blocked arm does not hammer the notification centre once per tick.
- The wall clock is used throughout (`Date`), and the monitor re-evaluates everything on system wake.

Coordinator changes: `ArmSource.activity`; `setMode` records the source on the in-place Armed ↔
Caffeinate switch (today it does not); `arm(source: .activity)` targets `.armed`; `disarm(reason:
"activity ended")`. Every existing block and rail applies unchanged. `statusLine()` appends
`auto-armed (activity)` when owned and an `activity: …` summary always (e.g. `activity: 1 session
working, 1 command`), so hooks can be verified before the switch is turned on.

## 7. Hook binary (`KoffeeLidHook`)

`hook`: reads stdin in 64 KB chunks, keeps at most **8 MB**; drops `tool_input`, `tool_response`,
`prompt`, `compact_summary`, `last_assistant_message`; clamps every metadata string to **200** chars;
keeps at most the first **16** background task ids of `type == "shell"` or untyped, **40** chars each;
walks its ancestors via `sysctl` to record `claude_pid` (a process named `claude`, or whose
`proc_pidpath` / `KERN_PROCARGS2` exec path has a `claude` component); appends one JSON line with a
single `write(2)` on `O_APPEND`, hard-capped at **4 KB** with progressive shrink passes and a minimal
fallback line; **always exits 0**. `KOFFEELID_DISABLE=1` exits immediately without writing.
Unparseable input still writes `{"event":"ParseError"}` with a ≤ 300-char raw prefix.

`job begin --id ID --pid PID [--label TEXT] [--arm-after SECONDS]` and `job end --id ID` append
`JobBegin` / `JobEnd` lines to the same journal. Labels are trimmed to 60 chars.

Journal: `~/Library/Application Support/KoffeeLid/activity.jsonl`, rotated by the app to
`activity.1.jsonl` when it exceeds **5 MB with nothing running** or **20 MB** unconditionally, checked
per batch and at launch. At launch the app replays `activity.1.jsonl` then `activity.jsonl`, skipping
events older than the current boot, then drops sessions whose pid is dead or no longer looks like
Claude (recycled pid) and jobs whose owner shell is dead.

## 8. Installers and the zsh snippet

`koffeelid install-hooks`: resolves the hook binary's absolute path next to the running app binary
(`_NSGetExecutablePath`, symlinks resolved), backs `~/.claude/settings.json` up to
`settings.json.backup-koffeelid`, applies `HookConfig.install` (all **15** events: SessionStart,
SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest,
PermissionDenied, Notification, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact,
PostCompact; one `{"matcher":"*","hooks":[{"type":"command","command":…,"timeout":5}]}` group each),
scrubs older KoffeeLid entries first (marker `/Contents/MacOS/KoffeeLidHook hook`), never touches
another tool's entries, declines shapes it does not understand, and counts what actually landed:
"Installed N of 15", exit 1 when N < 15. `uninstall-hooks` removes exactly what it adds. Both run
in-process from the CLI without launching the app; the Settings button runs the same code inside the app.

`koffeelid shell-init zsh` prints the snippet for `eval "$(koffeelid shell-init zsh)"` in `.zshrc`:
`preexec` collects the head of every segment of the command line (split on `&& || | |& ; &` and
`( ) { }`, quotes stripped, basename taken); one head in `KOFFEELID_SKIP` skips the whole line
(default list: `vi vim nvim emacs nano pico less more man info ssh mosh tmux screen top htop btop
watch claude codex grok koffeelid`); otherwise `job begin --id zsh-$$ --pid $$ --label <first head>`,
with `--arm-after $KOFFEELID_ARM_AFTER` appended only when that variable is set. `precmd` sends `job end` and hands `$?` back to later hooks. The
snippet calls the hook binary **by absolute path**. It is tested by running it in a real zsh against a
stub binary, as SidePulse does; a string comparison with itself proves nothing.

## 9. Preferences, UI, strings

Preferences (UserDefaults, `Preferences.shared`): `armOnActivity: Bool` (default off),
`activityDisarmHoldOffSeconds: Double` (60), `activityJobArmAfterSeconds: Double` (5; applied by the app to
every `begin` that carries no explicit `--arm-after`, so changing the slider needs no shell restart). The coordinator reacts in `preferenceChanged`.

Settings page, "Arm with" group: switch **While Claude Code or a terminal command is running**; below
it a row showing hook status ("Claude Code hooks: installed (15 of 15)" / "not installed") with an
**Install hooks…** button, and a row with the zsh line and a **Copy** button. Advanced: group
**Auto-arm on activity** with `labelledSlider` "Disarm after nothing has run for" (10–300 s) and
"Ignore commands shorter than" (0–30 s), plus a live line "Activity: …" refreshed from the monitor.
Every string through `L()` with an `fr` entry.

The Debug build shares UserDefaults and the journal with the installed app. `KOFFEELID_DISABLE_ACTIVITY=1`
in the app's environment turns the monitor off for that process, so the runtime smoke never arms on the
session running it.

## 10. Diagnostics

Log lines (keep phrasing; manual checks grep for them): `activity: hooks journal tailing`,
`activity: replayed N events, S sessions, J jobs`, `activity: running (S sessions working, J commands)`,
`activity: idle`, `auto-armed (activity)`, `auto-disarm scheduled in 60s`, `disarmed (activity ended)`,
`activity: quiet turn <sid> — registry idle, turn over`, `activity: hooks look dead for <sid>`,
`activity: no registry record for pid <pid>`, `activity: journal rotated`.

## 11. Testing

Core unit tests (hermetic, injected time): every row of §4 and §5, the held-Stop release and TTL, the
idle_prompt 50 s gate, the 240 s helper silence, pid exit, replay pruning, `ActivityArmPolicy` edges,
ownership transfer, suppression, hold-off cancel on a rising edge, blocked-arm edge discipline,
`ActivityTrim` caps (8 MB, 4 KB line, 200/40/16), `HookConfig` install/uninstall/idempotence/declined
shapes, and the zsh snippet in a real `zsh -f` against a stub `KoffeeLidHook` that records its argv.

Manual checks (added to `docs/manual-checks.md`): install hooks, start a `sleep 120`, see the mug arm
after 5 s, close the lid, confirm the Mac stays awake, open, wait for the command to end, confirm
`disarmed (activity ended)` ≈ 60 s later; Ctrl-C a Claude turn and confirm disarm within ~35 s plus
hold-off; two sessions, finish one, confirm still armed; arm manually then finish activity, confirm no
disarm; `koffeelid off` while running, confirm no re-arm until the next command.

## 12. Files

New: `Hook/Sources/main.swift`; Core `Activity*.swift`, `HookConfig.swift`, `ShellInit.swift`,
`ProcWalk.swift` and their tests; App `ActivityMonitor.swift`, `ActivityJournalTailer.swift`,
`ActivityProcessWatcher.swift`, `ClaudeProcessRegistry.swift`. Changed: `project.yml` (tool target
`KoffeeLidHook`, embedded like the watchdog), `KoffeeLidController.swift`, `CommandServer.swift`,
`Preferences.swift`, `SettingsViewController.swift`, `AdvancedViewController.swift`,
`Localizable.xcstrings`, `docs/architecture.md`, `docs/development.md`, `docs/manual-checks.md`,
`CLAUDE.md`, `README.md`.

## 13. Out of scope

`koffeelid run`, notifications about activity, an activity-specific icon, bash/fish snippets, and any
reading of SidePulse state.
