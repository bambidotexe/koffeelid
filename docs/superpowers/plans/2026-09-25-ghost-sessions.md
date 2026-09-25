# Ghost sessions: turn identity, Codex liveness, Claude Code rescues, terminal jobs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No session or job can keep the Mac armed after its work has ended, for any of the three hooks (Claude Code, Codex, terminal), on any end path the analysis found.

**Architecture:** Every fix lands in the layer that owns it: `KoffeeLidCore` for the rules (turn identity, compaction, rollout and daemon verdicts, job liveness), the app for the readers (rollout file, daemon socket, registry, process probes) and the monitor's schedule, `ShellInit` for the zsh snippet. Docs move in the same commit as the code they describe. Nothing here touches arming itself: the auto level still follows `ActivityMonitor`'s snapshot; the tasks only make that snapshot true.

**Tech Stack:** Swift 5, SwiftPM (Core), XcodeGen app target, XCTest, zsh (snippet tests run a real `/bin/zsh -f -i`).

**Spec:** `.superpowers/sdd/2026-09-25-ghost-sessions/spec/` holds the four analysis reports: `report-synthesis.md` (start here), `report-codex.md`, `report-claude.md`, `report-terminal.md`. Every rule below argues from them; when the plan and a report disagree, the report's evidence wins and the ruling goes in the ledger.

## Global Constraints

- Read `CLAUDE.md` first. Its Rules and Invariants bind every task. The owner has approved this plan's behaviour changes; nothing else about arming, TCC or privilege may change.
- `KoffeeLidCore` is Foundation-only, pure, with injected time; every rule gets its unit test first (TDD). App code has no automated tests: anything it does gets a line in `docs/manual-test-checklist.md` and a log line to grep for.
- `docs/functional.md` is replaced, never annotated: a rule this plan changes is rewritten in place in the same commit, with no trace of the old one. `docs/architecture.md`, `docs/macOS.md`, `docs/pitfalls.md` and `docs/manual-test-checklist.md` are updated where the task says so. Comments state the present rule, never the history.
- Verification per task: `swift test` green (count per-case lines: `swift test 2>&1 | grep -E "^Test Case '.*' passed" | sort -u | wc -l`, today 423), then the warning check `DEBUG_OK=1 script/build.sh Debug 2>&1 | grep -E "warning:|error:"` must print nothing but `appintentsmetadataprocessor` lines, then delete the `.app` path that build printed. Both need Claude Code's sandbox off (`dangerouslyDisableSandbox`). Never install, never launch a built app, never send `koffeelid off`, never run `claude` or `codex` (they fire hooks and arm the owner's Mac).
- New log lines are exact strings named in the task; the checklist greps for them. Existing log-line phrasing stays.
- No new user-visible strings are expected; if one is needed it goes through `L("…")` with its `fr` entry in `App/Resources/Localizable.xcstrings`, edited in place.
- Commit per task, staged by path (`git add <paths>`, never `-A`), subject `feat|fix|docs(activity): …`, body ending with the two trailers `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_016xk5oLV2T4JHgQq7zSFNLw`. Work on `main`; do not push.
- `KoffeeLid.xcodeproj` is generated: after adding an App source file run `script/bootstrap.sh`.
- Time constants live in `Sources/KoffeeLidCore/ActivityConstants.swift` with a comment giving the evidence.

## Review Focus

1. A journal line from an older hook (no `turn_id`, no `transcript_path`) must behave exactly as today; Task 1 pins it with `testLinesWithoutATurnIdKeepTodaysRules`.
2. A verdict or a daemon answer must never arm: they only end turns. Task 5 pins it with `testAVerdictForAnUnknownSessionIsIgnored` and the launch order.
3. A rollout or daemon answer for the wrong session, an unreadable file, an unknown status must change nothing; Tasks 3 and 4 pin it with the `…DecidesNothing` tests.
4. A running six-hour build must keep the Mac armed; Task 6 pins it with `testAJobWithAShellIsNeverDroppedByStaleness`.
5. A Codex session hosted by the daemon must survive the launch prune while its turn runs; Task 3 pins it with `testPruneKeepsADaemonHostedSessionForTheCodexCheck`.

---

### Task 1: A closed turn stays closed (turn identity)

