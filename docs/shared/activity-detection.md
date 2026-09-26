# Activity detection — the contract koffeelid and my-sidepulse share

Two apps of the family watch the same work on this Mac, each for its own reason: **koffeelid** keeps the Mac
awake while it runs, **my-sidepulse** shows it on an LED strip and pushes to a phone. They share no code, and
they decide *whether an agent or a terminal command is working* by the same rules: the ones below. What each
app then does with a session that is not working (a hold-off, a colour, a push) is its own and is not here.

## The rule that keeps them in sync

- **A change to how either app detects work is a change to this document first**, made in the template and
  synced (`sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh`), **then made in both apps in the same
  session**, each with its test. A rule one app follows and the other does not is a bug in one of them.
- Where the two apps are found to differ, the better rule wins in both — the one with the measurement, the test
  or the recorded trap behind it — and this document says the winner.
- Each app's `CLAUDE.md` points here from its activity rows; each app's own documents say *where* in its code a
  rule lives (the table at the end), never a different rule.
- Constants in § 7 are equal in both apps. A constant retuned in one is retuned in both.

## 1. Sources

1. Claude Code's 15 hook events, Codex's 12, Copilot's 7 (`sessionStart`, `userPromptSubmitted`, `postToolUse`,
   `postToolUseFailure`, `notification`, `agentStop`, `sessionEnd` — never `preToolUse` or `permissionRequest`,
   whose failure denies the tool) and OpenCode's plugin (the 19 forwarded events, `session.tool.input.started`
   read for tool names) feed one append-only journal per app, one trimmed line per event.
2. A Codex hook is installed with no `matcher`, `timeout` 3 for `SessionEnd` and `Interrupt` and 5 otherwise,
   after every existing group, and its trust (`[hooks.state."<hooks file>:<event>:<group>:<handler>"]`,
   `trusted_hash` = Codex's hash of the normalised entry) is written into Codex's `config.toml`; removing the
   hooks removes the trust first. A Codex hook counts as set up only while installed **and** trusted.
3. The hook drains stdin to its end, keeps 8 MB at most, never blocks on anything but one `O_APPEND` write of at
   most 4096 bytes, never launches the app, and exits 0 for every hook form, unrecognised arguments included (a
   malformed `job` call alone prints its usage); the app's `*_DISABLE=1` silences it, its job lines included.
4. A journal line carries the agent (the hook's verb or flag says which; a bare hook is Claude Code's), the event
   under Claude Code's names (Copilot's and OpenCode's mapped onto them), `session_id`, `agent_id`, `tool_name`,
   `turn_id` (`turn_id`, else `prompt_id`), `notification_type`, `source`, the transcript path on `SessionStart`,
   `UserPromptSubmit`, `Stop` and `Interrupt` only (at most 1024 characters), the `background_tasks` ids of type
   `shell` or untyped (at most 16 × 40 characters), and the agent's pid. Identifiers are clamped at 200
   characters; a line still over 4096 bytes keeps only the session, turn and job ids. An event outside the
   agent's own list, or not spelled as the agent sends it (Claude Code's and Codex's PascalCase in the payload,
   Copilot's camelCase in the hook's argument), is a parse error, never an event: a payload cannot forge another
   agent's `Interrupt`.
5. The agent's pid is the nearest ancestor of the hook's parent that runs the agent named; OpenCode's
   `opencode_pid` is believed only when it is such an ancestor. A Copilot line whose session has no folder under
   `$COPILOT_HOME/session-state` (else `~/.copilot/session-state`) is a subagent's and is not written; the
   session's `events.jsonl` path is filled in on its start, prompt and stop. An OpenCode line with a parent
   session is a helper event of its top session; an event of no session is not written.

## 2. The session machine

