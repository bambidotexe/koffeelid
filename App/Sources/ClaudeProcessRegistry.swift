// App/Sources/ClaudeProcessRegistry.swift
import Foundation
import KoffeeLidCore

/// Reads Claude Code's `<config>/sessions/<pid>.json`. The config directory is the one the session's transcript
/// lives in (`ClaudeRegistryRecord.configDir(fromTranscriptPath:)`), which follows a relocated
/// `CLAUDE_CONFIG_DIR`; else the pid's own `CLAUDE_CONFIG_DIR`, read from its `KERN_PROCARGS2` environment
/// (`ProcWalk.environmentValue`: a same-user process's environment, unlike another user's, is not withheld);
/// `~/.claude` when neither names one.
enum ClaudeProcessRegistry {
    static func read(pid: Int32, configDir: URL?) -> ClaudeRegistryRecord? {
        let dir = configDir
            ?? ProcWalk.environmentValue("CLAUDE_CONFIG_DIR", forPid: pid).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("sessions/\(pid).json")) else { return nil }
        return ClaudeRegistryRecord.parse(data, expectedPid: pid)
    }

    /// The registry directory of `session`: its transcript's config directory, or nil for the fallback.
    static func configDir(of session: ActivitySession) -> URL? {
        session.transcriptPath.flatMap(ClaudeRegistryRecord.configDir(fromTranscriptPath:))
    }
}