**Files:**
- Modify: `Sources/KoffeeLidCore/ActivityEvent.swift` (new field), `Sources/KoffeeLidCore/ActivityTrim.swift` (keep the id), `Sources/KoffeeLidCore/ActivitySessionStore.swift` (session fields, the guard, the close), `Sources/KoffeeLidCore/ActivityConstants.swift` (`abortQuarantineSeconds`)
- Test: `Tests/KoffeeLidCoreTests/ActivitySessionStoreTests.swift`, `Tests/KoffeeLidCoreTests/ActivityTrimTests.swift`, `Tests/KoffeeLidCoreTests/ActivityEventTests.swift`
- Docs: `docs/functional.md` § Auto-arm on activity (the Claude Code and Codex bullets, and "Without an end event"), `docs/architecture.md` § Auto-arm on activity (the state table), `docs/pitfalls.md` § Codex hooks (new trap), `docs/manual-test-checklist.md` § Auto-arm on activity (one line)

**Interfaces:**
- Produces: `ActivityEvent.turnId: String?` (JSON key `turn_id`); `ActivitySession.openTurnId: String?`, `ActivitySession.lastMainTurnId: String?`, `ActivitySession.closedTurnIds: [String]` (the last 8), `ActivitySession.interruptedAt: Date?`; `ActivitySessionStore.turnOver(sessionId:now:)` now also closes the open turn; `ActivityConstants.abortQuarantineSeconds: TimeInterval = 120`.