6. States: `idle`, `working`, `waiting`, `done`. **Only `working` is work.**
7. `SessionStart` (not `source: compact`, not Copilot's, which fires after the first prompt) → `idle`, forgetting
   helpers and background shells. Copilot's start records the pid and the path and changes nothing.
8. `UserPromptSubmit` → `working`: it opens its turn whatever id it carries, ends the quarantine, forgets the
   compaction snapshot, and clears no helper.
9. `PreToolUse` of `AskUserQuestion`, `ExitPlanMode` or `request_user_input` → `waiting`; of any other tool →
   `working`. `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` → `working`. `PermissionRequest` and
   `StopFailure` → `waiting`. `Notification` `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`
   → `waiting`; `idle_prompt` / `agent_needs_input` is a lost `Stop` only on a `working` session with nothing
   held and the main agent quiet for 50 s, and otherwise changes nothing, like every other notification type.
10. `Stop` → `done` when no helper is live and no background shell is out, else held (`working`, finish
    pending); a `Stop` ends the turn without closing it.
11. `Interrupt` → `idle`: it forgets helpers and background shells and closes the turn by interrupt. (`idle`, not
    `done`: a helper line arriving after it must not reopen an interrupted turn.)
12. Compaction: `PreCompact` → `working`, remembering the state it found (the first since the last boundary),
    with when it began and whether a helper raised it; `PostCompact` restores all three (else `working`); a prompt, a `Stop`, an `Interrupt` or a non-compact
    start forgets the snapshot.
13. Helper events (`agent_id` set) mark the helper live and never speak for the main agent, except: a helper's
    `PermissionRequest` → `waiting`, raised by the helper; a helper acting again answers any wait a helper raised
    (a permission, a question, a plan) → `working`, and a repeated `permission_prompt` notification on that wait
    leaves it the helper's; a helper acting after `done` → `working` with the finish held. `SubagentStop` marks the helper gone; one for an unknown session creates
    nothing. Only the main agent's `background_tasks` replace the session's set.
14. A helper is live for 240 s after its last event. A held finish becomes `done` 90 s after the last helper or
    background shell cleared, or 30 min after the session's last event; a new helper re-engages the hold; any
    main-agent event cancels it.
15. `done` → `idle` after 20 min. A session with no event for 2 h is forgotten. `SessionEnd` forgets the session;
    the death of the pid it recorded forgets every session on that pid.
16. **A closed turn stays closed.** An `Interrupt`, or a verdict that the turn is over, closes the turn named by
    the last main-agent event that carried an id; the last 8 closed turns are kept. An event of a closed turn
    refreshes liveness and changes nothing — except a prompt or a start (always), a `SessionEnd`, and a
    main-agent `PreToolUse` of a turn a *verdict* closed, which reopens it; a turn an `Interrupt` closed reopens
    with a prompt only. For 120 s after an `Interrupt`, and until a prompt or a verdict closes the turn, a tool or
    permission event without a turn id changes nothing.

## 3. Rescues: asking the source when the hooks say nothing

17. A `working` session with nothing held, no live helper and no background shell, quiet for 20 s (0 at launch),
    is asked about at its source every 15 s: Claude Code's `<config>/sessions/<pid>.json`, Codex's managed daemon
    and then its rollout, Copilot's `events.jsonl`. OpenCode is never asked: its hooks, its server's exit and
    staleness end it. A Codex rollout or a Copilot `events.jsonl` that decided nothing is read again 15 s later at
    the earliest, however much else the journal delivers; Claude Code's record is read at every pass once due.
18. **Claude Code.** `<config>` is the parent of the last `projects` folder at least two levels above the
    transcript path (absolute, no `.` or `..`), else the process's own `CLAUDE_CONFIG_DIR`, else `~/.claude`. A
    record must name the pid and the session. `idle` stamped after the last main-agent event ends the turn at
    once, whatever the transcript says (the transcript may choose how an app shows the end, never whether it
    ended); `busy` is liveness, and 5 min of it with no hook logs one line; anything else decides nothing.
19. **Codex.** Only a session whose pid is the managed daemon (`--managed-daemon`, or under
    `/app-server-daemon/`) is asked `thread/read` (1 s, fail closed; only `initialize`, `initialized`,
    `thread/read`, `thread/loaded/list` are ever sent); a record about another thread, a partial loaded list, or
    an unknown shape or status decides nothing; `notLoaded` / `idle` → the turn is over, and the rollout says
    how: its `task_complete` of this turn is a finish, its `turn_aborted` or no end of this turn is an end that
    delivered nothing, dated to the marker, else the record's `updatedAt`; `active` → liveness. The rollout
    (`~/.codex/sessions/…/rollout-…-<sid>.jsonl`, named after the session, else found by id; last 64 KB): the
    last of `task_started` / `task_complete` / `turn_aborted` decides; an end stamped after the last main-agent
    event, or naming its turn, ends the turn; a start with no end is liveness; unreadable decides nothing. Any
    `codex` with an `app-server` argument or under `/app-server-daemon/` is a shared host: its pid alive proves
    nothing about one session, and its death forgets its sessions.
20. **Copilot, a quiet turn.** `<session-state>/<sid>/events.jsonl` only (the recorded path when it is exactly
    that, else the session's own; last 64 KB). The last marker decides: `abort`, `session.error`,
    `session.shutdown`, or the `hook.start` of an `agentStop` whose `data.input` names this session, stamped after
    the last main-agent event, ends the turn; a work step (`user.message`, `assistant.turn_start`,
    `assistant.message`, `tool.execution_start`, `tool.execution_complete`, `permission.requested`,
    `permission.completed`) is liveness; `assistant.turn_end` and a subagent's `agentStop` are no markers;
    unreadable decides nothing. A `session.shutdown` after the last main-agent event ends the turn whatever older
    end precedes it.
21. **Copilot, a wait.** A `waiting` Copilot session is read from the same file every 15 s from the moment the
    wait began, with no quiet gate. An `abort` stamped after the wait began → `idle`, the turn closed (Ctrl+C or
    a double Esc at the prompt fires no hook). With the turn still at work, a latest **permission line** that is
    `permission.completed`, stamped after the wait began → `working`, as of the check (approving or denying fires
    no hook). A latest `permission.requested` is a prompt still open — a second one opens right after the first
    is answered — and no other step is an answer: a tool called beside the prompt can finish while it waits. A
    question needs none of this: its answer ends the `ask_user` tool and `postToolUse` fires.
22. **Claude Code, a wait.** A `waiting` Claude Code session with a pid is re-read every 15 s: a record `busy`
    stamped more than 2 s after the wait began → `working`, as of the check, whatever the wait was.
23. Liveness from a source that says "running" is dated to that source's last write (the rollout's or the
    `events.jsonl`'s modification time or last line; the registry and the daemon, which have no file to date, at
    the check), never later than now, never earlier than the session's last event; it
    never counts as a main-agent event. A session whose source last wrote 2 h ago is forgotten by staleness.
24. A verdict that a turn is over closes the turn and follows the source: a **finished** turn (Claude Code's
    record `idle` — see § 6 —, Codex's `task_complete`, Copilot's own `agentStop`) is a lost
    `Stop` — `done`, or held while a helper is live or a background shell is out; every other end (aborted,
    failed, the session closed) leaves the session not working and never `done` (`idle`, or an app's own
    failure state), so a helper line without a turn id cannot reopen it. It takes effect at
    `min(max(endedAt, lastMainEventAt), now)`, `endedAt` being the
    source's own stamp (the registry's `statusUpdatedAt`, the end marker's, the daemon record's `updatedAt`); an
    answered wait takes effect as of the check. Every verdict is journaled at its stamp, and a replay applies the
    same outcome as of the same stamp. A verdict never creates a session, never refreshes liveness, changes
    nothing when stamped before the session's last main-agent event, and is refused by a state it does not apply
    to.
