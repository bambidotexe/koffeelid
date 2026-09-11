import Foundation

/// Two lines: pid, then the executable path (so the watchdog can relaunch the same bundle).
public struct PidFileRecord: Equatable {
    public let pid: Int32
    public let executablePath: String

    public init(pid: Int32, executablePath: String) { self.pid = pid; self.executablePath = executablePath }

    public init?(contents: String) {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[0].trimmingCharacters(in: .whitespaces)),
              !lines[1].isEmpty else { return nil }
        self.pid = pid; self.executablePath = lines[1]
    }

    public var serialized: String { "\(pid)\n\(executablePath)\n" }
}

public enum AppSupport {
    public static let appName = "KoffeeLid"
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }
    public static var pidFileURL: URL { directory.appendingPathComponent("koffeelid.pid") }
    public static var relaunchHistoryURL: URL { directory.appendingPathComponent("relaunch-history.json") }
    public static var diagnosticsURL: URL { directory.appendingPathComponent("diagnostics.log") }
    public static var brightnessRecoveryURL: URL { directory.appendingPathComponent("display-brightness-recovery.json") }
    /// Present while the root-backed sleep lock (`pmset disablesleep 1`) is engaged by this app; a stale one at launch means a crashed instance left the Mac unable to sleep.
    public static var sleepLockMarkerURL: URL { directory.appendingPathComponent("sleep-lock") }
    public static var activityJournalURL: URL { directory.appendingPathComponent("activity.jsonl") }
    public static var activityJournalRotatedURL: URL { directory.appendingPathComponent("activity.1.jsonl") }
}