**The rule (write it into functional.md, replacing the Codex bullet's "until its Stop or its Interrupt" sentence and adding to the Claude Code bullet), as amended by the ledger's rulings A and B:**
Every event of a turn carries the turn's id: Claude Code's `prompt_id`, Codex's `turn_id`. An `Interrupt`, or a verdict that the turn is over (§ Without an end event), closes the turn. A tool or permission event that arrives for a closed turn, as the end of a tool Codex aborted does seconds or minutes later, only proves the hook alive and changes nothing, and so does a helper event of a closed turn. A `Stop` ends the turn but does not close it: a Stop hook that blocks it keeps the turn running, and its later events count. A prompt always opens a turn, whatever id it carries; a turn closed before any prompt was seen closes the last turn id seen. For 120 s after an `Interrupt`, a tool or permission event without a turn id changes nothing either. A line without a turn id otherwise follows the rules above.

**Behaviour, precisely (in `ActivitySessionStore.apply`):**
- `ActivityTrim.event(fromHookPayload:)` sets `turnId` from `turn_id`, else from `prompt_id`, clamped to `metadataMaxChars`.
- Main-agent `UserPromptSubmit`: `openTurnId = e.turnId`, `closedByInterrupt = false`, `interruptedAt = nil`, then today's handling.
- Closing (a private `closeTurn(&s, byInterrupt:, now:)`): if `openTurnId` is non-nil append it to `closedTurnIds` (keep the last 8); `openTurnId = nil`; `closedByInterrupt = byInterrupt`; `interruptedAt = byInterrupt ? now : nil`. Called from `.stop` (after `applyStopVerdict`), `.interrupt`, the `idle_prompt`/`agent_needs_input` lost-Stop path, and `turnOver(sessionId:now:)`.
- Guard, evaluated before the state switch, after `lastEventAt` is refreshed (liveness) and before `lastMainEventAt` is touched: a main-agent event other than `SessionStart`, `SessionEnd`, `UserPromptSubmit` whose `turnId` is in `closedTurnIds` stores the session and returns; a helper event (agent id set) whose `turnId` is in `closedTurnIds` while `closedByInterrupt` is true does the same; a main-agent `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` or `PermissionDenied` with no `turnId`, within `abortQuarantineSeconds` of `interruptedAt`, does the same.
- `SessionEnd` and process exit are unchanged.

- [ ] **Step 1: Write the failing tests** in `ActivitySessionStoreTests` (use the existing `ev(…)` helper, extended with a `turn: String? = nil` parameter that sets `turnId`):
  - `testALatePostToolUseOfAnAbortedCodexTurnDoesNotReopenIt`: Codex session, `userPromptSubmit(turn: "t1")`, `preToolUse(tool: "Bash", turn: "t1")`, `interrupt` at +10 → `.done`, not running; `postToolUse(tool: "Bash", turn: "t1")` at +23 → still `.done`, `lastEventAt` advanced to +23.
  - `testAToolEventOfAClosedTurnRefreshesLivenessOnly`: after a `stop(turn: "t1")` (done), `postToolUse(turn: "t1")` at +30 → `.done`; `lastEventAt` == +30; `lastMainEventAt` unchanged.
  - `testANewPromptOpensANewTurnAfterAnInterrupt`: interrupt of `t1`, then `userPromptSubmit(turn: "t2")` → `.working`; `preToolUse(turn: "t2")` → `.working`.
  - `testAHelperEventOfAnInterruptedTurnIsIgnored`: interrupt of `t1`, helper `preToolUse(agent: "h1", turn: "t1")` → `.done`, `liveAgents` empty.
  - `testAHelperOfAStoppedTurnStillHoldsIt`: `stop(turn: "t1")` with `liveAgents` non-empty → `.working` held; helper event `turn: "t1"` → still held (`pendingDone` true).
  - `testARegistryVerdictClosesTheTurn`: Claude session working with `turn: "p1"`; `turnOver` → `.done`; `postToolUse(turn: "p1")` → `.done`.
  - `testToolEventsWithoutAnIdInTheQuarantineAfterAnInterruptChangeNothing`: interrupt at t, `postToolUse` (no turn) at t+60 → `.done`; at t+121 → `.working` (today's rule again).
  - `testLinesWithoutATurnIdKeepTodaysRules`: the existing sequences with `turn: nil` produce the existing states (copy the assertions of `testToolTrafficIsWorkingAndDialogsAreWaiting`).
  In `ActivityTrimTests`: `testTurnIdIsKeptFromTurnIdOrPromptIdAndClamped` (payload with `turn_id` → kept; with only `prompt_id` → kept; both → `turn_id` wins; 300 chars → 200). In `ActivityEventTests`: the round trip of a line with `turn_id`.
- [ ] **Step 2: Run** `swift test --filter ActivitySessionStoreTests` → the new tests fail to compile or fail.
- [ ] **Step 3: Implement** the fields, the trim, `closeTurn`, the guard, the constant (comment: "Codex reported a tool's end 13 s after the abort on 2026-09-25; 120 s covers a process that ignores SIGTERM").
- [ ] **Step 4: Run** `swift test` → all green, count rises by the new tests.
- [ ] **Step 5: Docs.** functional.md as above; architecture.md table gains the row "`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied` of a closed turn | unchanged (liveness only)"; pitfalls.md § Codex hooks gains "### Codex reports a tool's end after the turn was aborted" (symptom: a session working after Ctrl+C until Codex is quit; why: the aborted process ends later and `PostToolUse` fires for it, and `Stop` runs only on completion; what the code does: the turn id); checklist line: "Ctrl-C a Codex turn while its `sleep 60` runs → `Interrupt`, then a `PostToolUse` within a minute → `koffeelid status` stays at `0 sessions working`".
- [ ] **Step 6: Warning check, then commit** `fix(activity): a closed turn stays closed, whatever event arrives for it later`.

### Task 2: A compaction keeps the state it found

**Files:**
- Modify: `Sources/KoffeeLidCore/ActivitySessionStore.swift`
- Test: `Tests/KoffeeLidCoreTests/ActivitySessionStoreTests.swift` (replace `testCompactionIsWorking`)
- Docs: `docs/functional.md` § Auto-arm (a sentence in the Claude Code bullet), `docs/architecture.md` (the `SessionStart` and `PreCompact`/`PostCompact` rows), `docs/manual-test-checklist.md` (one line)

**Interfaces:** Produces `ActivitySession.stateBeforeCompaction: ActivitySessionState?`.

**The rule:** A compaction is work while it runs: `PreCompact` makes the session working and `PostCompact` puts it back to the state it had before, so a compaction inside a turn leaves it working and one at the prompt leaves it idle or finished. A `SessionStart` of source `compact` changes no state (helpers and background ids are kept, as today).

**Behaviour:** `.preCompact`: `stateBeforeCompaction = s.state`, then `set(.working)`. `.sessionStart` with source `compact`: no `set` call. `.postCompact`: `set(&s, stateBeforeCompaction ?? .working, now)`, `stateBeforeCompaction = nil`. Restoring `.done` resets `stateSince` (acceptable: `done` shows 20 min longer).

- [ ] **Step 1: Tests.** `testCompactionKeepsTheStateItFound`: idle → `preCompact` working → `sessionStart(compact)` working → `postCompact` idle; from `done` (after a stop) → working during → done after; from working (mid-turn) → working throughout. `testACompactSessionStartAloneChangesNothing`: idle session, `sessionStart(compact)` → idle. Delete `testCompactionIsWorking`.
- [ ] **Step 2: Run** → fail. **Step 3: Implement.** **Step 4: Run** `swift test` → green.
- [ ] **Step 5: Docs** as listed; checklist line: "`/compact` at the prompt with the Mac idle → `armed (activity` during the compaction, `activity: idle` at `PostCompact`, no registry verdict needed".
- [ ] **Step 6: Warning check, commit** `fix(activity): a compaction keeps the state it found`.

### Task 3: Codex's rollout as its transcript, and the daemon pid told apart

**Files:**
- Create: `Sources/KoffeeLidCore/CodexRolloutTail.swift`, `App/Sources/CodexRollout.swift`, `Tests/KoffeeLidCoreTests/CodexRolloutTailTests.swift`
- Modify: `Sources/KoffeeLidCore/ActivityEvent.swift` (`transcriptPath`), `ActivityTrim.swift` (keep it on `SessionStart`, `UserPromptSubmit`, `Stop`, `Interrupt`, clamped to `ActivityConstants.pathMaxChars = 1024`), `ActivitySessionStore.swift` (`transcriptPath`, `codexCandidates(at:)`, `nextDeadline` for Codex), `ProcWalk.swift` (`isCodexDaemon`), `ActivityConstants.swift`, `App/Sources/ActivityMonitor.swift` (`checkCodex`), `Tests/KoffeeLidCoreTests/ProcWalkTests.swift`, `ActivitySessionStoreTests.swift`
- Docs: `docs/functional.md` § Auto-arm "Without an end event" (rewrite the Codex sentences), `docs/macOS.md` § Codex (the daemon, the rollout, `turn_id`, lazy `SessionStart`, `SessionEnd` reason `other`; replace "its parent is the `codex` process itself" and "what a lost `Stop` costs Claude Code, Codex covers with `Interrupt` and `SessionEnd`"), `docs/pitfalls.md` § Codex hooks ("### The daemon outlives every TUI, so the pid proves nothing"), `docs/architecture.md` § Auto-arm (the rollout check beside the registry; `CodexRollout` in the diagram), `docs/manual-test-checklist.md` (two lines)

**Interfaces:**
- Produces: `CodexRolloutTail.Verdict` = `.running(turnId: String?) | .complete(at: Date) | .aborted(at: Date) | .unreadable`; `CodexRolloutTail.verdict(tail: Data) -> Verdict`; `CodexRolloutTail.tailBytes = 65_536`; `CodexRollout.read(path: String) -> Data?` (the last `tailBytes` of the file); `CodexRollout.locate(sessionId: String) -> String?` (glob `~/.codex/sessions/*/*/*/rollout-*-<sessionId>.jsonl`, newest); `ActivitySessionStore.codexCandidates(at:quietSeconds:) -> [(sessionId: String, transcriptPath: String?)]`; `ProcWalk.isCodexDaemon(_ info: ProcInfo) -> Bool`; `ActivitySession.hostedByDaemon: Bool` (set when the line's pid is the daemon, read at launch).

**The rules (functional.md, "Without an end event", the Codex part):** A Codex session hosted by the TUI is hosted by Codex's managed daemon, one per user, alive across every TUI: the pid its hooks record is the daemon's, so only the daemon's death drops its sessions. Every Codex hook names the session's rollout file (`transcript_path`), and a working Codex session quiet for 20 s with nothing out is checked against it every 15 s and once at launch: a `task_complete` or `turn_aborted` stamped after the last main-agent event ends the turn, however it ended; a `task_started` with no end keeps it alive; a rollout that cannot be read decides nothing. `codex exec` and the desktop app record their own process, and their death drops their sessions.

**Parser:** JSON lines; a first line cut by the 64 KB window is skipped; only lines with `type == "event_msg"` and `payload.type` in `task_started`, `task_complete`, `turn_aborted` are markers; the last marker wins; `item_completed`, `token_count`, `thread_settings_applied` are not markers; `timestamp` is ISO 8601 with milliseconds (`ActivityCodec.isoMs`); `turn_id` from `payload.turn_id`. No marker at all → `.unreadable`.

**Monitor:** `checkCodex(now:atLaunch:)` beside `checkRegistry`: candidates are Codex sessions `.working`, not `pendingDone`, no live helpers, no background ids, quiet ≥ `abandonQuietSeconds` (0 at launch). Read `transcriptPath` or `locate(sessionId)`; `.complete(at)` / `.aborted(at)` with `at > lastMainEventAt` → log `activity: quiet Codex turn <sid8> — rollout says <finished|aborted>, turn over` and `sessions.turnOver`; `.running` → `noteBusy` (and the existing 5 min `hooks look dead` warning applies); `.unreadable` → log once per session `activity: no rollout for Codex session <sid8>; only staleness can end it`. `nextDeadline` schedules Codex working sessions like Claude ones (the `abandonQuietSeconds` / `abandonRecheckSeconds` lines, without the pid condition). `start()` calls `checkCodex(now:atLaunch: true)` after `pruneDead` and before the first `sync()`.

**Daemon pid:** `ProcWalk.isCodexDaemon(info)`: the exec args (`procArgs`) contain `app-server`, or the path contains `/app-server-daemon/`. `ActivityMonitor` marks a session `hostedByDaemon` when its pid is the daemon; `pruneDead` keeps such a session (the daemon is alive) and the launch `checkCodex` decides it. Nothing else changes for the kqueue (the daemon's own death still drops every TUI session).

- [ ] **Step 1: Tests.** `CodexRolloutTailTests` with hand-written fixtures mirroring the real rollout shapes (types and timestamps only, no content): `testATurnAbortedAfterOurLastEventEndsTheTurn`, `testATaskCompleteIsAFinish`, `testAStrayItemCompletedAfterTheAbortIsNotATurnMarker`, `testTaskStartedWithoutAnEndIsStillRunning`, `testAnUnreadableOrTruncatedTailDecidesNothing`, `testACutFirstLineIsSkipped`. Store: `testAQuietCodexSessionIsACandidateAndAClaudeOneIsNot`, `testNextDeadlineCoversTheCodexRecheck`, `testPruneKeepsADaemonHostedSessionForTheCodexCheck`. `ProcWalkTests.testTheManagedDaemonIsRecognisedByItsArguments`. `ActivityTrimTests`: `transcript_path` kept on the four events, dropped on `PreToolUse`.
- [ ] **Step 2: Run** → fail. **Step 3: Implement** Core, then the App reader and monitor; `script/bootstrap.sh` after adding `App/Sources/CodexRollout.swift`. **Step 4:** `swift test` green.
- [ ] **Step 5: Docs** as listed. Checklist lines: "Interrupt a Codex turn with the KoffeeLid hooks switched off in Codex's `/hooks` (nothing arrives) → within ~35 s `activity: quiet Codex turn … — rollout says aborted, turn over`"; "Quit the app during a Codex turn, relaunch → `replayed …` then `activity: running (… Codex 1 …)` and no `turn over` while the turn runs".
- [ ] **Step 6: Warning check, commit** `feat(activity): a quiet Codex turn is checked against its rollout, and the daemon pid proves nothing`.

### Task 4: Ask the daemon (`thread/read`)

**Files:**
- Create: `Sources/KoffeeLidCore/WebSocketFrame.swift`, `Sources/KoffeeLidCore/CodexThreadRecord.swift`, `App/Sources/CodexDaemonClient.swift`, `Tests/KoffeeLidCoreTests/WebSocketFrameTests.swift`, `Tests/KoffeeLidCoreTests/CodexThreadRecordTests.swift`
- Modify: `App/Sources/ActivityMonitor.swift` (`checkCodex` asks the daemon first), `docs/functional.md`, `docs/macOS.md` § Codex (the socket), `docs/pitfalls.md` (protocol coupling), `docs/architecture.md`, `docs/manual-test-checklist.md`

**Interfaces:**
- Produces: `WebSocketFrame.encodeText(_ text: String) -> Data` (a masked client text frame, lengths up to 65 535), `WebSocketFrame.decode(_ data: Data) -> (payload: Data, consumed: Int)?` (server frames: unmasked, opcodes text and binary, 7/16/64-bit lengths; a fragment shorter than its length → nil); `CodexThreadRecord.parse(_ data: Data) -> CodexThreadRecord?` with `status: String`, `updatedAt: Date?`, `rolloutPath: String?`; `CodexThreadRecord.Verdict` = `.over | .busy | .undecided`; `record.verdict(lastMainEventAt:)`: `notLoaded` → `.over`; `active` → `.busy`; `idle` → `.over`; anything else → `.undecided`; `CodexDaemonClient.readThread(id:completion:)` and `CodexDaemonClient.loadedThreadIds(completion:)`, both completing on main within 1 s or with nil.

**Protocol (from the read-only probe on 2026-09-25, Codex 0.157):** the control socket is `~/.codex/app-server-control/app-server-control.sock` (a symlink; resolve it). Over a `PF_LOCAL` stream: an HTTP/1.1 `GET / HTTP/1.1` upgrade with `Host: localhost`, `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key` (16 random bytes, base64), `Sec-WebSocket-Version: 13`; the daemon answers `101`. Then JSON-RPC 2.0 text frames: `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"KoffeeLid","title":"KoffeeLid","version":"<app version>"}}}`, the reply carries `result.userAgent`; then the notification `{"jsonrpc":"2.0","method":"initialized"}`; then `{"jsonrpc":"2.0","id":2,"method":"thread/read","params":{"threadId":"<session id>","includeTurns":false}}` whose `result.thread.status.type` is the status and `result.thread.path` the rollout; or `{"jsonrpc":"2.0","id":2,"method":"thread/loaded/list","params":{}}` whose `result.data` is a list of threads with `id`. Every call has a 1 s overall deadline; any refusal, timeout or malformed answer is nil and is logged once per launch as `activity: Codex daemon not answering; using the rollout`. Never call any other method.

**Monitor:** in `checkCodex`, for each candidate: if the socket path exists, `readThread`; `.over` → log `activity: Codex daemon says thread <sid8> has nothing running, turn over` and `turnOver`; `.busy` → `noteBusy`; `.undecided` or nil → the rollout path of Task 3. At launch, `loadedThreadIds`: a working Codex session whose id is not loaded → `turnOver` with the log `activity: Codex daemon has not loaded thread <sid8>, turn over`; an answer of nil leaves the rollout check to decide. All socket I/O on a utility queue; completions hop to main.

- [ ] **Step 1: Tests.** `WebSocketFrameTests`: `testAClientTextFrameIsMaskedAndFramed` (decode our own frame after unmasking; lengths 5, 200, 70 000 → 7-, 16-, 64-bit), `testAServerTextFrameDecodes`, `testAShortFragmentDecodesToNil`. `CodexThreadRecordTests`: `testNotLoadedMeansNothingRuns`, `testAnActiveThreadIsBusy`, `testAnUnknownStatusDecidesNothing`, `testTheRecordCarriesTheRolloutPath` (fixture shaped like `{"result":{"thread":{"id":"…","status":{"type":"notLoaded"},"path":"/…/rollout-….jsonl","updatedAt":"2026-09-25T19:20:43.962Z"}}}`).
- [ ] **Step 2: Run** → fail. **Step 3: Implement**; `script/bootstrap.sh`. **Step 4:** `swift test` green.
- [ ] **Step 5: Docs.** functional.md adds one sentence to the Codex paragraph of "Without an end event": "When Codex's daemon is running, it is asked first (`thread/read`): a thread it has not loaded, or has idle, has nothing running; an active one keeps the session alive; the rollout decides when the daemon does not answer." macOS.md § Codex documents the socket and the three methods. pitfalls.md: "### The daemon's protocol is undocumented and versioned" (what the code does: fail closed, three methods, 1 s). Checklist: "With a Codex TUI at its prompt, mid-turn, and after quitting, the log's `Codex daemon says …` lines match the state; with the daemon stopped (`codex app-server daemon stop` or after a reboot before any Codex start) the rollout path takes over".
- [ ] **Step 6: Warning check, commit** `feat(activity): Codex's daemon is asked whether a quiet thread still runs`.

### Task 5: Claude Code: the registry from the transcript path, verdicts that survive a relaunch, an honest prune

**Files:**
- Modify: `Sources/KoffeeLidCore/ClaudeRegistryRecord.swift` (`configDir(fromTranscriptPath:)`), `ActivityEvent.swift` (`.verdict = "KoffeeLidVerdict"`, `verdict: String?` key `verdict`), `ActivitySessionStore.swift` (apply a verdict line; `pruneDead` with a registry closure; `abandonCandidates(at:quietSeconds:)`), `App/Sources/ClaudeProcessRegistry.swift` (`read(pid:configDir:)`), `App/Sources/ActivityMonitor.swift` (derive the dir; append verdict lines; check at launch; prune by the record), `Tests/KoffeeLidCoreTests/ClaudeRegistryRecordTests.swift` (create if absent), `ActivitySessionStoreTests.swift`, `ActivityEventTests.swift`
- Docs: `docs/functional.md` § Auto-arm "Without an end event" (Claude Code part), `docs/macOS.md` § Claude Code (the config dir from the transcript path; `prompt_id`), `docs/pitfalls.md` § "Another process's environment cannot be read" (what the code does now), `docs/architecture.md` (the verdict line; launch order), `docs/manual-test-checklist.md` (two lines)

**Interfaces:**
- Produces: `ClaudeRegistryRecord.configDir(fromTranscriptPath: String) -> URL?` (`…/projects/<slug>/<file>.jsonl` → the directory two levels above `projects`' child, i.e. the parent of `projects`; nil when no `projects` component); `ActivityEventName.verdict`; `ActivityEvent.verdict` with the values `"turn-over"` and `"dialog-answered"`; `ActivitySessionStore.pruneDead(isAlive: (Int32, ActivityAgent) -> Bool, registrySession: (Int32) -> String?)`.

**The rules (functional.md):** The registry is found from the session's transcript path (`<config>/projects/…`), so a relocated `CLAUDE_CONFIG_DIR` is found; `~/.claude` is the fallback. The app records its own verdicts (turn over, dialog answered) in the journal, so a relaunch replays them; at launch the registry and the rollouts are read before the first arm, and a session already over is never counted. A replayed session is kept only while its pid is alive, runs its agent and, when a registry record exists for the pid, names the same session.

**Behaviour:** `checkRegistry` derives the dir from `session.transcriptPath` (kept since Task 3), falling back to `~/.claude`; after `turnOver` / `dialogAnswered` it appends a verdict line (`ActivityJournalWriter.append`, session id, verdict, `loggedAt` now). The store applies a verdict line: unknown session → ignored; `loggedAt` older than `lastMainEventAt` → ignored; `turn-over` → `turnOver`; `dialog-answered` → `dialogAnswered`; a verdict never creates a session and never refreshes `lastEventAt`. The tailer delivers the app's own line back; both paths are idempotent. `start()`: replay → `pruneDead` (registry closure reads `~/.claude/sessions/<pid>.json` or the transcript-derived dir; returns its `sessionId`) → `checkRegistry(now:, quietSeconds: 0)` → `checkCodex(atLaunch:)` → first `sync()`.

- [ ] **Step 1: Tests.** `ClaudeRegistryRecordTests.testConfigDirIsDerivedFromTheTranscriptPath` (`/Users/x/.claude/projects/-Users-x-p/abc.jsonl` → `/Users/x/.claude`; `/tmp/cfg/projects/s/a.jsonl` → `/tmp/cfg`; `/tmp/a.jsonl` → nil). Store: `testAJournaledVerdictReplaysAsTheSameVerdict`, `testAVerdictForAnUnknownSessionIsIgnored`, `testAVerdictOlderThanTheLastMainEventIsIgnored`, `testPruneDropsAPidWhoseRegistryNamesAnotherSession`, `testAbandonCandidatesAtLaunchIgnoreTheQuietGate`. `ActivityEventTests`: the verdict line round trip; an older reader's behaviour is not testable here (note it in the docs: unknown names are skipped by `ActivityCodec.decodeLine`, which returns nil).
- [ ] **Step 2: Run** → fail. **Step 3: Implement.** **Step 4:** `swift test` green.
- [ ] **Step 5: Docs.** Checklist: "Under cswap (`CLAUDE_CONFIG_DIR` set), Ctrl-C a turn → `turn over` within 35 s and no `no registry record`"; "Ctrl-C a turn, wait for `turn over`, quit and reopen the app within 10 s → `replayed …` followed by no `armed (activity`".
- [ ] **Step 6: Warning check, commit** `feat(activity): the registry is found from the transcript, verdicts survive a relaunch, and the prune reads the record`.

### Task 6: Terminal jobs: the snippet, and a shell asked whether it still runs a command

**Files:**
- Create: `Sources/KoffeeLidCore/ShellJobLiveness.swift`, `Tests/KoffeeLidCoreTests/ShellJobLivenessTests.swift`
- Modify: `Sources/KoffeeLidCore/ShellInit.swift` (the template), `ActivityJobStore.swift` (`promptSeenAt`, `probe`, staleness only for pid-less jobs), `ActivityConstants.swift` (`jobProbeSeconds = 15`, `jobPromptSettleSeconds = 5`), `ProcWalk.swift` (`ProcInfo.pgid`, `ProcInfo.tpgid`, `ProcInfo.isShell`, `ProcWalk.hasChildren(pid:)`), `App/Sources/ActivityMonitor.swift` (probe every 15 s while a job with a pid exists, and once at replay), `Tests/KoffeeLidCoreTests/ShellInitTests.swift`, `ActivityJobStoreTests.swift`, `ProcWalkTests.swift`
- Docs: `docs/functional.md` § Auto-arm (the Terminal bullet and the job sentence of "Without an end event"), `docs/macOS.md` § zsh (the foreground process group fact; re-sourcing), `docs/pitfalls.md` § Claude Code hooks and the shell (two traps: "`exec zsh` and `source ~/.zshrc` end the running job"; "a shell at its prompt is the truth about a job, not the journal"), `docs/manual-test-checklist.md` (the lines below)

**Interfaces:**
- Produces: `ShellJobLiveness.Probe(alive: Bool, isShell: Bool, atPrompt: Bool, hasChildren: Bool)`; `ShellJobLiveness.Verdict` = `.keep | .drop(reason: String)`; `ShellJobLiveness.judge(_ probe: Probe, promptSeenAt: inout Date?, now: Date) -> Verdict`; `ActivityJobStore.probe(id: String, _ probe: ShellJobLiveness.Probe, now: Date) -> String?` (the drop reason when dropped); `ProcInfo.isShell` (p_comm, with a leading `-` stripped, in `zsh`, `bash`, `sh`, `fish`, `dash`, `ksh`, `tcsh`).

**The rules (functional.md, Terminal bullet):** A shell that re-reads the snippet, or is replaced by `exec`, ends the job it was running; the snippet releases the shell's slot when it loads. Prefixes (`sudo` and its flags, `time`, `command`, `builtin`, `exec`, `nice`, `nohup`, `env`, `noglob`, `caffeinate`) and leading `VAR=value` words are skipped before the program's name is read, and `zsh`, `bash`, `sh`, `fish`, `su`, `login`, `tig`, `lazygit` never count. While a command counts, its shell is asked every 15 s whether it still runs one: a shell gone ends the job at once (kqueue); a shell back at its prompt with no child for 5 s ends it, the end having been lost; a shell replaced by its program is kept until that program exits; a job without a shell pid is dropped after 2 h.

**Snippet changes:** `(( ${+_koffeelid_job} )) || typeset -g _koffeelid_job=`; after the functions are defined and before `add-zsh-hook`: `[[ -o interactive ]] && '@KOFFEELID_HOOK@' job end --id zsh-$$ >/dev/null 2>&1`; in `_koffeelid_preexec`, when collecting a segment's head, skip words matching `[A-Za-z_][A-Za-z0-9_]*=*` and the prefix list (for `sudo`, also its following `-`-flags), take the next word as the head; the default skip list gains `zsh bash sh fish su login tig lazygit`. (The `job end` verb for an unknown id is already a no-op in the store.)

**Liveness rule (`ShellJobLiveness.judge`):** `!alive` → `.drop("shell gone")`; `!isShell` → `.keep` (promptSeenAt = nil); `atPrompt && !hasChildren` → if `promptSeenAt == nil` set it to now and `.keep`, else if `now - promptSeenAt >= jobPromptSettleSeconds` → `.drop("shell at its prompt")`, else `.keep`; otherwise `promptSeenAt = nil`, `.keep`. `atPrompt` is `tpgid == pgid` read from `kinfo_proc.kp_eproc.e_tpgid` and `e_pgid`; `hasChildren` from `proc_listchildpids`. Staleness: `tick` drops a job after `jobStaleSeconds` only when `ownerPid == nil`.

**Monitor:** while any job has an `ownerPid`, `nextDeadline` includes `now + jobProbeSeconds`; `sync()` probes every such job (`ProcWalk.isAlive`, `ProcWalk.info`, `hasChildren`) and logs `activity: job <id> ended without a hook (<reason>)` when the store drops it; at replay the same probe runs once before the first publish (a recycled pid that is not a shell, or a shell at its prompt, is dropped after the 5 s settle by the next tick).

- [ ] **Step 1: Tests.** `ShellInitTests` (real zsh, stub hook, the existing harness): `testResourcingTheSnippetKeepsTheRunningJob` (`source init.zsh` again, then `true` → every `job begin` has its `job end`, and the load emitted `job end --id zsh-<pid>`), `testTheLoadReleasesTheShellsSlot` (the first call after sourcing in an interactive shell is `job end --id zsh-<pid>`), `testPrefixesAreSkippedBeforeTheHead` (`sudo -n vim`, `FOO=1 vim`, `time vim`, `env vim` → no `job begin`; `sudo make` → a begin labelled `make`), `testInteractiveShellsNeverCount` (`zsh -c true`? no: `bash -c true` and `zsh -f -c true` → no calls). `ShellJobLivenessTests`: the table (gone → drop; not a shell → keep; at prompt, no children, first probe → keep, second probe 5 s later → drop, second probe 4 s later → keep; at prompt with children → keep and the timer resets; running a foreground command → keep). `ActivityJobStoreTests`: `testAJobWithAShellIsNeverDroppedByStaleness` (3 h old job with a pid survives `tick`; one without a pid does not), `testAProbeThatFindsTheShellAtItsPromptDropsTheJob`. `ProcWalkTests.testShellNamesAreRecognisedWithALoginDash`.
- [ ] **Step 2: Run** → fail. **Step 3: Implement.** **Step 4:** `swift test` green.
- [ ] **Step 5: Docs.** Checklist lines: "`exec zsh`, wait 10 s → no `activity: running`"; "`source ~/.zshrc` idem"; "`sleep 300` then close the tab → `activity: idle` at once"; "`sleep 7300` → still armed after 2 h"; "`sleep 300`, Ctrl-Z, `fg` → armed again 5 s after `fg`"; "`sudo -n vim` → never arms"; "kill the app during a `sleep 300`, relaunch → `replayed … 1 jobs`, armed, ends with the sleep".
- [ ] **Step 6: Warning check, commit** `fix(activity): a shell that re-reads the snippet ends its job, and a job's shell is asked whether it still runs a command`.
