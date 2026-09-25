import Foundation

/// What the end of a Codex rollout file (`~/.codex/sessions/…/rollout-<ts>-<session id>.jsonl`) says about
/// the session's turn. Codex writes one `event_msg` line when a turn starts (`task_started`) and one when it
/// ends (`task_complete`, or `turn_aborted` for Esc and Ctrl-C), whether or not a hook fired. Only the
/// line's `type`, `timestamp`, `payload.type` and `payload.turn_id` are read: the rollout holds the whole
/// conversation, and nothing else of a line is kept, returned or logged.
public enum CodexRolloutTail {
    public enum Verdict: Equatable {
        /// The last turn marker is a start with no end: Codex is working.
        case running(turnId: String?)
        /// The last turn finished at `at`, however it ended.
        case complete(at: Date)
        /// The last turn was aborted at `at` (Esc, Ctrl-C).
        case aborted(at: Date)
        /// No turn marker could be read: nothing is decided.
        case unreadable
    }

    /// How much of the file's end is read. A finished turn's end marker sits among its last few lines; a tail
    /// that one large line fills leaves no marker to read, and decides nothing.
    public static let tailBytes = 65_536

    /// The verdict of the last turn marker in `tail`, the file's last `tailBytes`. A line that is not a whole
    /// JSON object is skipped: the first one, cut by the window, and a last one still being written.
    /// `item_completed`, `token_count` and every other line are not turn markers: Codex writes an
    /// `item_completed` for an aborted call after the abort.
    public static func verdict(tail: Data) -> Verdict {
        var last: Verdict = .unreadable
        for line in tail.split(separator: 0x0A) {
            let line = Data(line)
            // A cheap sieve before any parse: most lines are the conversation's items, never an event.
            guard line.range(of: eventMessage) != nil, let marker = marker(in: line) else { continue }
            last = marker
        }
        return last
    }

    /// Whether `path` is the rollout of `sessionId`: Codex names the file after the session, so a path from
    /// another session, or no rollout at all, decides nothing.
    public static func isRollout(path: String, ofSession sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix("-\(sessionId).jsonl")
    }

    private static let eventMessage = Data("\"event_msg\"".utf8)
    private static let markerTypes: Set<String> = ["task_started", "task_complete", "turn_aborted"]

    private static func marker(in line: Data) -> Verdict? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let kind = payload["type"] as? String, markerTypes.contains(kind),
              let stamp = object["timestamp"] as? String,
              let at = ActivityCodec.isoMs.date(from: stamp) ?? ActivityCodec.iso.date(from: stamp)
        else { return nil }
        switch kind {
        case "task_started": return .running(turnId: payload["turn_id"] as? String)
        case "task_complete": return .complete(at: at)
        default: return .aborted(at: at)
        }
    }
}
