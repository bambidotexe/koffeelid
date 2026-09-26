import Foundation

/// Copilot CLI's session folders: `~/.copilot/session-state/<session id>/`, or under `$COPILOT_HOME` when the
/// hook's environment sets it, one per session and named by its id, holding the session's `events.jsonl`. A
/// subagent's own prompt and stop carry the subagent's id, which has no folder: the hook drops those lines, so
/// a helper's stop never ends its parent's turn. Pure: the hook hands in the environment and the file checks.
public enum CopilotSessionState {
    /// `$COPILOT_HOME/session-state` when `COPILOT_HOME` is set and not empty, else `<home>/.copilot/session-state`.
    public static func root(environment: [String: String], home: String) -> String {
        let base: String
        if let copilotHome = environment["COPILOT_HOME"], !copilotHome.isEmpty { base = copilotHome }
        else { base = (home as NSString).appendingPathComponent(".copilot") }
        return (base as NSString).appendingPathComponent("session-state")
    }

    /// The session's event log, where its turn markers are written.
    public static func transcriptPath(root: String, sessionId: String) -> String {
        ((root as NSString).appendingPathComponent(sessionId) as NSString).appendingPathComponent("events.jsonl")
    }

    /// Whether the hook writes a Copilot line: always when it names no session (a `ParseError`) or when the root
    /// is missing (nothing to tell a subagent by); otherwise only when the session has its folder under the
    /// root. An id that is not one path component names no folder.
    public static func keeps(sessionId: String?, root: String, directoryExists: (String) -> Bool) -> Bool {
        guard let sessionId, directoryExists(root) else { return true }
        return isFolderName(sessionId) && directoryExists((root as NSString).appendingPathComponent(sessionId))
    }

    /// The line the hook writes for a trimmed Copilot event: nil for a subagent's (`keeps`), else the event,
    /// with the session's `events.jsonl` as its transcript path on `SessionStart`, `UserPromptSubmit` and `Stop`
    /// when the payload named none and the root exists, so the session knows its file before its first `Stop`.
    public static func line(_ event: ActivityEvent, root: String, directoryExists: (String) -> Bool) -> ActivityEvent? {
        guard keeps(sessionId: event.sessionId, root: root, directoryExists: directoryExists) else { return nil }
        var e = event
        if ActivityTrim.pathEvents.contains(e.event), e.transcriptPath == nil, let sid = e.sessionId, isFolderName(sid), directoryExists(root) {
            e.transcriptPath = ActivityTrim.clampPath(transcriptPath(root: root, sessionId: sid))
        }
        return e
    }

    static func isFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
