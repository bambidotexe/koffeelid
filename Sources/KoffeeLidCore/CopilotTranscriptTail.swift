import Foundation

/// What the end of a Copilot session's `events.jsonl` (`~/.copilot/session-state/<session id>/events.jsonl`)
/// says about the session's turn. Copilot writes every step of a turn there, whether or not a hook fired:
/// Ctrl+C and a double Esc fire no hook but write an `abort`, and a failed turn fires no `agentStop` but writes a
/// `session.error`. Only a line's `type`, `timestamp`, `data.hookType` and the session id inside `data.input`
/// are read: the file holds the whole conversation, and nothing else of a line is kept, returned or logged.
public enum CopilotTranscriptTail {
    public enum Verdict: Equatable {
        /// The last turn marker is a step of a turn with no end after it: Copilot is working.
        case running
        /// The session's own `agentStop` hook started at `at`: the turn reached its natural end.
        case complete(at: Date)
        /// The turn was aborted at `at` (Ctrl+C, a double Esc, a remote or MCP abort).
        case aborted(at: Date)
        /// The turn failed at `at`: a model call that gave up.
        case failed(at: Date)
        /// The session was closed at `at`.
        case ended(at: Date)
        /// No turn marker could be read: nothing is decided.
        case unreadable
    }

    /// How much of the file's end is read. A turn's end sits among its last few lines; a tail that one large
    /// line fills leaves no marker to read, and decides nothing.
    public static let tailBytes = 65_536

    /// The verdict of the last turn marker in `tail`, the file's last `tailBytes`, for the session `sessionId`.
    /// A line that is not a whole JSON object is skipped: the first one, cut by the window, and a last one still
    /// being written. `hook.start` is a marker only for an `agentStop` whose payload names `sessionId`: a
    /// subagent's `agentStop` is written into its parent's file under the subagent's id, while the parent's turn
    /// goes on. `assistant.turn_end` is not a marker: Copilot writes one after every model call.
    public static func verdict(tail: Data, sessionId: String) -> Verdict {
        for line in tail.split(separator: 0x0A).reversed() {
            if let marker = marker(in: Data(line), sessionId: sessionId) { return marker }
        }
        return .unreadable
    }

    /// Whether `path` is `<sessionStateDirectory>/<sessionId>/events.jsonl`, absolute, with no `.` or `..`
    /// component. A recorded path is read only then, so a forged journal line cannot point the reader at
    /// another file, nor at another session's.
    public static func isTranscript(path: String, ofSession sessionId: String, sessionStateDirectory: String) -> Bool {
        let root = sessionStateDirectory.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), sessionStateDirectory.hasPrefix("/"), !root.isEmpty, CopilotSessionState.isFolderName(sessionId),
              !parts.contains(where: { $0 == "." || $0 == ".." }), !root.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return parts == root + [sessionId, "events.jsonl"]
    }

    /// What a verdict means for a quiet working session whose last main-agent event is `lastMainEventAt`.
    public enum Decision: Equatable {
        /// The turn is over; `reason` is `finished`, `aborted`, `failed` or `ended`, and `at` is the end marker's stamp.
        case turnOver(reason: String, at: Date)
        /// Copilot is still working the turn, and last wrote the file at `writtenAt` (nil when the file's date
        /// could not be read).
        case busy(writtenAt: Date?)
        case nothing
    }
    /// An end marker ends the turn when it is stamped after our last main-agent event; Copilot names no turn, so
    /// an end stamped before it is an earlier turn's. An unreadable tail decides nothing. A turn with no end is
    /// busy only while Copilot still writes the file: one last written `ActivityConstants.staleSeconds` or more
    /// before `now` decides nothing, and staleness ends the session. The file's date never ends a turn.
    public static func decision(verdict: Verdict, lastMainEventAt: Date, writtenAt: Date?, now: Date) -> Decision {
        func over(_ reason: String, _ at: Date) -> Decision { at > lastMainEventAt ? .turnOver(reason: reason, at: at) : .nothing }
        switch verdict {
        case .complete(let at): return over("finished", at)
        case .aborted(let at): return over("aborted", at)
        case .failed(let at): return over("failed", at)
        case .ended(let at): return over("ended", at)
        case .running:
            if let writtenAt, now.timeIntervalSince(writtenAt) >= ActivityConstants.staleSeconds { return .nothing }
            return .busy(writtenAt: writtenAt)
        case .unreadable: return .nothing
        }
    }

    /// The steps of a turn: a prompt taken, a model call, a message, a tool, a permission.
    private static let runningTypes: Set<String> = ["user.message", "assistant.turn_start", "assistant.message", "tool.execution_start",
                                                    "tool.execution_complete", "permission.requested", "permission.completed"]

    private static func marker(in line: Data, sessionId: String) -> Verdict? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String,
              let stamp = object["timestamp"] as? String,
              let at = ActivityCodec.isoMs.date(from: stamp) ?? ActivityCodec.iso.date(from: stamp)
        else { return nil }
        switch type {
        case "abort": return .aborted(at: at)
        case "session.error": return .failed(at: at)
        case "session.shutdown": return .ended(at: at)
        case "hook.start":
            guard !sessionId.isEmpty, let data = object["data"] as? [String: Any], data["hookType"] as? String == "agentStop",
                  let input = data["input"] as? [String: Any], (input["sessionId"] ?? input["session_id"]) as? String == sessionId
            else { return nil }
            return .complete(at: at)
        default: return runningTypes.contains(type) ? .running : nil
        }
    }
}
