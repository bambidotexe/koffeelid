# Copilot and OpenCode beside Claude Code and Codex — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** KoffeeLid auto-arms while GitHub Copilot CLI or OpenCode works, exactly as it does for Codex: hooks set up from the onboarding, Settings › Auto-Arm and the CLI, their own hold-off, their Health line and reading, their badge on the auto-armed cup, their removal by Reset and Uninstall, and a rescue for the end a hook cannot report.

**Spec:** the owner's request of 2026-09-26: "add support for opencode and copilot to koffeelid and my-sidepulse … look at the git history from the last 12 hours to understand how to do it, we did Codex, do the exact same thing … follow your own recommendation." The Codex precedent is commits `905e181` (the feature), `60be945`…`bd9098b` (the badges), `15e346d`, `24897df` (the rollout check) and `0ef0389`. The facts about the two agents come from two research records made on this Mac on 2026-09-26, each fact tagged VERIFIED / DOCUMENTED / INFERRED:
`/private/tmp/claude-501/-Users-Rubens-Projects-koffeelid/5630704b-c3a1-4a7b-99b0-a1d350a65e89/scratchpad/research-copilot.md` and `…/research-opencode.md` (raw probe logs beside them in `probe/` and `opencode-probe/`). The essentials are copied below; the records win on any detail this plan leaves out.

**Tech Stack:** Swift 5, SwiftPM (`KoffeeLidCore`), XcodeGen app target and two tools, XCTest.

## The two agents, in short

### GitHub Copilot CLI (1.0.88; also the CLI copy GitHub Copilot.app runs)
- **User hooks** load from `~/.copilot/hooks/*.json` with no trust step and no flag, read at each `copilot` start. KoffeeLid owns the whole file `~/.copilot/hooks/koffeelid.json` (create `hooks/` if missing; never touch `settings.json` or `config.json`). Format, camelCase keys, `exec` form (no shell):
  `{"version":1,"hooks":{"agentStop":[{"type":"command","exec":"<abs path>/Contents/MacOS/KoffeeLidHook","args":["hook","copilot","agentStop"],"timeoutSec":5}], …}}`.
  camelCase payloads carry **no event name**, so the event rides in `args`.
- **The events KoffeeLid subscribes (7), in this order:** `sessionStart`, `userPromptSubmitted`, `postToolUse`, `postToolUseFailure`, `notification`, `agentStop`, `sessionEnd`.
  - **Never `preToolUse` and never `permissionRequest`:** for `preToolUse` any non-zero exit, a crash or a missing binary DENIES the tool (fail-closed), and exit 2 denies for both. A hook file that outlives the app would block every Copilot tool call. Consequence for the hook binary: **every `hook …` invocation exits 0, including unrecognised arguments** (today `hook` with bad arguments prints usage and exits 2).
  - Not subscribed either: `preCompact` (there is no `postCompact`), `errorOccurred` (fires on retried errors too; the transcript check below decides a failed turn), `subagentStart/Stop` (no subagent id on start, nothing to track).
