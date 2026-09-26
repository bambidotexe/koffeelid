import Foundation

/// The four agents whose hooks feed the journal, in the order every list of them follows. A journal line
/// without an agent is Claude Code's: lines written before Codex was supported carry none.
public enum ActivityAgent: String, Codable, Equatable, CaseIterable, Sendable {
    case claude, codex, copilot, opencode
    /// The name the log uses; the command line uses the raw value, the windows have their own words.
    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        case .opencode: return "OpenCode"
        }
    }
}

/// The journal's event names: Claude Code's hook events, which Codex shares and onto which Copilot's and
/// OpenCode's are mapped, Codex's `Interrupt`, plus KoffeeLid's own line kinds.
public enum ActivityEventName: String, Codable, Equatable {
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd", userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest", permissionDenied = "PermissionDenied", notification = "Notification"
    case stop = "Stop", stopFailure = "StopFailure", subagentStart = "SubagentStart", subagentStop = "SubagentStop"
    case preCompact = "PreCompact", postCompact = "PostCompact"
    case interrupt = "Interrupt"
    case parseError = "ParseError"
    case jobBegin = "JobBegin", jobEnd = "JobEnd"
    /// The app's own verdict on a session (`ActivityVerdict`), journaled after it applied it live, so a relaunch
    /// replays it. A reader that does not know the name skips the line: `ActivityCodec.decodeLine` returns nil.
    case verdict = "KoffeeLidVerdict"

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
    /// The 7 journal events a Copilot line carries: its subscribed events (`copilotHookEvents`) under the
    /// journal's names. Copilot's tool-start and permission hooks are left out (a failing one denies the tool),
    /// and it has no hook for a helper's or a compaction's end, a failed turn or an interrupt.
    public static let copilotEvents: [ActivityEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .postToolUse, .postToolUseFailure, .notification, .stop,
    ]
    /// The 16 journal events an OpenCode line carries once `ActivityTrim.opencodeEvent` has mapped OpenCode's
    /// own event onto them: Claude Code's 15 and `Interrupt`.
    public static let opencodeEvents: [ActivityEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .permissionRequest, .permissionDenied, .notification, .stop, .stopFailure, .subagentStart, .subagentStop,
        .preCompact, .postCompact, .interrupt,
    ]
    /// The journal events a line of `agent` can carry: what the store takes from that agent.
    public static func hookEvents(for agent: ActivityAgent) -> [ActivityEventName] {
        switch agent {
        case .claude: return claudeCodeEvents
        case .codex: return codexEvents
        case .copilot: return copilotEvents
        case .opencode: return opencodeEvents
        }
    }

    /// Copilot CLI's names for the events KoffeeLid subscribes to, in the order its hook file lists them, each
    /// with the journal event its line carries. Copilot's words, not the journal's: a camelCase payload names no
    /// event, so the name rides in the hook's arguments (`hook copilot <name>`). Never `preToolUse` or
    /// `permissionRequest`: Copilot denies the tool when either hook fails, so a hook file outliving the app
    /// would block every tool call.
    static let copilotHookMapping: KeyValuePairs<String, ActivityEventName> = [
        "sessionStart": .sessionStart, "userPromptSubmitted": .userPromptSubmit, "postToolUse": .postToolUse,
        "postToolUseFailure": .postToolUseFailure, "notification": .notification, "agentStop": .stop,
        "sessionEnd": .sessionEnd,
    ]
    /// The 7 Copilot events KoffeeLid subscribes to, in Copilot's words and in the order its hook file lists them.
    public static let copilotHookEvents: [String] = copilotHookMapping.map(\.key)
    /// The journal event of one of `copilotHookEvents`; nil for any other name.
    public init?(copilotHookEvent name: String) {
        guard let event = Self.copilotHookMapping.first(where: { $0.key == name })?.value else { return nil }
        self = event
    }
}

/// What a `KoffeeLidVerdict` line says: the rescue that decided it found the turn over, or the dialog answered.
public enum ActivityVerdict: String, Equatable, CaseIterable, Sendable {
    case turnOver = "turn-over", dialogAnswered = "dialog-answered", waitAbandoned = "wait-abandoned"
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
    /// The turn the event belongs to: Codex's `turn_id`, Claude Code's `prompt_id`. Nil on SessionStart,
    /// SessionEnd, every Copilot and OpenCode line (neither names a turn) and lines written before the field.
    public var turnId: String?
    public var notificationType: String?
    public var source: String?
    /// The session's transcript file: Claude Code's conversation, Codex's rollout, Copilot's `events.jsonl`.
    /// Kept on `SessionStart`, `UserPromptSubmit`, `Stop` and `Interrupt` only; nil on the others, on OpenCode's
    /// lines and on lines written before the field.
    public var transcriptPath: String?
    public var backgroundTaskIds: [String]?
    /// The agent process the hook ran under: the nearest ancestor of that agent's kind, or the OpenCode server
    /// the payload names when it is one of those ancestors.
    public var agentPid: Int32?
    public var rawPrefix: String?
    public var jobId: String?
    public var jobPid: Int32?
    public var jobLabel: String?
    public var jobArmAfterSeconds: Double?
    /// A `KoffeeLidVerdict` line's `ActivityVerdict` raw value; nil on every other line.
    public var verdict: String?

    public init(loggedAt: Date, event: ActivityEventName) { self.loggedAt = loggedAt; self.event = event }

    public var effectiveAgent: ActivityAgent { agent ?? .claude }

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at", event, agent, sessionId = "session_id", agentId = "agent_id", toolName = "tool_name", turnId = "turn_id"
        case notificationType = "notification_type", source, transcriptPath = "transcript_path", backgroundTaskIds = "background_task_ids"
        case agentPid = "agent_pid", rawPrefix = "raw_prefix", jobId = "job_id", jobPid = "job_pid"
        case jobLabel = "job_label", jobArmAfterSeconds = "job_arm_after_seconds", verdict
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
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        backgroundTaskIds = try c.decodeIfPresent([String].self, forKey: .backgroundTaskIds)
        agentPid = try c.decodeIfPresent(Int32.self, forKey: .agentPid)
            ?? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Int32.self, forKey: .claudePid)
        rawPrefix = try c.decodeIfPresent(String.self, forKey: .rawPrefix)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
        jobPid = try c.decodeIfPresent(Int32.self, forKey: .jobPid)
        jobLabel = try c.decodeIfPresent(String.self, forKey: .jobLabel)
        jobArmAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .jobArmAfterSeconds)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict)
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
