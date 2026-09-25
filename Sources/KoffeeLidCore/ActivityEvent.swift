import Foundation

/// The two agents whose hooks feed the journal. A journal line without an agent is Claude Code's: lines
/// written before Codex was supported carry none.
public enum ActivityAgent: String, Codable, Equatable, CaseIterable, Sendable {
    case claude, codex
    /// The name the log and the command line use; the windows have their own words.
    public var name: String { self == .claude ? "Claude Code" : "Codex" }
}

/// Claude Code and Codex hook event names, plus KoffeeLid's own line kinds.
public enum ActivityEventName: String, Codable, Equatable {
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd", userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest", permissionDenied = "PermissionDenied", notification = "Notification"
    case stop = "Stop", stopFailure = "StopFailure", subagentStart = "SubagentStart", subagentStop = "SubagentStop"
    case preCompact = "PreCompact", postCompact = "PostCompact"
    case interrupt = "Interrupt"
    case parseError = "ParseError"
    case jobBegin = "JobBegin", jobEnd = "JobEnd"

    /// The 15 Claude Code events the hook subscribes to, in the order `install-hooks` writes them.
    public static let claudeCodeEvents: [ActivityEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .permissionRequest, .permissionDenied, .notification, .stop, .stopFailure, .subagentStart, .subagentStop,
        .preCompact, .postCompact,
    ]
    /// The 12 Codex events the hook subscribes to, in the order `install-hooks codex` writes them. Codex has
    /// no Notification, PermissionDenied, PostToolUseFailure or StopFailure, and it has Interrupt, which
    /// Esc fires.
    public static let codexEvents: [ActivityEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest,
        .stop, .subagentStart, .subagentStop, .preCompact, .postCompact, .interrupt,
    ]
    public static func hookEvents(for agent: ActivityAgent) -> [ActivityEventName] {
        agent == .claude ? claudeCodeEvents : codexEvents
    }
}

/// One trimmed journal line. Bodies (tool input/output, prompts, messages) never reach this type.
public struct ActivityEvent: Codable, Equatable {
    public var loggedAt: Date
    public var event: ActivityEventName
    /// Which agent's hook wrote the line. Nil is Claude Code: `effectiveAgent` reads it.
    public var agent: ActivityAgent?
    public var sessionId: String?
    public var agentId: String?
    public var toolName: String?
    public var notificationType: String?
    public var source: String?
    public var backgroundTaskIds: [String]?
    /// The agent process the hook ran under: the nearest ancestor of that agent's kind.
    public var agentPid: Int32?
    public var rawPrefix: String?
    public var jobId: String?
    public var jobPid: Int32?
    public var jobLabel: String?
    public var jobArmAfterSeconds: Double?

    public init(loggedAt: Date, event: ActivityEventName) { self.loggedAt = loggedAt; self.event = event }

    public var effectiveAgent: ActivityAgent { agent ?? .claude }

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at", event, agent, sessionId = "session_id", agentId = "agent_id", toolName = "tool_name"
        case notificationType = "notification_type", source, backgroundTaskIds = "background_task_ids"
        case agentPid = "agent_pid", rawPrefix = "raw_prefix", jobId = "job_id", jobPid = "job_pid"
        case jobLabel = "job_label", jobArmAfterSeconds = "job_arm_after_seconds"
    }
    /// The pid's key on lines written before Codex was supported; this boot's journal can still hold them.
    private enum LegacyKeys: String, CodingKey { case claudePid = "claude_pid" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loggedAt = try c.decode(Date.self, forKey: .loggedAt)
        event = try c.decode(ActivityEventName.self, forKey: .event)
        agent = try c.decodeIfPresent(ActivityAgent.self, forKey: .agent)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        backgroundTaskIds = try c.decodeIfPresent([String].self, forKey: .backgroundTaskIds)
        agentPid = try c.decodeIfPresent(Int32.self, forKey: .agentPid)
            ?? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Int32.self, forKey: .claudePid)
        rawPrefix = try c.decodeIfPresent(String.self, forKey: .rawPrefix)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
        jobPid = try c.decodeIfPresent(Int32.self, forKey: .jobPid)
        jobLabel = try c.decodeIfPresent(String.self, forKey: .jobLabel)
        jobArmAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .jobArmAfterSeconds)
    }
}

public enum ActivityCodec {
    static let isoMs: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in var c = enc.singleValueContainer(); try c.encode(isoMs.string(from: date)) }
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = isoMs.date(from: s) ?? iso.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "unparseable date: \(s)"))
            }
            return date
        }
        return d
    }()
    public static func encodeLine(_ e: ActivityEvent) throws -> Data { try encoder.encode(e) }
    public static func decodeLine(_ data: Data) -> ActivityEvent? { try? decoder.decode(ActivityEvent.self, from: data) }
}