25. At launch: this boot's journal lines are replayed (the rotated file, then the live one, tailed from the
    consumed offset); the time rules run; a session is kept only while its pid is alive and runs its agent and,
    for Claude Code, while a registry record for the pid, when there is one, names the session (a shared Codex
    host is kept); the daemon's loaded list is awaited up to 2 s when a working session it hosts exists; then
    every working Claude Code, Codex and Copilot session, and every waiting Copilot session, is checked with no
    quiet gate. Nothing counts before that.

## 4. Processes

26. Claude Code is `claude` by name, a path ending in `/claude` or holding a `claude` component, or such an
    argv0; Codex the same for `codex`; Copilot the executable basename `copilot`; OpenCode the basenames
    `opencode`, `opencode-cli` and `.opencode`. A desktop app's own window process is none of them. A chain is
    read by `sysctl` from the parent, at most 15 hops. `kill(pid, 0)` proves a process; the process running the
    agent proves *the* process.

## 5. Terminal jobs

27. The zsh snippet reports a job from `preexec` (`job begin --id zsh-$$ --pid $$ --label <first head>` and the
    count-after) and ends it from `precmd` (`job end --id zsh-$$`, `$?` read first and returned). Segment heads
    are read after `VAR=value` words and the prefixes `sudo time command builtin exec nice nohup env noglob
    caffeinate` (with their flags, and the argument of `sudo -[ughpCDTUrt]`, `nice -n`, `env -[uCS]`); a segment of prefixes
    alone (`sudo -i`) opens an interactive shell and skips the whole line, as one head on the skip list does. The skip list: `vi vim nvim emacs
    nano pico less more man info ssh mosh tmux screen top htop btop watch tig lazygit su login claude codex
    copilot opencode grok koffeelid mysidepulse`, and the shells `zsh bash sh fish dash ksh` when every word
    after the shell is a flag. The job variable is declared, never assigned, at load; an interactive shell
    loading the snippet ends `zsh-$$` first.
