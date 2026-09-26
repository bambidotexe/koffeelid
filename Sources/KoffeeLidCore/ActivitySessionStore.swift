import Foundation

public enum ActivitySessionState: Equatable { case idle, working, waiting, done }

/// One agent session: Claude Code's, Codex's, Copilot's or OpenCode's. Only `.working` counts as running.
public struct ActivitySession: Equatable {
    public var id: String
    public var agent: ActivityAgent = .claude
    public var state: ActivitySessionState = .idle
    public var stateSince: Date
    public var lastEventAt: Date
    /// Last MAIN-agent event (not a helper's, not a Notification): what "the turn has gone quiet" is measured against.
    public var lastMainEventAt: Date
    /// The agent process hosting the session.
    public var agentPid: Int32?
    /// The pid is a shared Codex host (`ProcWalk.isSharedCodexHost`: the managed daemon or the desktop app's
    /// `codex`), which hosts many sessions and outlives them: alive, it proves nothing about this session.
    /// Set by `markCodexHosts`.
    public var hostedBySharedCodex = false
    /// The pid is Codex's managed daemon, the one host whose control socket is asked about the session's
    /// thread. Set by `markCodexHosts`; implies `hostedBySharedCodex`.
    public var hostedByManagedDaemon = false
    /// The session's transcript file, from the last main-agent line that named one: Claude Code's
    /// conversation, Codex's rollout, Copilot's `events.jsonl`.
    public var transcriptPath: String?
    /// Helpers believed running, each with its last-seen time; there is no reliable end event.
    public var liveAgents: [String: Date] = [:]
    public var backgroundIds: Set<String> = []
    /// A `done` deferred because helpers or background shells were still out.
    public var pendingDone = false
    public var holdReleasedAt: Date?
    public var waitingFromAgent = false
    /// The turn the last main-agent event carrying an id named, a prompt included: the turn a close records.
    public var lastMainTurnId: String?
    /// The last `ActivitySessionStore.closedTurnsKept` turns closed by an Interrupt or a verdict.
    public var closedTurnIds: [String] = []
    /// The ids in `closedTurnIds` an `Interrupt` closed: only a prompt opens one of them again. A turn a verdict
    /// closed is opened again by a prompt or by a main-agent `PreToolUse`.
    public var interruptedTurnIds: Set<String> = []
    /// When the last turn was closed by an `Interrupt`; starts the quarantine for lines without a turn id.
    public var interruptedAt: Date?
    /// The state the first `PreCompact` since the last turn boundary found the session in: `PostCompact`
    /// restores it, and a prompt, a `Stop`, an `Interrupt` or a `SessionStart` not from a compaction forgets
    /// it. A compaction is work while it runs and changes nothing once it ends.
    public var stateBeforeCompaction: ActivitySessionState?

    public init(id: String, at now: Date) { self.id = id; stateSince = now; lastEventAt = now; lastMainEventAt = now }

    public func hasLiveHelpers(at now: Date) -> Bool {
        liveAgents.values.contains { now.timeIntervalSince($0) < ActivityConstants.agentStaleSeconds }
    }
    public func helperExpiry(after now: Date) -> Date? {
        guard hasLiveHelpers(at: now), let last = liveAgents.values.max() else { return nil }
        return last.addingTimeInterval(ActivityConstants.agentStaleSeconds)
    }
}

/// The per-session state machine. Pure: driven by event timestamps and explicit `tick(now:)`,
/// so journal replay and live events share one path.
public struct ActivitySessionStore {
    public private(set) var sessions: [String: ActivitySession] = [:]
    public init() {}