- **Payloads** (stdin, camelCase): `sessionId` (a UUID, equal to the directory `~/.copilot/session-state/<id>/`), `timestamp` (ms), `cwd`; `toolName` on tool events; `notification` carries snake `notification_type` (`permission_prompt`, `elicitation_dialog` = an `ask_user` question, `shell_completed`, …); `agentStop` carries `transcriptPath` (`…/session-state/<id>/events.jsonl`) and `stopReason`; `sessionStart` carries `source` (`new|resume|startup`); `sessionEnd` carries `reason` (`complete` after every `-p` turn, `user_exit` at interactive exit, `error`, `abort`, `timeout`). Accept `session_id` as a fallback key.
- **Order quirks:** `sessionStart` is lazy: it fires with the first prompt, **after** `userPromptSubmitted`, so a Copilot `SessionStart` must change no state. Interactive exit fires `sessionEnd` even for a session that never started.
- **Subagents:** a subagent's own `userPromptSubmitted` / `agentStop` carry the **subagent's** id, which has no `session-state` directory (its `agentStop`'s `transcriptPath` names the parent's file). The hook drops a Copilot event whose `sessionId` has no directory under the session-state root, when that root exists; the root is `$COPILOT_HOME/session-state` when the hook's environment sets `COPILOT_HOME`, else `~/.copilot/session-state`.
- **Needs you:** `notification` with `permission_prompt` or `elicitation_dialog`. Answering fires no hook; the next `postToolUse` is the answer.
- **What no hook reports:** Ctrl+C / Esc-Esc (interrupt) fires **nothing**; a failed turn fires only `errorOccurred` (not subscribed) and no `agentStop`; a killed Copilot fires no `sessionEnd`. Copilot writes `~/.copilot/session-state/<id>/events.jsonl`, one JSON object per line `{"type","data","id","timestamp"(ISO),"parentId"}`; its turn markers: `abort` (`data.reason` `user_initiated|user_abort|remote_command|…`) = the turn was aborted; `session.error` = the turn failed; `session.shutdown` = the session closed; `hook.start` with `data.hookType == "agentStop"` = a natural end (present because our hooks are installed; check whether `data.input` names the session, since a subagent's agentStop may be mirrored into the parent's file — see `probe/` logs); `user.message`, `assistant.turn_start`, `assistant.message`, `tool.execution_start`, `tool.execution_complete`, `permission.requested`, `permission.completed` = running. `session.idle` is never written. This is the Codex rollout's twin and gets the same quiet check.
- **Process:** the hook's parent is the `copilot` process (kernel name and executable basename `copilot`: `~/.local/bin/copilot`, or GitHub Copilot.app's pooled `~/Library/Caches/github-copilot-sdk/cli/<ver>/copilot`). One process can hold several sessions; no daemon. `COPILOT_CLI=1` is set in the hook.
- **Disabled hooks:** `"disableAllHooks": true` in `~/.copilot/settings.json` (JSON) or `~/.copilot/config.json` (JSON with `//` line comments) turns every user hook off: the row reads Disabled then.
- **The badge app:** GitHub Copilot.app, `com.github.githubapp`.