28. **A shell whose process chain holds a Claude Code, Codex (its app-server daemon included), Copilot or
    OpenCode (its server included) process is that agent's own work, never a terminal command**: the hook writes
    no `job begin` for it, and the app drops such a job when it reads it, live or replayed, while the shell's pid
    can be read. (An agent's shell tool can run an interactive zsh, and OpenCode's server keeps a tool's process
    running after a Ctrl+C in its window.)
29. A job reaches the app as a journal line (`JobBegin` / `JobEnd`), replayed at launch like every other line, and
    counts after 5 s by default. One job per shell: a new `begin` evicts the shell's previous job.
30. While a job runs, its shell is asked at every pass and at least every 15 s, and once at launch before anything
    counts: the pid gone, or held by a process forked after the job began → dropped; the process no longer a
    shell → kept, for the exit watch; a shell at its prompt (`tpgid == pgid`) with no child forked since the job
    began, seen so twice 5 s apart → dropped; anything else → kept with no time limit. Only a job without a shell
    pid is dropped after 2 h.

## 6. Not in the contract

One bounded exception: how a rescued Claude Code end is classified. my-sidepulse reads the transcript when the
record says `idle` and counts a finish only when it ends on a completed answer (its colour and its push depend on
it), else an end that delivered nothing; koffeelid reads no transcript and counts every such end a finish. Both
end the turn at the same moment and close it, so a later line of that turn changes nothing in either; only a
helper line carrying no turn id could reopen koffeelid's and not my-sidepulse's.

Each app's own: what a non-working state looks like (wait reasons, colours, the alert settle, pushes and their
timing, acknowledgement — my-sidepulse; the hold-off after work, "Disarm once finished", the drop on local
input, the badges — koffeelid), job outcomes and my-sidepulse's `run` wrapper, set-up ergonomics (which agents
an install sets up), and every name that has to differ: journal files, verdict line names, plugin ids, hook
markers, the `*_DISABLE` variables, each app's own CLI name, and the job lines' own keys (koffeelid's
`job_arm_after_seconds`; my-sidepulse's `job_slot_pid`, `job_show_after_seconds`, `job_exit_code`, which carry its
job outcomes).

## 7. Constants, equal in both apps

| Meaning | Value |
|---|---|
| A helper is live after its last event | 240 s |
| A held finish becomes `done` after the last helper clears | 90 s |
| The longest hold without an event | 30 min |
| `done` → `idle` | 20 min |
| A silent session is forgotten | 2 h |
| Quiet before `idle_prompt` counts as a lost `Stop` | 50 s |
| Quiet before a working session is asked at its source | 20 s |
| Recheck cadence (quiet turns, open waits, Copilot waits) | 15 s |
| Quiet before a waiting Copilot session is first read | none |
| Tool or permission lines without a turn id ignored after an `Interrupt` | 120 s |
| Source says running with no hook, before one log line | 300 s |
| Registry `busy` lead over a wait's start | 2 s |
| Rollout and `events.jsonl` tail read | 64 KB |
| One daemon call, connection included | 1 s |
| Launch wait for the daemon's loaded list | 2 s |
| Closed turns remembered per session | 8 |
| One journal line / payload kept / identifier clamp / transcript path clamp | 4096 B / 8 MB / 200 / 1024 |
| Background shell ids | 16 × 40 characters |
| Job label | 60 characters |
| A command counts after (default) | 5 s |
| A job's shell asked at least every / second sighting at the prompt / job with no shell pid dropped | 15 s / 5 s / 2 h |
| Journal rotation, idle / hard (idle as each app defines it) | 5 MB / 20 MB |
| Codex hook timeout, `SessionEnd` and `Interrupt` / others | 3 s / 5 s |
| Copilot hook `timeoutSec` | 5 s |
| OpenCode plugin: hook timeout / queue / dedupe set | 2 s / 256 / 2048 |
| Process chain walk | 15 hops |