    /// The tools whose call is a question to the user: Claude Code's `AskUserQuestion` and `ExitPlanMode`,
    /// Codex's `request_user_input`. A session inside one is waiting, not working.
    public static let dialogTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "request_user_input"]

    public var isRunning: Bool { sessions.values.contains { $0.state == .working } }
    public var workingCount: Int { sessions.values.filter { $0.state == .working }.count }
    public func workingCount(of agent: ActivityAgent) -> Int { sessions.values.filter { $0.state == .working && $0.agent == agent }.count }
    public var trackedPids: Set<Int32> { Set(sessions.values.compactMap(\.agentPid)) }

    public mutating func apply(_ e: ActivityEvent) {
        if e.event == .verdict { applyVerdict(e); return }
        let agent = e.effectiveAgent
        guard ActivityEventName.hookEvents(for: agent).contains(e.event), let sid = e.sessionId else { return }
        let now = e.loggedAt
        if e.event == .sessionEnd { sessions.removeValue(forKey: sid); return }
        // A helper's own end naming a session the store never heard of tells nothing about it: it must not
        // conjure one into existence.
        if sessions[sid] == nil, e.agentId != nil, e.event == .subagentStop { return }
        var s = sessions[sid] ?? ActivitySession(id: sid, at: now)
        s.agent = agent
        s.lastEventAt = now
        if let pid = e.agentPid { s.agentPid = pid }
        // Copilot starts a session lazily, with its first prompt and after it: its SessionStart says nothing
        // about the turn and records only what it carries.
        if agent == .copilot, e.event == .sessionStart {
            if let path = e.transcriptPath { s.transcriptPath = path }
            sessions[sid] = s; return
        }
        if Self.changesNothing(e, in: s) { sessions[sid] = s; return } // liveness only

        if let agentId = e.agentId {
            // Helper events maintain the registry and never speak for the main agent — except that a helper
            // blocked on a permission blocks the whole turn, and a helper active after `done` re-opens it.
            switch e.event {
            case .subagentStop: s.liveAgents.removeValue(forKey: agentId)
            case .permissionRequest:
                s.liveAgents[agentId] = now; clearPending(&s); set(&s, .waiting, now, fromAgent: true)
            default:
                s.liveAgents[agentId] = now
                if s.state == .waiting, s.waitingFromAgent { set(&s, .working, now) }
                else if s.state == .done { s.pendingDone = true; set(&s, .working, now) }
            }
            updateHoldRelease(&s, now: now); sessions[sid] = s; return
        }

        // Below the helper return on purpose: the snapshot belongs to the main agent.
        if let bg = e.backgroundTaskIds { s.backgroundIds = Set(bg) }
        if e.event != .notification { s.lastMainEventAt = now }

        if let turn = e.turnId { s.lastMainTurnId = turn }
        if let path = e.transcriptPath { s.transcriptPath = path }
        if e.event == .userPromptSubmit { reopen(&s, e.turnId); s.interruptedAt = nil }
        // `changesNothing` let it through: its turn is open, or a verdict closed it.
        if e.event == .preToolUse { reopen(&s, e.turnId) }

        // A turn boundary forgets a compaction's snapshot: a PostCompact lost, or set aside with its closed turn,
        // must not hand a later compaction the state an earlier one found.
        if [.userPromptSubmit, .stop, .interrupt].contains(e.event) || (e.event == .sessionStart && e.source != "compact") {
            s.stateBeforeCompaction = nil
        }

        switch e.event {
        case .sessionStart:
            // Compaction changes no state (helpers and background ids are kept too): a compaction inside a
            // turn stays working, one at the prompt stays idle or finished; PostCompact restores it either way.
            guard e.source != "compact" else { break }
            s.liveAgents.removeAll(); s.backgroundIds.removeAll()
            clearPending(&s); set(&s, .idle, now)
        case .userPromptSubmit, .postToolUse, .postToolUseFailure, .permissionDenied:
            clearPending(&s); set(&s, .working, now)
        case .preCompact:
            // A compaction is work while it runs: PostCompact puts the session back to what this remembers. The
            // first PreCompact since the last turn boundary remembers; a second one would remember its working.
            if s.stateBeforeCompaction == nil { s.stateBeforeCompaction = s.state }
            clearPending(&s); set(&s, .working, now)
        case .postCompact:
            let restored = s.stateBeforeCompaction ?? .working
            s.stateBeforeCompaction = nil
            set(&s, restored, now)
        case .preToolUse:
            clearPending(&s)
            set(&s, e.toolName.map(Self.dialogTools.contains) ?? false ? .waiting : .working, now)
        case .permissionRequest, .stopFailure:
            clearPending(&s); set(&s, .waiting, now)
        case .notification:
            switch e.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog":
                if s.state != .waiting { clearPending(&s); set(&s, .waiting, now) }
            case "idle_prompt", "agent_needs_input":
                // A timer, not a request. Its one use: the machine still believes the turn runs, so the Stop was lost.
                guard s.state == .working, !s.pendingDone,
                      now.timeIntervalSince(s.lastMainEventAt) >= ActivityConstants.idleSignalMinQuietSeconds else { break }
                applyStopVerdict(&s, now: now)
            default: break
            }
        case .stop:
            // Ends the turn without closing it: a Stop hook that blocks the Stop keeps the same turn running.
            clearPending(&s); applyStopVerdict(&s, now: now)
        case .interrupt:
            // Esc in Codex, or OpenCode's own interrupt, ends the turn and its helpers at once, idle: nothing
            // is left out to hold it, and a straggler with no turn id (OpenCode's helper lines carry none)
            // finds the session idle, not done, so it cannot re-open it as working.
            s.liveAgents.removeAll(); s.backgroundIds.removeAll(); clearPending(&s); set(&s, .idle, now)
            closeTurn(&s, byInterrupt: true, now: now)
        case .sessionEnd, .subagentStart, .subagentStop, .parseError, .jobBegin, .jobEnd, .verdict:
            break // handled above, or helper shapes without agent_id, which carry no signal
        }
        updateHoldRelease(&s, now: now)
        sessions[sid] = s
    }

    /// The app's own verdict, replayed or handed back by the tailer after it was applied live: it applies the same
    /// rescue at the same stamp, so the replay reproduces the session, and a second application changes nothing.
    /// It never creates a session and never refreshes `lastEventAt`; one stamped before the session's last
    /// main-agent event was overtaken by that event and changes nothing.
    private mutating func applyVerdict(_ e: ActivityEvent) {
        guard let sid = e.sessionId, let s = sessions[sid], e.loggedAt >= s.lastMainEventAt,
              let verdict = e.verdict.flatMap(ActivityVerdict.init(rawValue:)) else { return }
        switch verdict {
        case .turnOver: turnOver(sessionId: sid, now: e.loggedAt)
        case .dialogAnswered: dialogAnswered(sessionId: sid, now: e.loggedAt)
        }
    }

    /// How many closed turns a session remembers: a late line names the turn just closed, seldom an older one.
    static let closedTurnsKept = 8
    /// The tool and permission events a tool Codex aborted can still send after the turn closed.
    static let lateToolEvents: Set<ActivityEventName> = [.preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest, .permissionDenied]

    /// An event that only proves the hook alive: a main-agent event of a closed turn (a prompt or a start always
    /// counts; `apply` removes the session at an end before asking; a `PreToolUse` counts when a verdict, not an
    /// `Interrupt`, closed the turn), a helper event of a closed turn, or a main-agent tool or permission event
    /// without a turn id inside the quarantine after an `Interrupt`.
    static func changesNothing(_ e: ActivityEvent, in s: ActivitySession) -> Bool {
        let ofClosedTurn = e.turnId.map(s.closedTurnIds.contains) ?? false
        if e.agentId != nil { return ofClosedTurn }
        if [.sessionStart, .userPromptSubmit].contains(e.event) { return false }
        // A new tool call is never an aborted tool's straggler, and a verdict can close a turn that waits on a
        // dialog whose hook lines were lost: its next tool call is the turn at work.
        if ofClosedTurn { return e.event != .preToolUse || e.turnId.map(s.interruptedTurnIds.contains) ?? false }
        guard e.turnId == nil, lateToolEvents.contains(e.event), let interruptedAt = s.interruptedAt else { return false }
        return e.loggedAt.timeIntervalSince(interruptedAt) < ActivityConstants.abortQuarantineSeconds
    }
    /// An Interrupt or a verdict that the turn is over closes the turn the last main-agent event carrying an id
    /// named (an Interrupt's own id among them). A prompt of that id opens it again, and so does a main-agent
    /// `PreToolUse` of it when a verdict closed it.
    private func closeTurn(_ s: inout ActivitySession, byInterrupt: Bool, now: Date) {
        if let turn = s.lastMainTurnId {
            if !s.closedTurnIds.contains(turn) { s.closedTurnIds.append(turn) }
            if byInterrupt { s.interruptedTurnIds.insert(turn) }
            if s.closedTurnIds.count > Self.closedTurnsKept {
                s.closedTurnIds.removeFirst(s.closedTurnIds.count - Self.closedTurnsKept)
                s.interruptedTurnIds.formIntersection(s.closedTurnIds)
            }
        }
        s.interruptedAt = byInterrupt ? now : nil
    }
    private func reopen(_ s: inout ActivitySession, _ turn: String?) {
        guard let turn else { return }
        s.closedTurnIds.removeAll { $0 == turn }; s.interruptedTurnIds.remove(turn)
    }
    /// The finish line, shared by Stop and the lost-Stop rescues: done if nothing is still out, held otherwise.
    func applyStopVerdict(_ s: inout ActivitySession, now: Date) {
        if !s.hasLiveHelpers(at: now) && s.backgroundIds.isEmpty { set(&s, .done, now) }
        else { s.pendingDone = true; set(&s, .working, now) }
    }
    func clearPending(_ s: inout ActivitySession) { s.pendingDone = false; s.holdReleasedAt = nil }
    func set(_ s: inout ActivitySession, _ new: ActivitySessionState, _ now: Date, fromAgent: Bool = false) {
        guard s.state != new || new == .waiting else { return }
        s.state = new; s.stateSince = now; s.waitingFromAgent = fromAgent
    }
    func updateHoldRelease(_ s: inout ActivitySession, now: Date) {
        guard s.pendingDone else { return }
        if !s.hasLiveHelpers(at: now) && s.backgroundIds.isEmpty { if s.holdReleasedAt == nil { s.holdReleasedAt = now } }
        else { s.holdReleasedAt = nil }
    }

    /// The agent process died: every session it hosted is gone, no SessionEnd required.
    public mutating func processExited(pid: Int32) { sessions = sessions.filter { $0.value.agentPid != pid } }
    /// Startup prune after replay: a session is kept only while its pid is alive and runs its agent and, for a
    /// Claude Code session, while the registry record for that pid, when one exists, names the same session (a
    /// recycled pid's record names another; no record proves nothing). `registrySession` is asked about live
    /// Claude Code pids only. Sessions without a pid are left to staleness. A session on a shared Codex host is
    /// kept without asking: the host was alive when it was marked, and its life says nothing about the
    /// session's turn, which the Codex check at launch decides.
    public mutating func pruneDead(isAlive: (Int32, ActivityAgent) -> Bool, registrySession: (Int32) -> String?) {
        sessions = sessions.filter { entry in
            let s = entry.value
            guard !s.hostedBySharedCodex, let pid = s.agentPid else { return true }
            guard isAlive(pid, s.agent) else { return false }
            guard s.agent == .claude, let named = registrySession(pid) else { return true }
            return named == s.id
        }
    }
    /// Marks each Codex session by the process its pid names: Codex's managed daemon, or any shared Codex
    /// host (the managed daemon included).
    public mutating func markCodexHosts(isManagedDaemon: (Int32) -> Bool, isSharedHost: (Int32) -> Bool) {
        for (id, s) in sessions where s.agent == .codex {
            let managed = s.agentPid.map(isManagedDaemon) ?? false
            let shared = managed || (s.agentPid.map(isSharedHost) ?? false)
            if managed != s.hostedByManagedDaemon { sessions[id]?.hostedByManagedDaemon = managed }
            if shared != s.hostedBySharedCodex { sessions[id]?.hostedBySharedCodex = shared }
        }
    }

    /// Every time-based rule. Call with the wall clock; schedule the next call at `nextDeadline(after:)`.
    public mutating func tick(now: Date) {
        for (id, original) in sessions {
            var s = original
            if s.pendingDone {
                updateHoldRelease(&s, now: now)
                let graceExpired = s.holdReleasedAt.map { now.timeIntervalSince($0) >= ActivityConstants.holdGraceSeconds } ?? false
                let ttlExpired = now.timeIntervalSince(s.lastEventAt) >= ActivityConstants.holdTTLSeconds
                if graceExpired || ttlExpired { clearPending(&s); set(&s, .done, now) }
            }
            if s.state == .done, now.timeIntervalSince(s.stateSince) >= ActivityConstants.doneVisibleSeconds { set(&s, .idle, now) }
            if now.timeIntervalSince(s.lastEventAt) >= ActivityConstants.staleSeconds { sessions.removeValue(forKey: id); continue }
            sessions[id] = s
        }
    }

    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for s in sessions.values {
            if s.pendingDone {
                if let released = s.holdReleasedAt { deadlines.append(released.addingTimeInterval(ActivityConstants.holdGraceSeconds)) }
                if let expiry = s.helperExpiry(after: now) { deadlines.append(expiry) }
                deadlines.append(s.lastEventAt.addingTimeInterval(ActivityConstants.holdTTLSeconds))
            }
            if s.state == .done { deadlines.append(s.stateSince.addingTimeInterval(ActivityConstants.doneVisibleSeconds)) }
            // A quiet working session is asked about at its source: Claude Code's registry, found by the pid,
            // Codex's rollout or Copilot's `events.jsonl`, found by the session. An OpenCode session is not
            // asked: its hooks, its server's exit and staleness end it.
            if s.state == .working, !s.pendingDone, [.codex, .copilot].contains(s.agent) || (s.agent == .claude && s.agentPid != nil) {
                let eligibleAt = s.lastEventAt.addingTimeInterval(ActivityConstants.abandonQuietSeconds)
                deadlines.append(eligibleAt > now ? eligibleAt : now.addingTimeInterval(ActivityConstants.abandonRecheckSeconds))
            }
            if s.agent == .claude, s.state == .waiting, s.agentPid != nil { deadlines.append(now.addingTimeInterval(ActivityConstants.abandonRecheckSeconds)) }
            // A waiting Copilot session is asked about too: answering its prompt fires no hook either.
            if s.agent == .copilot, s.state == .waiting { deadlines.append(now.addingTimeInterval(ActivityConstants.abandonRecheckSeconds)) }
            deadlines.append(s.lastEventAt.addingTimeInterval(ActivityConstants.staleSeconds))
        }
        return deadlines.filter { $0 > now }.min()
    }

    /// Working Claude Code sessions quiet for `quietSeconds` with nothing out, to be asked about at the source
    /// (Claude Code's registry file). The read lives in the app; at launch the gate is 0. Codex and Copilot have
    /// no registry: their sessions are `codexCandidates` and `copilotCandidates`.
    public func abandonCandidates(at now: Date, quietSeconds: TimeInterval = ActivityConstants.abandonQuietSeconds) -> [(sessionId: String, pid: Int32)] {
        sessions.values.compactMap { s in
            guard s.agent == .claude, s.state == .working, !s.pendingDone, let pid = s.agentPid, !s.hasLiveHelpers(at: now), s.backgroundIds.isEmpty,
                  now.timeIntervalSince(s.lastEventAt) >= quietSeconds else { return nil }
            return (s.id, pid)
        }
    }
    /// Working Codex sessions quiet for `quietSeconds` with nothing out, to be checked against their rollout
    /// (the path their hooks named, when one did). The read lives in the app; at launch the gate is 0.
    public func codexCandidates(at now: Date, quietSeconds: TimeInterval = ActivityConstants.abandonQuietSeconds) -> [(sessionId: String, transcriptPath: String?)] {
        quietWorkingSessions(of: .codex, at: now, quietSeconds: quietSeconds)
    }
    /// Working Copilot sessions quiet for `quietSeconds` with nothing out, to be checked against their
    /// `events.jsonl` (the path their hooks named, when one did). The read lives in the app; at launch the gate is 0.
    public func copilotCandidates(at now: Date, quietSeconds: TimeInterval = ActivityConstants.abandonQuietSeconds) -> [(sessionId: String, transcriptPath: String?)] {
        quietWorkingSessions(of: .copilot, at: now, quietSeconds: quietSeconds)
    }
    private func quietWorkingSessions(of agent: ActivityAgent, at now: Date, quietSeconds: TimeInterval) -> [(sessionId: String, transcriptPath: String?)] {
        sessions.values.compactMap { s in
            guard s.agent == agent, s.state == .working, !s.pendingDone, !s.hasLiveHelpers(at: now), s.backgroundIds.isEmpty,
                  now.timeIntervalSince(s.lastEventAt) >= quietSeconds else { return nil }
            return (s.id, s.transcriptPath)
        }
    }
    /// The registry, a rollout, Codex's daemon or a Copilot `events.jsonl` says the turn ended after our last
    /// event: the turn is over, however it ended, and closed. `now` is when it ended (`rescueStamp`).
    public mutating func turnOver(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working, !s.pendingDone else { return }
        set(&s, .done, now); closeTurn(&s, byInterrupt: false, now: now); sessions[sessionId] = s
    }
    /// When a rescued turn ended: the source's own stamp (the registry's `statusUpdatedAt`, the end marker's of a
    /// rollout or an `events.jsonl`; now for an answer that carries none), never before the last main-agent event
    /// and never after now. The turn is ended at it and the verdict journaled with it, so a replay gives the same
    /// `stateSince`.
    public static func rescueStamp(endedAt: Date, lastMainEventAt: Date, now: Date) -> Date {
        min(max(endedAt, lastMainEventAt), now)
    }
    /// The registry says busy, or the rollout's or the `events.jsonl`'s turn has no end: the agent is running
    /// even though no hook arrived. Liveness only — `lastMainEventAt` keeps measuring true hook silence.
    public mutating func noteBusy(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working else { return }
        s.lastEventAt = now; sessions[sessionId] = s
    }
    public func openWaitCandidates() -> [(sessionId: String, pid: Int32, stateSince: Date)] {
        sessions.values.compactMap { s in
            guard s.agent == .claude, s.state == .waiting, let pid = s.agentPid else { return nil }
            return (s.id, pid, s.stateSince)
        }
    }
    /// Waiting Copilot sessions (a permission prompt, most often), each with the transcript path its hooks named
    /// and when the wait began (`stateSince`): Copilot fires no hook when the prompt is answered, so the read
    /// lives in the app, against `events.jsonl` (`CopilotTranscriptTail.waitAnswered`).
    public func copilotWaitCandidates() -> [(sessionId: String, transcriptPath: String?, waitSince: Date)] {
        sessions.values.compactMap { s in
            guard s.agent == .copilot, s.state == .waiting else { return nil }
            return (s.id, s.transcriptPath, s.stateSince)
        }
    }
    /// The dialog or prompt was answered without a hook: Claude Code's registry busy, stamped after the dialog
    /// opened, or Copilot's `events.jsonl` holding the prompt's `permission.completed` after the wait began.
    public mutating func dialogAnswered(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .waiting else { return }
        set(&s, .working, now); sessions[sessionId] = s
    }
}
