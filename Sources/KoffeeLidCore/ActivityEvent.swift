import Foundation

/// Claude Code hook event names, plus KoffeeLid's own line kinds.
public enum ActivityEventName: String, Codable, Equatable {
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd", userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest", permissionDenied = "PermissionDenied", notification = "Notification"
    case stop = "Stop", stopFailure = "StopFailure", subagentStart = "SubagentStart", subagentStop = "SubagentStop"
    case preCompact = "PreCompact", postCompact = "PostCompact"
    case parseError = "ParseError"
    case jobBegin = "JobBegin", jobEnd = "JobEnd"

    /// The 15 Claude Code events the hook subscribes to, in the order `install-hooks` writes them.
    public static let claudeCodeEvents: [ActivityEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .permissionRequest, .permissionDenied, .notification, .stop, .stopFailure, .subagentStart, .subagentStop,
        .preCompact, .postCompact,
    ]
}

/// One trimmed journal line. Bodies (tool input/output, prompts, messages) never reach this type.
public struct ActivityEvent: Codable, Equatable {
    public var loggedAt: Date
    public var event: ActivityEventName
    public var sessionId: String?
    public var agentId: String?
    public var toolName: String?
    public var notificationType: String?
    public var source: String?
    public var backgroundTaskIds: [String]?
    public var claudePid: Int32?
    public var rawPrefix: String?
    public var jobId: String?
    public var jobPid: Int32?
    public var jobLabel: String?
    public var jobArmAfterSeconds: Double?

    public init(loggedAt: Date, event: ActivityEventName) { self.loggedAt = loggedAt; self.event = event }

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at", event, sessionId = "session_id", agentId = "agent_id", toolName = "tool_name"
        case notificationType = "notification_type", source, backgroundTaskIds = "background_task_ids"
        case claudePid = "claude_pid", rawPrefix = "raw_prefix", jobId = "job_id", jobPid = "job_pid"
        case jobLabel = "job_label", jobArmAfterSeconds = "job_arm_after_seconds"
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
