// App/Sources/ClaudeProcessRegistry.swift
import Foundation
import KoffeeLidCore

/// Reads Claude Code's `<config>/sessions/<pid>.json`. The config directory is the one the session's transcript
/// lives in (`ClaudeRegistryRecord.configDir(fromTranscriptPath:)`), which follows a relocated
/// `CLAUDE_CONFIG_DIR`; `~/.claude` when the session names no transcript under a `projects` folder. The
/// process's environment is not read: macOS withholds it from another process.
enum ClaudeProcessRegistry {
    static func read(pid: Int32, configDir: URL?) -> ClaudeRegistryRecord? {
        let dir = configDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("sessions/\(pid).json")) else { return nil }
        return ClaudeRegistryRecord.parse(data, expectedPid: pid)
    }

    /// The registry directory of `session`: its transcript's config directory, or nil for the fallback.
    static func configDir(of session: ActivitySession) -> URL? {
        session.transcriptPath.flatMap(ClaudeRegistryRecord.configDir(fromTranscriptPath:))
    }
}
