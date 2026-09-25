// App/Sources/CodexRollout.swift
import Foundation
import KoffeeLidCore

/// Reads the end of a Codex session's rollout file for `CodexRolloutTail`. Only the last
/// `CodexRolloutTail.tailBytes` are read, and the bytes go nowhere but the parser: the file holds the
/// whole conversation.
enum CodexRollout {
    /// `~/.codex/sessions`, where Codex keeps every rollout.
    static var sessionsDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions").path
    }

    /// The last `CodexRolloutTail.tailBytes` of the regular file at `path` and when it was last written, or nil
    /// when it cannot be read. A FIFO or a device is never opened: opening one could block the main thread.
    static func read(path: String) -> (tail: Data, writtenAt: Date?)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(CodexRolloutTail.tailBytes) ? size - UInt64(CodexRolloutTail.tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return nil }
        return (tail, attributes[.modificationDate] as? Date)
    }

    /// The newest `~/.codex/sessions/<y>/<m>/<d>/rollout-*-<sessionId>.jsonl`, for a session whose lines
    /// named no path. A session id that is not a plain id (letters, digits, dashes) finds nothing.
    static func locate(sessionId: String) -> String? {
        guard !sessionId.isEmpty, sessionId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let root = sessionsDirectory
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob("\(root)/*/*/*/rollout-*-\(sessionId).jsonl", 0, nil, &matches) == 0 else { return nil }
        let paths = (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { String(cString: $0) } }
        func modified(_ path: String) -> Date {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
        }
        return paths.max { modified($0) < modified($1) }
    }
}
