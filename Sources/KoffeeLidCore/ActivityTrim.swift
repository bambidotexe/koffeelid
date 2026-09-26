import Foundation

/// What a `KoffeeLidHook hook …` invocation speaks for, from the arguments after `hook`: none is Claude Code,
/// `codex` Codex, `copilot <event>` Copilot (its payload names no event, so the hook file puts the name here),
/// `opencode` OpenCode (which has no command hooks: a plugin runs it). Any other arguments are nil: the hook
/// writes nothing and still exits 0.
public enum HookCall: Equatable, Sendable {
    case claude, codex, copilot(event: String), opencode

    /// The hook always names its agent: `hook` alone is no agent's, and the hook writes nothing for it.
    public init?(arguments: [String]) {
        switch arguments {
        case ["claude"]: self = .claude
        case ["codex"]: self = .codex
        case ["opencode"]: self = .opencode
        default:
            guard arguments.count == 2, arguments[0] == "copilot" else { return nil }
            self = .copilot(event: arguments[1])
        }
    }

    public var agent: ActivityAgent {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .copilot: return .copilot
        case .opencode: return .opencode
        }
    }
}

/// Reduces a raw hook payload to one journal line. Bodies are dropped here so the journal stays small and
/// appends stay atomic; every copied string is clamped at ingestion. The hook's verb says which agent sent the
/// payload, never the payload. Claude Code and Codex name the event in the payload, and only the agent's own
/// names pass (`event(fromHookPayload:agent:loggedAt:)`); Copilot names it in the hook's arguments
/// (`copilotEvent`); OpenCode's own events are mapped onto the journal's names, and one outside the mapping
/// writes nothing (`opencodeEvent`).
public enum ActivityTrim {
    /// A Claude Code or Codex payload, whose `hook_event_name` must be one of that agent's events. Copilot's and
    /// OpenCode's payloads name no journal event: `copilotEvent` and `opencodeEvent` read them, and here they
    /// are a `ParseError`.
    public static func event(fromHookPayload data: Data, agent: ActivityAgent, loggedAt: Date) -> ActivityEvent {
        guard agent == .claude || agent == .codex,
              let obj = object(data),
              let name = obj["hook_event_name"] as? String,
              let event = ActivityEventName(rawValue: name),
              ActivityEventName.hookEvents(for: agent).contains(event)
        else { return parseError(data, agent: agent, loggedAt: loggedAt) }
        var e = ActivityEvent(loggedAt: loggedAt, event: event)
        e.agent = agent
        e.sessionId = clamp(obj["session_id"])
        e.agentId = clamp(obj["agent_id"])
        e.toolName = clamp(obj["tool_name"])
        e.turnId = clamp(obj["turn_id"]) ?? clamp(obj["prompt_id"])
        e.notificationType = clamp(obj["notification_type"])
        e.source = clamp(obj["source"])
        if pathEvents.contains(event) { e.transcriptPath = clampPath(obj["transcript_path"]) }
        if let tasks = obj["background_tasks"] { e.backgroundTaskIds = taskIds(tasks) }
        return e
    }

    /// A Copilot payload, its event named by the hook's arguments (`hook copilot agentStop`, one of
    /// `ActivityEventName.copilotHookEvents`). The body is camelCase: `sessionId` (else `session_id`), `toolName`,
    /// `source`, `transcriptPath`; `notification_type` is snake case even there. Copilot names no turn. Any other
    /// name, or a body that is not a JSON object, is a `ParseError`. The subagent filter and the transcript path
    /// the payload leaves out need the session folders: `CopilotSessionState.line`.
    public static func copilotEvent(fromHookPayload data: Data, named name: String, loggedAt: Date) -> ActivityEvent {
        guard let obj = object(data), let event = ActivityEventName(copilotHookEvent: name) else {
            return parseError(data, agent: .copilot, loggedAt: loggedAt)
        }
        var e = ActivityEvent(loggedAt: loggedAt, event: event)
        e.agent = .copilot
        e.sessionId = clamp(obj["sessionId"]) ?? clamp(obj["session_id"])
        e.toolName = clamp(obj["toolName"]) ?? clamp(obj["tool_name"])
        e.notificationType = clamp(obj["notification_type"]) ?? clamp(obj["notificationType"])
        e.source = clamp(obj["source"])
        if pathEvents.contains(event) { e.transcriptPath = clampPath(obj["transcriptPath"]) ?? clampPath(obj["transcript_path"]) }
        return e
    }