## 8. Where each rule lives

Paths from each repository's root. A rule's test in one app has its twin in the other; a new rule gets both.

| Contract | koffeelid | my-sidepulse |
|---|---|---|
| § 1 Sources: the events, Codex's trust, the hook, the trim | `Sources/KoffeeLidCore/HookConfig.swift`, `CodexHookTrust.swift`, `SHA256.swift`, `CopilotHookFile.swift`, `CopilotSessionState.swift`, `OpencodePlugin.swift`, `ActivityTrim.swift`, `ActivityEvent.swift`, `ActivityJournalWriter.swift`; `Hook/Sources/main.swift`; `App/Sources/HookInstaller.swift` | `Sources/MySidepulseCore/HookConfig.swift`, `CodexHookTrust.swift`, `SHA256.swift`, `CopilotSessionState.swift`, `Trim.swift`, `Event.swift`; `Sources/MySidepulsePlatform/HookCommand.swift`, `HookInstaller.swift`, `JournalWriter.swift`; `Sources/MySidepulseCLI/CLIMain.swift` |
| § 2 The session machine | `Sources/KoffeeLidCore/ActivitySessionStore.swift` (`apply`, `changesNothing`, `closeTurn`, `tick`) | `Sources/MySidepulseCore/SessionStore.swift` (`apply`, `changesNothing`, `closeTurn`, `tick`) |
| § 3 Rescues | `Sources/KoffeeLidCore/ClaudeRegistryRecord.swift`, `CodexRolloutTail.swift`, `CodexThreadRecord.swift`, `WebSocketFrame.swift`, `CopilotTranscriptTail.swift`; `App/Sources/ActivityMonitor.swift` (`checkRegistry`, `checkCodex`, `daemonAnswered`, `checkCopilot`, `start`), `ClaudeProcessRegistry.swift`, `CodexDaemonClient.swift`, `CodexRollout.swift`, `CopilotTranscript.swift` | `Sources/MySidepulseCore/ClaudeQuietTurn.swift`, `CodexRolloutTail.swift`, `CodexThreadRecord.swift`, `WebSocketFrame.swift`, `CopilotTranscriptTail.swift`; `Sources/MySidepulseApp/Engine.swift` (`checkAbandonedTurns`, `checkCodexTurns`, `daemonAnswered`, `checkCopilotTurns`, `start`); `Sources/MySidepulsePlatform/ClaudeProcessRegistry.swift`, `TranscriptTail.swift`, `CodexDaemonClient.swift`, `CodexRollout.swift`, `CopilotTranscript.swift`, `FileTail.swift` |
| § 4 Processes | `Sources/KoffeeLidCore/ProcWalk.swift`; `App/Sources/ActivityProcessWatcher.swift` | `Sources/MySidepulsePlatform/ProcWalk.swift`, `ProcessWatcher.swift` |
| § 5 Terminal jobs | `Sources/KoffeeLidCore/ShellInit.swift`, `ActivityJobStore.swift`, `ShellJobLiveness.swift`; `Hook/Sources/main.swift` (`job`); `App/Sources/ActivityMonitor.swift` (`ingest`, `probeJobs`) | `Sources/MySidepulseCore/ShellInit.swift`, `JobStore.swift` (`JobLine`, `apply`), `ShellJobLiveness.swift`; `Sources/MySidepulsePlatform/JobJournal.swift`; `Sources/MySidepulseCLI/RunCommand.swift` (`JobReport`); `Sources/MySidepulseApp/Engine.swift` (`ingest`, `probeJobs`) |
| § 7 Constants | `Sources/KoffeeLidCore/ActivityConstants.swift` | `Sources/MySidepulseCore/Constants.swift` (`K`) |
