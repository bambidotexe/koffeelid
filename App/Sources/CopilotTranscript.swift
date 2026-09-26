// App/Sources/CopilotTranscript.swift
import Foundation
import KoffeeLidCore

/// Reads the end of a Copilot session's `events.jsonl` for `CopilotTranscriptTail`. Only the last
/// `CopilotTranscriptTail.tailBytes` are read, and the bytes go nowhere but the parser: the file holds the
/// whole conversation.
enum CopilotTranscript {
    /// Where Copilot keeps its session folders, found as the hook finds them: `$COPILOT_HOME/session-state` when
    /// the app's own environment sets it, else `~/.copilot/session-state`.
    static var sessionStateDirectory: String {
        CopilotSessionState.root(environment: ProcessInfo.processInfo.environment,
                                 home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// The session's `events.jsonl`: the path its hooks named, else the one its id names, each only when it is
    /// exactly `<session-state>/<session id>/events.jsonl`.
    static func path(sessionId: String, recorded: String?) -> String? {
        let root = sessionStateDirectory
        return [recorded, CopilotSessionState.transcriptPath(root: root, sessionId: sessionId)].compactMap { $0 }.first {
            CopilotTranscriptTail.isTranscript(path: $0, ofSession: sessionId, sessionStateDirectory: root)
        }
    }

    /// The last `CopilotTranscriptTail.tailBytes` of the regular file at `path` and when it was last written, or
    /// nil when it cannot be read. A FIFO or a device is never opened: opening one could block the main thread.
    static func read(path: String) -> (tail: Data, writtenAt: Date?)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(CopilotTranscriptTail.tailBytes) ? size - UInt64(CopilotTranscriptTail.tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return nil }
        return (tail, attributes[.modificationDate] as? Date)
    }
}
