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
}
