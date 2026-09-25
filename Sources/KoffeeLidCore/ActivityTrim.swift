import Foundation

/// Reduces a raw Claude Code or Codex hook payload to one journal line. Bodies are dropped here so the
/// journal stays small and appends stay atomic; every copied string is clamped at ingestion. Only the
/// agent's own event names pass: the hook's verb says which agent sent the payload, not the payload.
public enum ActivityTrim {
    public static func event(fromHookPayload data: Data, agent: ActivityAgent, loggedAt: Date) -> ActivityEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["hook_event_name"] as? String,
              let event = ActivityEventName(rawValue: name),
              ActivityEventName.hookEvents(for: agent).contains(event)
        else {
            var e = ActivityEvent(loggedAt: loggedAt, event: .parseError)
            e.agent = agent
            e.rawPrefix = String(String(decoding: data, as: UTF8.self).prefix(ActivityConstants.rawPrefixMaxChars))
            return e
        }
        var e = ActivityEvent(loggedAt: loggedAt, event: event)
        e.agent = agent
        e.sessionId = clamp(obj["session_id"])
        e.agentId = clamp(obj["agent_id"])
        e.toolName = clamp(obj["tool_name"])
        e.turnId = clamp(obj["turn_id"]) ?? clamp(obj["prompt_id"])
        e.notificationType = clamp(obj["notification_type"])
        e.source = clamp(obj["source"])
        if pathEvents.contains(event), let path = obj["transcript_path"] as? String { e.transcriptPath = String(path.prefix(ActivityConstants.pathMaxChars)) }
        if let tasks = obj["background_tasks"] { e.backgroundTaskIds = taskIds(tasks) }
        return e
    }

    /// The events that carry the transcript path: every turn's boundaries and the session's start, enough for
    /// a session to know its file without a kilobyte on every tool line.
    static let pathEvents: Set<ActivityEventName> = [.sessionStart, .userPromptSubmit, .stop, .interrupt]

    static func clamp(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return String(text.prefix(ActivityConstants.metadataMaxChars))
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
