# Agent hooks and the shell — traps koffeelid and my-sidepulse share

The traps of the activity feature, paid for once and kept here beside the contract (`activity-detection.md`).
Synced only to the apps in `family-activity.txt`: the others have no hooks and no journal.


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