    /// The payload `hook opencode` reads, one JSON object per OpenCode event (`docs/macOS.md` § OpenCode):
    /// `hook_event_name` is OpenCode's own event type, mapped onto the journal's names (`opencodeMapping`). A
    /// session with a `parent_id` is a subagent: its events are helper events of the parent (`sessionId` the
    /// parent, `agentId` the child). OpenCode names no turn. The server's pid, `opencode_pid`, is kept as
    /// `agentPid`: a claim the hook keeps only when that pid is an OpenCode ancestor of its own
    /// (`ProcWalk.pid(of:inChainFrom:claimed:)`). Nil is a line KoffeeLid does not write: an event outside the
    /// mapping, a form that is not a question to the user, or an event of no session (`session_id` null, or
    /// `global` for a form outside any session). A body that is not a JSON object with an event type is a
    /// `ParseError`.
    public static func opencodeEvent(fromHookPayload data: Data, loggedAt: Date) -> ActivityEvent? {
        guard let obj = object(data), let type = obj["hook_event_name"] as? String else {
            return parseError(data, agent: .opencode, loggedAt: loggedAt)
        }
        guard let session = clamp(obj["session_id"]), !session.isEmpty, session != "global" else { return nil }
        let parent = clamp(obj["parent_id"]).flatMap { $0.isEmpty ? nil : $0 }
        guard let (event, notification) = opencodeMapping(type, subagent: parent != nil, status: obj["status"] as? String,
                                                          question: obj["question"] as? Bool ?? false) else { return nil }
        var e = ActivityEvent(loggedAt: loggedAt, event: event)
        e.agent = .opencode
        if let parent { e.sessionId = parent; e.agentId = session } else { e.sessionId = session }
        // A permission's action (`shell`, `edit`, …) names the tool it guards.
        e.toolName = clamp(obj["tool_name"]) ?? (type == "permission.asked" ? clamp(obj["permission"]) : nil)
        e.notificationType = notification
        e.agentPid = (obj["opencode_pid"] as? Int).flatMap { Int32(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil }
        return e
    }

    /// OpenCode's event type onto the journal's name, for a top-level session or a subagent (whose events are its
    /// parent's helper events), with the notification type a question to the user carries. A subagent's end of
    /// any kind is its `SubagentStop`, and its question or permission holds the parent's turn; a rejected
    /// permission is a denial at the top and a reply like any other in a subagent. Nil: nothing is written.
    static func opencodeMapping(_ type: String, subagent: Bool, status: String?, question: Bool) -> (ActivityEventName, String?)? {
        switch type {
        case "session.created", "session.forked": return (subagent ? .subagentStart : .sessionStart, nil)
        case "session.inbox.enqueued", "session.execution.started": return (.userPromptSubmit, nil)
        case "session.tool.called": return (.preToolUse, nil)
        case "session.tool.success": return (.postToolUse, nil)
        case "session.tool.failed": return (.postToolUseFailure, nil)
        case "permission.asked": return (.permissionRequest, nil)
        case "permission.replied": return (status == "reject" && !subagent ? .permissionDenied : .postToolUse, nil)
        case "form.created":
            guard question else { return nil }
            return subagent ? (.permissionRequest, nil) : (.notification, "elicitation_dialog")
        case "form.replied", "form.cancelled": return (.postToolUse, nil)
        case "session.compaction.started": return (.preCompact, nil)
        case "session.compaction.ended", "session.compaction.failed": return (.postCompact, nil)
        case "session.execution.succeeded": return (subagent ? .subagentStop : .stop, nil)
        case "session.execution.failed": return (subagent ? .subagentStop : .stopFailure, nil)
        case "session.execution.interrupted": return (subagent ? .subagentStop : .interrupt, nil)
        case "session.deleted": return (subagent ? .subagentStop : .sessionEnd, nil)
        default: return nil
        }
    }

    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    static func parseError(_ data: Data, agent: ActivityAgent, loggedAt: Date) -> ActivityEvent {
        var e = ActivityEvent(loggedAt: loggedAt, event: .parseError)
        e.agent = agent
        e.rawPrefix = String(String(decoding: data, as: UTF8.self).prefix(ActivityConstants.rawPrefixMaxChars))
        return e
    }

    /// The events that carry the transcript path: every turn's boundaries and the session's start, enough for
    /// a session to know its file without a kilobyte on every tool line.
    static let pathEvents: Set<ActivityEventName> = [.sessionStart, .userPromptSubmit, .stop, .interrupt]

    static func clamp(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return String(text.prefix(ActivityConstants.metadataMaxChars))
    }
    static func clampPath(_ value: Any?) -> String? {
        guard let path = value as? String else { return nil }
        return String(path.prefix(ActivityConstants.pathMaxChars))
    }

    public static func clampLabel(_ label: String) -> String { String(label.prefix(ActivityConstants.labelMaxChars)) }

    /// Only background shells hold a turn. Subagents have their own events; monitor-type entries never
    /// report completion, so either would hold the arm long after the turn ended.
    static func taskIds(_ raw: Any) -> [String]? {
        guard let arr = raw as? [Any] else { return nil }
        let n = ActivityConstants.backgroundIdMaxChars
        return Array(arr.compactMap { item -> String? in
            if let s = item as? String { return String(s.prefix(n)) }
            guard let d = item as? [String: Any] else { return nil }
            if let type = d["type"] as? String, type != "shell" { return nil }
            for key in ["id", "task_id", "shell_id", "bash_id"] { if let v = d[key] as? String { return String(v.prefix(n)) } }
            return nil
        }.prefix(ActivityConstants.backgroundIdMaxCount))
    }

    /// Encode with a guaranteed cap: full line, then drastic cuts, then a minimal line that always fits.
    public static func cappedLine(_ event: ActivityEvent) throws -> Data {
        let cap = ActivityConstants.journalLineMaxBytes
        var e = event
        var data = try ActivityCodec.encodeLine(e)
        if data.count > cap {
            e.rawPrefix = e.rawPrefix.map { String($0.prefix(100)) }
            e.backgroundTaskIds = e.backgroundTaskIds.map { Array($0.prefix(4)) }
            e.jobLabel = e.jobLabel.map(clampLabel)
            data = try ActivityCodec.encodeLine(e)
        }
        if data.count > cap {
            var minimal = ActivityEvent(loggedAt: event.loggedAt, event: event.event)
            minimal.sessionId = event.sessionId.map { String($0.prefix(64)) }
            // The turn id says whether the line belongs to a closed turn.
            minimal.turnId = event.turnId.map { String($0.prefix(ActivityConstants.metadataMaxChars)) }
            minimal.jobId = event.jobId.map { String($0.prefix(64)) }
            data = try ActivityCodec.encodeLine(minimal)
        }
        return data
    }
}
