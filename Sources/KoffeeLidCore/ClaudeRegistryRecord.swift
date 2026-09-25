import Foundation

/// Claude Code's own per-process record, `<config>/sessions/<pid>.json`: `status` is "busy" while a turn
/// runs and "idle" at the prompt. The one signal about a turn that does not travel through hooks.
public struct ClaudeRegistryRecord: Equatable {
    public let sessionId: String?
    public let status: String?
    public let statusUpdatedAt: Date?
    /// Strictly "idle" / "busy": values a future Claude Code adds must read as neither.
    public var isIdle: Bool { status == "idle" }
    public var isBusy: Bool { status == "busy" }

    public static func parse(_ data: Data, expectedPid: Int32) -> ClaudeRegistryRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["pid"] as? Int == Int(expectedPid) else { return nil }
        let ms = (object["statusUpdatedAt"] as? Double) ?? (object["statusUpdatedAt"] as? Int).map(Double.init)
        return ClaudeRegistryRecord(sessionId: object["sessionId"] as? String, status: object["status"] as? String,
                                    statusUpdatedAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    /// The config directory a transcript lives in: `<config>/projects/<slug>/<session>.jsonl` gives `<config>`, where
    /// the registry sits too (`<config>/sessions/`), so a relocated `CLAUDE_CONFIG_DIR` is found from the path the
    /// hooks name. The `projects` folder is the last one above the file's own folder. Nil for a path that is not
    /// absolute, carries a `.` or `..` component, or has no such folder with a folder above it.
    public static func configDir(fromTranscriptPath path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), !parts.contains(where: { $0 == "." || $0 == ".." }),
              let index = parts.dropLast(2).lastIndex(of: "projects"), index > 0 else { return nil }
        return URL(fileURLWithPath: "/" + parts[..<index].joined(separator: "/"), isDirectory: true)
    }
}
