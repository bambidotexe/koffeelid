// App/Sources/CodexRollout.swift
import Foundation
import KoffeeLidCore

/// Reads the end of a Codex session's rollout file for `CodexRolloutTail`. Only the last
/// `CodexRolloutTail.tailBytes` are read, and the bytes go nowhere but the parser: the file holds the
/// whole conversation.
enum CodexRollout {
    /// The last `CodexRolloutTail.tailBytes` of the file at `path`, or nil when it cannot be read.
    static func read(path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(CodexRolloutTail.tailBytes) ? size - UInt64(CodexRolloutTail.tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    /// The newest `~/.codex/sessions/<y>/<m>/<d>/rollout-*-<sessionId>.jsonl`, for a session whose lines
    /// named no path. A session id that is not a plain id (letters, digits, dashes) finds nothing.
    static func locate(sessionId: String) -> String? {
        guard !sessionId.isEmpty, sessionId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions").path
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