### OpenCode (2.0.17; the TUI, `opencode run` and OpenCode.app are all clients of one background server)
- OpenCode has no command hooks; KoffeeLid installs a **plugin**, the file `~/.config/opencode/plugins/koffeelid.js` (create `plugins/` if missing; never touch `service.json` or `opencode.json` beside it). No registration, no trust step; a running server loads, reloads and unloads the file within a second. Removing = deleting the file.
- **The plugin source** is the tested one in `research-opencode.md` § 9.2, generated by Core from the hook command and the plugin id `dev.rubens.koffeelid.opencode`, with two changes: drop `location.shutdown` from `FORWARDED` and drop every `directory` field (no path leaves OpenCode). The v2 shape is `export default { id, setup(ctx) }` and `ctx.event.subscribe()`; a v1-style plugin fails to load. The plugin de-duplicates by event id through `globalThis` (one instance per open directory, each sees every directory's events), runs one hook at a time in event order, caps each at 2 s, never throws. Its first line is a comment naming KoffeeLid; a file is ours when it holds the marker `/Contents/MacOS/KoffeeLidHook` and the id; it is current when it equals, byte for byte, what this bundle would write.
- **Hook command:** `<abs path>/Contents/MacOS/KoffeeLidHook hook opencode`; stdin is one JSON object: `hook_event_name` (the OpenCode event type verbatim), `session_id` (`ses_…`), `event_time` (ms), `opencode_pid` (the server = the hook's parent), and only when relevant `parent_id`, `delivery`, `status`, `reason`, `error_name`, `tool_name`, `tool_use_id`, `permission`, `question`.
- **Mapping onto the journal vocabulary** (done in Core by the trim). A session with `parent_id` is a subagent: its events become helper events of the parent (`sessionId` = `parent_id`, `agentId` = the child's id).

  | OpenCode `hook_event_name` | top-level session | subagent (has `parent_id`) |
  |---|---|---|
  | `session.created`, `session.forked` | SessionStart | SubagentStart |
  | `session.inbox.enqueued`, `session.execution.started` | UserPromptSubmit | UserPromptSubmit (helper) |
  | `session.tool.called` | PreToolUse (`tool_name`) | PreToolUse (helper) |
  | `session.tool.success` | PostToolUse | PostToolUse (helper) |
  | `session.tool.failed` | PostToolUseFailure | PostToolUseFailure (helper) |
  | `permission.asked` | PermissionRequest | PermissionRequest (helper: the parent waits) |
  | `permission.replied` with `status` `once`/`always` | PostToolUse | PostToolUse (helper) |
  | `permission.replied` with `status` `reject` | PermissionDenied | PostToolUse (helper) |
  | `form.created` with `question: true` | Notification `elicitation_dialog` | PermissionRequest (helper) |
  | `form.created` with `question` false or absent | nothing (an MCP form, maybe `session_id` `global`) | nothing |
  | `form.replied`, `form.cancelled` | PostToolUse | PostToolUse (helper) |
  | `session.compaction.started` | PreCompact | PreCompact (helper) |
  | `session.compaction.ended`, `.failed` | PostCompact | PostCompact (helper) |
  | `session.execution.succeeded` | Stop | SubagentStop |
  | `session.execution.failed` | StopFailure | SubagentStop |
  | `session.execution.interrupted` (any `reason`) | Interrupt | SubagentStop |
  | `session.deleted` | SessionEnd | SubagentStop |
  | anything else | nothing | nothing |

  "Nothing" means the hook writes no line. OpenCode has no turn id (`turnId` stays nil).
- **Process:** the hook's parent is the OpenCode server (`opencode serve --service`, parented by launchd, or a `--standalone` `opencode-cli serve --stdio` under the client). Kernel name / executable basename `opencode`, `opencode-cli` or `.opencode`. The server hosts every session: alive, it proves nothing about one session; dead, all its sessions are gone. The hook takes `opencode_pid` when it is an ancestor that looks like OpenCode, else the nearest OpenCode ancestor.
- Every busy period ends in exactly one terminal (`succeeded`, `failed`, `interrupted`) and a user abort is always told apart, so OpenCode needs no transcript check; a lost terminal is covered by the server's death and the 2 h staleness.
- **The badge app:** OpenCode.app, `ai.opencode.desktop`.

## Global Constraints

- Read `CLAUDE.md` first; its Rules and Invariants bind every task. Nothing here changes arming semantics: Copilot and OpenCode are two more sources of the auto level, exactly like Codex (invariant 9). No TCC or privilege change.
- `KoffeeLidCore` is Foundation-only, pure, with injected time; every rule gets its unit test first. The app has no automated tests: anything it does gets a line in `docs/manual-test-checklist.md` and, where it logs, an exact log line.
- Names: the product names are **Copilot** and **OpenCode** everywhere KoffeeLid shows or logs one (`ActivityAgent.name`, the rows, the menu line, the CLI word `copilot` / `opencode`). The French words follow the Codex strings (`Suivi de Codex` → `Suivi de Copilot`, …).
- Order everywhere a list of agents appears: Claude Code, Codex, Copilot, OpenCode, then the terminal (this is `ActivityKind`'s raw-value order: claude < codex < copilot < opencode < terminal).
- `docs/functional.md` is replaced, never annotated; each task updates the documents its change makes false or incomplete, in the same commit. Comments state the present rule.
- Every user-visible string goes through `L("literal")` with its `fr` entry in `App/Resources/Localizable.xcstrings`, edited in place (never load and re-serialise the catalog).
- Verification per task: `swift test` green, counting per-case lines (`swift test 2>&1 | grep -E "^Test Case '.*' passed" | sort -u | wc -l`, 521 before this plan) and no `failed` line; for any task touching `App/`, `Hook/` or `project.yml`: `script/bootstrap.sh` if files were added, then `DEBUG_OK=1 script/build.sh Debug 2>&1 | grep -E "warning:|error:"` prints nothing but `appintentsmetadataprocessor` lines, then delete the `.app` the build printed. Both need Claude Code's sandbox off (`dangerouslyDisableSandbox: true`).
- **Never** install, never launch a built app, never run `script/install.sh`, never send `koffeelid off`, never run `claude`, `codex`, `copilot` or `opencode`, never write into `~/.claude`, `~/.codex`, `~/.copilot`, `~/.config/opencode` or `~/.zshrc` (tests use temporary directories).
- Commit per task on `main`, staged by path (never `git add -A`; `AGENTS.md` is the owner's, leave it untracked), subject `feat|fix|docs(activity): …`, body ending with exactly:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_0158pDfMDJWkrsujYpmW5Syi`
  Do not push.

## Rulings made before execution

- Ruling: Copilot subscribes 7 events and never `preToolUse`/`permissionRequest` — a fail-closed hook would block every Copilot tool if the app were removed without its uninstall — costs the tool-start signal, which the transcript check replaces.
- Ruling: Copilot's quiet turns get the Codex rollout check against `events.jsonl` — Ctrl+C fires no hook, so without it an interrupted turn holds the Mac armed for 2 h — costs one more reader.
- Ruling: OpenCode's events are mapped onto the existing vocabulary by the trim, not given new names — the store stays agent-agnostic and every proven rule applies — costs a mapping table to keep in step with OpenCode's event names.
- Ruling: the Health page gets a check line and a reading per new agent, like Codex; the check shows only while the agent is on this Mac (Copilot: `~/.copilot` exists; OpenCode: `~/.config/opencode`, `~/.opencode` or `/Applications/OpenCode.app` exists) or its hooks are set up; `HealthLimits` become 13 checks and 8 readings — the owner asked for "the exact same thing" and accepted an exception for the third hook — costs a longer page; the next step, if the owner finds it long, is one "Agent hooks" line.
- Ruling: the onboarding's hooks page shows all five rows at 560 pt (the family's height for five rows), and Settings › Auto-Arm gets one group per agent — the same as Codex.
- Ruling: the menu's greyed auto-arm line is built from a list instead of one key per combination (31 combinations) — `Auto-armed while %@ works|work|runs|run`, the names joined with `, ` and ` and ` / ` et ` — costs the existing seven keys, replaced.

---

### Task 1: The agent model — two more agents, their events, their processes, their badges

**Files:** `Sources/KoffeeLidCore/ActivityEvent.swift`, `ActivityTrim.swift`, `ActivityArmPolicy.swift` (`ActivityKind`), `ActivityConstants.swift` (`holdOffDefaults`), `ActivitySessionStore.swift`, `ProcWalk.swift`, `ActivityBadges.swift`, `Hook/Sources/main.swift`; tests in `Tests/KoffeeLidCoreTests/` (`ActivityEventTests`, `ActivityTrimTests`, `ActivitySessionStoreTests`, `ProcWalkTests`, `ActivityBadgesTests`, `ActivityArmPolicyTests`, a new `CopilotHookTests` / `OpencodeHookTests` if clearer). Docs: `docs/architecture.md` § Auto-arm on activity (the agents, the hook verbs, the mapping), `docs/macOS.md` (new § Copilot and § OpenCode: where hooks live, payloads, process shapes — from the two records).

Requirements:
1. `ActivityAgent` gains `copilot` and `opencode` (`name` "Copilot", "OpenCode"); `ActivityKind` gains `copilot`, `opencode`; `holdOffDefaults` gives each 30 min (same comment as Codex).
2. `ActivityEventName`: `hookEvents(for:)` answers for all four agents with the journal events each can produce after mapping: Copilot → SessionStart, SessionEnd, UserPromptSubmit, PostToolUse, PostToolUseFailure, Notification, Stop; OpenCode → SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact, Interrupt. The installed Copilot event names (the camelCase seven, in the order above) are a separate public list (they are Copilot's words, not the journal's), e.g. `ActivityEventName.copilotHookEvents: [String]` or on the install type of Task 3 — one source of truth.
3. `ActivityTrim`: a Copilot payload is trimmed from its event name (the verb's third word) and its camelCase body: `sessionStart`→SessionStart (`source`), `userPromptSubmitted`→UserPromptSubmit, `postToolUse`→PostToolUse (`toolName`), `postToolUseFailure`→PostToolUseFailure, `notification`→Notification (`notification_type`), `agentStop`→Stop (`transcriptPath`), `sessionEnd`→SessionEnd; any other name or an unparseable body is the usual `ParseError` line with `rawPrefix`. An OpenCode payload is trimmed by the mapping table above (subagent → helper event of the parent; "nothing" rows produce no event: make the API able to say "write nothing", e.g. an optional result). Clamp every copied string as today; bodies never reach the journal.
4. The Copilot subagent filter is a pure function in Core (`sessionId`, the session-state root, a `directoryExists` closure → keep or drop), used by the hook binary; the hook also sets `transcriptPath` on a Copilot SessionStart, UserPromptSubmit and Stop line to `<root>/<sessionId>/events.jsonl` when the payload names none (so the transcript check of Task 2 knows the file before the first Stop).
5. `ProcWalk`: `isCopilotProcess` (name or executable basename `copilot`), `isOpencodeProcess` (`opencode`, `opencode-cli`, `.opencode`); `isProcess(of:)`, `pid(of:inChainFrom:)`, `looksLike` cover all four agents. For OpenCode the hook prefers `opencode_pid` when it is an ancestor that looks like OpenCode.
6. `ActivitySessionStore`: a Copilot `SessionStart` changes no state (lazy start, after the prompt) — it records the pid and the transcript path only. Nothing else in the state machine changes; `workingCount(of:)` works for all agents. Prove with tests replaying the recorded sequences: Copilot `-p` run (UserPromptSubmit → SessionStart → PostToolUse → Stop → SessionEnd), Copilot interactive with a permission prompt and an `ask_user` question (Notification permission_prompt / elicitation_dialog → waiting, PostToolUse → working, Stop → done), OpenCode run with a permission auto-approved 3 ms later, OpenCode reject → interrupted, OpenCode with a subagent whose Stop is held until its SubagentStop, OpenCode question form.
7. `ActivityBadge.copilot` = `com.github.githubapp`, `ActivityBadge.opencode` = `ai.opencode.desktop`; badges sort Claude, Codex, Copilot, OpenCode, terminals.
8. `Hook/Sources/main.swift`: `hook` → Claude Code, `hook codex`, `hook copilot <event>`, `hook opencode`; every `hook …` form exits 0, unrecognised arguments included (writes nothing then); `job …` keeps its usage/exit 2. The Copilot subagent filter and transcript path (4) run here, reading `COPILOT_HOME` from the environment.
9. Existing journal lines (no `agent`, `claude_pid`) keep decoding exactly as today.

Commit: `feat(activity): Copilot and OpenCode as agents: their events, their processes, their badges`.

### Task 2: A quiet Copilot turn is checked against its `events.jsonl`

**Files:** new `Sources/KoffeeLidCore/CopilotTranscriptTail.swift` (+ tests), `ActivitySessionStore.swift` (candidates), new `App/Sources/CopilotTranscript.swift` (the reader, like `CodexRollout.swift`), `App/Sources/ActivityMonitor.swift` (the check and the launch check), `script/bootstrap.sh` run. Docs: `docs/functional.md` § Auto-arm on activity (what ends a Copilot turn without a hook), `docs/architecture.md`, `docs/macOS.md` § Copilot (the file), `docs/pitfalls.md` (new § Copilot hooks: interrupt fires nothing, preToolUse is fail-closed, lazy sessionStart, subagent ids), `docs/manual-test-checklist.md` § Auto-arm on activity (the Ctrl+C walk, the exact log lines).

Requirements — mirror `CodexRolloutTail` / `CodexRollout` / `checkCodex` (read them first; keep their shape and wording where it fits):
1. `CopilotTranscriptTail.verdict(tail:)` over the last 64 KB: the last turn marker among the types listed in "The two agents" (`abort` → aborted(at), `session.error` → failed(at), `session.shutdown` → ended(at), `hook.start` agentStop of this session → complete(at), the running types → running); only `type`, `timestamp`, `data.reason`, `data.hookType` and the session id inside `data.input` are read; a line that is not a whole JSON object is skipped; nothing else of a line is kept or logged.
2. `isTranscript(path:ofSession:sessionStateDirectory:)`: absolute, no `.`/`..`, exactly `<root>/<sessionId>/events.jsonl`. A recorded path is read only then.
3. `decision(verdict:lastMainEventAt:writtenAt:now:)`: an end marker stamped after the last main-agent event ends the turn (`turnOver` with reason `finished`, `aborted`, `failed` or `ended`, at the marker's stamp); running is busy unless the file was last written `staleSeconds` or more before now; unreadable decides nothing.
4. The store hands out `copilotCandidates` (working Copilot sessions quiet `abandonQuietSeconds`, nothing out) like `codexCandidates`; `nextDeadline` schedules their recheck; the monitor reads each (path from the session, else `~/.copilot/session-state/<id>/events.jsonl`), applies `turnOver` at `rescueStamp` / `noteBusy`, journals the verdict line exactly as for Codex, and logs `activity: quiet Copilot turn <sid8> — transcript says <reason>, turn over` / `activity: no transcript for Copilot session <sid8>; staleness ends it`. At launch every working Copilot session is checked with no quiet gate, after the time rules, as Codex's.

Commit: `feat(activity): a quiet Copilot turn is checked against its events.jsonl`.

### Task 3: Setting the hooks up and taking them away

**Files:** new `Sources/KoffeeLidCore/CopilotHookFile.swift` and `OpencodePlugin.swift` (+ tests), `Sources/KoffeeLidCore/UninstallPlan.swift` (comment), `App/Sources/HookInstaller.swift`, `App/Sources/CommandServer.swift`, `App/Sources/main.swift` if the verb list lives there, `App/Sources/KoffeeLidController.swift` (`uninstallEverything`, `resetEverything`, the "Disarm once finished" gate, `preferenceChanged` keys, `autoArmHint`), `App/Sources/Preferences.swift` (`activityHoldOff.copilot|opencode`, 30 min), `App/Sources/ActivityMonitor.swift` (`ActivitySnapshot` per agent — a dictionary of working counts replaces `claudeSessions`/`codexSessions`; `lastEvent` per agent replaces `lastClaudeEvent`/`lastCodexEvent`; `summary` names every agent), `App/Resources/Localizable.xcstrings` (the menu line). Docs: `docs/functional.md` (§ Modes and arming auto-arm bullets, § Settings and defaults rows for the two hold-offs, § User interface the menu line and the CLI verbs, § Uninstall), `docs/architecture.md`, `docs/development.md` (a CLI verb), `README.md` if it lists the agents.

Requirements:
1. `CopilotHookFile` (pure): the root object for a hook path (7 entries, order above, `timeoutSec` 5, `exec` + `args`); `installedCount(in:root, hookPath:)` counts the events whose array holds our entry for this path; an entry is ours when `exec` ends in `/Contents/MacOS/KoffeeLidHook` and `args` starts `["hook","copilot"]`; `disabled(settingsText:configText:)` true when either sets `disableAllHooks` true (strip whole-line `//` comments before parsing).
2. `OpencodePlugin` (pure): `source(hookPath:)` → the plugin text; `isOurs(_ text:)`; `isCurrent(_ text:, hookPath:)`.
3. `HookInstaller`: `installCopilot` (writes `~/.copilot/hooks/koffeelid.json` whole, creating the directory; the file is ours, no backup needed; message `Installed 7 Copilot hooks -> <path> hook copilot`), `uninstallCopilot` (deletes the file; absent is success), `copilotInstalledCount()` and an off-main variant told its paths, `copilotHooksDisabled`; `installOpencode` / `uninstallOpencode` / `opencodeInstalled()` (+ off-main variant) for `~/.config/opencode/plugins/koffeelid.js`; resolve symlinks like the other paths; refuse to overwrite a file at our path that is not ours (say so, change nothing).
4. CLI: `install-hooks [claude|codex|copilot|opencode]`, `uninstall-hooks [same]`; usage strings updated everywhere they appear.
5. Reset and Uninstall remove the Copilot file and the OpenCode plugin when present, with the same success / failure reporting as Codex (`copilot hooks removed`, `opencode plugin removed`, and `The Copilot hooks could not be removed: %@` / `The OpenCode plugin could not be removed: %@` with `fr`).
6. The menu line: `autoArmHint` builds from the kinds (Ruling above): EN `Auto-armed while %@ works` / `… work` / `… runs` / `… run`, FR `Activé automatiquement tant que %@ travaille` / `travaillent` / `tourne` / `tournent`; names in order, a command is `a command` / `une commande`, joined `, ` and ` and ` / ` et `; the old seven keys are removed from the catalog. "Disarm once finished" shows while any of the five hooks is set up.

Commit: `feat(activity): set up and remove Copilot's hooks and OpenCode's plugin, from the CLI, Reset and Uninstall`.

### Task 4: The windows — onboarding, Settings › Auto-Arm, Health

**Start by reading `~/.claude/skills/macos-building-onboarding/SKILL.md` and `~/.claude/skills/macos-building-settings-pages/SKILL.md`.**

**Files:** `App/Sources/UI/Hooks.swift` (two `PermissionItem`s after Codex), `Sources/KoffeeLidCore/SettingsStatus.swift` (`SettingsGrant.copilotHooks`, `.opencodeHooks`, not required; the "no hook set up" warning counts all five), `App/Sources/UI/SettingsAutoArmPage.swift` (a Copilot group and an OpenCode group like Codex's: status row Enabled/Disabled, Set Up / Remove button, the hold-off slider `Stay armed after Copilot finishes`; the page's intro and the sessions reading name every agent), `App/Sources/UI/SettingsModel.swift` if grants are polled there, `App/Sources/UI/OnboardingWindowController.swift` (the hooks page: five rows at 560 pt; its intro and the hero sentence name the new agents), `Sources/KoffeeLidCore/HealthReport.swift`, `Health.swift` (`HealthLimits` 13 and 8, and the worst-case test), `App/Sources/UI/HealthCheck.swift`, `App/Sources/UI/HealthWords.swift`, `App/Sources/UI/SettingsGeneralPage.swift` (the Uninstall sentences name Copilot and OpenCode), `App/Resources/Localizable.xcstrings` (every new string with `fr`). Tests: `HealthTests`, `SettingsStatusTests`, `SettingsWordsTests`. Docs: `docs/functional.md` § User interface (onboarding page 3, Auto-Arm page, Health), § Permissions if it lists the hooks, § Settings and defaults; `docs/manual-test-checklist.md` § Settings UI and § Auto-arm (the new rows).

Requirements:
1. Row words, following Codex's exactly: titles `Copilot`, `OpenCode`; why: "Tells KoffeeLid when a Copilot session is working, so it arms while you close the lid and disarms once the turn is over. Adds ~/.copilot/hooks/koffeelid.json." and "Tells KoffeeLid when an OpenCode session is working, so it arms while you close the lid and disarms once the turn is over. Adds the plugin ~/.config/opencode/plugins/koffeelid.js." Group hints like Codex's hint, naming the file. Buttons `Set Up Copilot` / `Remove from Copilot`, `Set Up OpenCode` / `Remove from OpenCode`. Status labels `Copilot hooks` / `OpenCode plugin`. French in the Codex strings' style.
2. The Copilot row is granted when all 7 entries point at this bundle and hooks are not disabled; the OpenCode row when the plugin file is current.
3. Health: checks `Copilot hooks` and `OpenCode plugin` (orange when not set up, optional), each only while its agent is on this Mac or it is set up (Ruling); details: the count `n of 7`, "~/.copilot/hooks/koffeelid.json could not be read", "Copilot hooks are turned off (disableAllHooks)", "the OpenCode plugin belongs to another copy of KoffeeLid" (stale); fixes "Set up Copilot on the Auto-Arm page." / "Set up OpenCode on the Auto-Arm page.". Readings `Last Copilot event`, `Last OpenCode event`, only while set up.
4. Build warning-free; `SettingsWordsTests` covers the new words.

Commit: `feat(activity): Copilot and OpenCode rows on the onboarding, Settings › Auto-Arm and Health`.

### Task 5: The documents that describe the whole

**Files:** `CLAUDE.md` (What this project is; the "Where a change usually lands" rows for auto-arm, hooks, CLI; Architecture in one screen; Traps 6; Status: what is in the tree and not walked), `README.md`, `docs/README.md`, `docs/functional.md` / `architecture.md` / `macOS.md` / `pitfalls.md` / `development.md` / `manual-test-checklist.md` (a sweep for every sentence that still says "Claude Code and Codex" where all four are meant, and "three hooks" / "12 events"-style counts), `~/.claude/skills/macos-building-settings-pages/SKILL.md` (koffeelid's Health row: the two new checks and readings, limits 13 and 8), `~/.claude/skills/macos-building-onboarding/SKILL.md` (koffeelid's row: the Copilot hooks file and the OpenCode plugin, five rows at 560 pt), `~/.claude/skills/macos-map/SKILL.md` (koffeelid's line mentions Claude Code activity only: say coding agents).

Commit: `docs(activity): CLAUDE.md, the README and the documents follow Copilot and OpenCode`.
