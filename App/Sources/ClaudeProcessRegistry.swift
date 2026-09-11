// App/Sources/ClaudeProcessRegistry.swift
import Foundation
import KoffeeLidCore

/// Locates `<config>/sessions/<pid>.json` through the process (CLAUDE_CONFIG_DIR is per account), not a fixed path.
/// The environment read is best-effort: macOS withholds another process's environment, so a nil value falls back to `~/.claude`.
enum ClaudeProcessRegistry {
    static func read(pid: Int32) -> ClaudeRegistryRecord? {
        let configDir = ProcWalk.environmentValue("CLAUDE_CONFIG_DIR", forPid: pid).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent("sessions/\(pid).json")) else { return nil }
        return ClaudeRegistryRecord.parse(data, expectedPid: pid)
    }
}
