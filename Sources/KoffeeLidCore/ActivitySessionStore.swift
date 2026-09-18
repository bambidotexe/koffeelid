import Foundation

public enum ActivitySessionState: Equatable { case idle, working, waiting, done }

/// One Claude Code session. Only `.working` counts as running.
public struct ActivitySession: Equatable {
    public var id: String
    public var state: ActivitySessionState = .idle
    public var stateSince: Date
    public var lastEventAt: Date
    /// Last MAIN-agent event (not a helper's, not a Notification): what "the turn has gone quiet" is measured against.
    public var lastMainEventAt: Date
    public var claudePid: Int32?
    /// Helpers believed running, each with its last-seen time; there is no reliable end event.
    public var liveAgents: [String: Date] = [:]
    public var backgroundIds: Set<String> = []
    /// A `done` deferred because helpers or background shells were still out.
    public var pendingDone = false
    public var holdReleasedAt: Date?
    public var waitingFromAgent = false

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

    public var isRunning: Bool { sessions.values.contains { $0.state == .working } }
    public var workingCount: Int { sessions.values.filter { $0.state == .working }.count }
    public var trackedPids: Set<Int32> { Set(sessions.values.compactMap(\.claudePid)) }

    public mutating func apply(_ e: ActivityEvent) {
        guard ActivityEventName.claudeCodeEvents.contains(e.event), let sid = e.sessionId else { return }
        let now = e.loggedAt
        if e.event == .sessionEnd { sessions.removeValue(forKey: sid); return }
        var s = sessions[sid] ?? ActivitySession(id: sid, at: now)
        s.lastEventAt = now
        if let pid = e.claudePid { s.claudePid = pid }

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

        switch e.event {
        case .sessionStart:
            if e.source != "compact" { s.liveAgents.removeAll(); s.backgroundIds.removeAll() }
            clearPending(&s); set(&s, e.source == "compact" ? .working : .idle, now)
        case .userPromptSubmit, .postToolUse, .postToolUseFailure, .permissionDenied, .preCompact, .postCompact:
            clearPending(&s); set(&s, .working, now)
        case .preToolUse:
            clearPending(&s)
            set(&s, (e.toolName == "AskUserQuestion" || e.toolName == "ExitPlanMode") ? .waiting : .working, now)
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
            clearPending(&s); applyStopVerdict(&s, now: now)
        case .sessionEnd, .subagentStart, .subagentStop, .parseError, .jobBegin, .jobEnd:
            break // handled above, or helper shapes without agent_id, which carry no signal
        }
        updateHoldRelease(&s, now: now)
        sessions[sid] = s
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

    /// The Claude process died: every session it hosted is gone, no SessionEnd required.
    public mutating func processExited(pid: Int32) { sessions = sessions.filter { $0.value.claudePid != pid } }
    /// Startup prune after replay. Sessions without a pid are left to staleness.
    public mutating func pruneDead(isAlive: (Int32) -> Bool) { sessions = sessions.filter { $0.value.claudePid.map(isAlive) ?? true } }

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
            if s.state == .working, !s.pendingDone, s.claudePid != nil {
                let eligibleAt = s.lastEventAt.addingTimeInterval(ActivityConstants.abandonQuietSeconds)
                deadlines.append(eligibleAt > now ? eligibleAt : now.addingTimeInterval(ActivityConstants.abandonRecheckSeconds))
            }
            if s.state == .waiting, s.claudePid != nil { deadlines.append(now.addingTimeInterval(ActivityConstants.abandonRecheckSeconds)) }
            deadlines.append(s.lastEventAt.addingTimeInterval(ActivityConstants.staleSeconds))
        }
        return deadlines.filter { $0 > now }.min()
    }

    /// Working sessions quiet for `abandonQuietSeconds` with nothing out, to be asked about at the source
    /// (Claude Code's registry file). The read lives in the app.
    public func abandonCandidates(at now: Date) -> [(sessionId: String, pid: Int32)] {
        sessions.values.compactMap { s in
            guard s.state == .working, !s.pendingDone, let pid = s.claudePid, !s.hasLiveHelpers(at: now), s.backgroundIds.isEmpty,
                  now.timeIntervalSince(s.lastEventAt) >= ActivityConstants.abandonQuietSeconds else { return nil }
            return (s.id, pid)
        }
    }
    /// The registry says idle, stamped after our last event: the turn is over, however it ended.
    public mutating func turnOver(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working, !s.pendingDone else { return }
        set(&s, .done, now); sessions[sessionId] = s
    }
    /// The registry says busy: Claude is running even though no hook arrived. Liveness only —
    /// `lastMainEventAt` keeps measuring true hook silence.
    public mutating func noteBusy(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working else { return }
        s.lastEventAt = now; sessions[sessionId] = s
    }
    public func openWaitCandidates() -> [(sessionId: String, pid: Int32, stateSince: Date)] {
        sessions.values.compactMap { s in
            guard s.state == .waiting, let pid = s.claudePid else { return nil }
            return (s.id, pid, s.stateSince)
        }
    }
    /// The dialog was answered without a hook (registry busy, stamped after the dialog opened).
    public mutating func dialogAnswered(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .waiting else { return }
        set(&s, .working, now); sessions[sessionId] = s
    }
}
