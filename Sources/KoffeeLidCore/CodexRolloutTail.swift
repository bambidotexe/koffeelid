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
        /// The last turn, `turnId`, finished at `at`, however it ended.
        case complete(at: Date, turnId: String?)
        /// The last turn, `turnId`, was aborted at `at` (Esc, Ctrl-C).
        case aborted(at: Date, turnId: String?)
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

    /// Whether `path` sits where Codex keeps rollouts: `<sessionsDirectory>/<yyyy>/<mm>/<dd>/<file>`, absolute,
    /// with no `.` or `..` component. A recorded path is read only then, so a forged journal line cannot point
    /// the reader at another file.
    public static func isInSessions(_ path: String, sessionsDirectory: String) -> Bool {
        let root = sessionsDirectory.split(separator: "/", omittingEmptySubsequences: true)
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), sessionsDirectory.hasPrefix("/"), !root.isEmpty,
              !parts.contains(where: { $0 == "." || $0 == ".." }), !root.contains(where: { $0 == "." || $0 == ".." }),
              parts.count == root.count + 4 else { return false }
        return Array(parts.prefix(root.count)) == root
    }

    /// What a verdict means for a quiet working session whose last main-agent event is `lastMainEventAt`,
    /// carrying the turn id `lastMainTurnId`.
    public enum Decision: Equatable {
        /// The turn is over; `reason` is `finished` or `aborted`, and `at` is the end marker's stamp.
        case turnOver(reason: String, at: Date)
        /// Codex is still working the turn, and last wrote the rollout at `writtenAt` (nil when the file's date
        /// could not be read).
        case busy(writtenAt: Date?)
        case nothing
    }
    /// An end marker ends the turn when it is stamped after our last main-agent event, or when it names the
    /// turn that event belonged to: an aborted tool's `PostToolUse` can arrive after the `turn_aborted` it
    /// belongs to, so its stamp alone would keep the session working. An end of an earlier turn, stamped
    /// before our last event, is that turn's; an unreadable tail decides nothing. A start with no end is busy
    /// only while Codex still writes the file: one last written `ActivityConstants.staleSeconds` or more before
    /// `now` decides nothing, and staleness ends the session. The file's date never ends a turn.
    public static func decision(verdict: Verdict, lastMainEventAt: Date, lastMainTurnId: String?, writtenAt: Date?, now: Date) -> Decision {
        func ends(_ at: Date, _ turn: String?) -> Bool {
            at > lastMainEventAt || (turn != nil && turn == lastMainTurnId)
        }
        switch verdict {
        case .complete(let at, let turn): return ends(at, turn) ? .turnOver(reason: "finished", at: at) : .nothing
        case .aborted(let at, let turn): return ends(at, turn) ? .turnOver(reason: "aborted", at: at) : .nothing
        case .running:
            if let writtenAt, now.timeIntervalSince(writtenAt) >= ActivityConstants.staleSeconds { return .nothing }
            return .busy(writtenAt: writtenAt)
        case .unreadable: return .nothing
        }
    }

    /// The last turn marker's own end stamp, when it names one (`complete`/`aborted`), else nil: what a Codex
    /// daemon "nothing runs" verdict is dated to when the rollout itself has an end to show; still running or
    /// unreadable leaves the caller with nothing to date the verdict to from the rollout.
    public static func endMarkerDate(_ verdict: Verdict) -> Date? {
        switch verdict {
        case .complete(let at, _), .aborted(let at, _): return at
        case .running, .unreadable: return nil
        }
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
        case "task_complete": return .complete(at: at, turnId: payload["turn_id"] as? String)
        default: return .aborted(at: at, turnId: payload["turn_id"] as? String)
        }
    }
}
