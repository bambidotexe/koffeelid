import Foundation

/// The rules that turn what was found into a level. Every page that reports one of these states reads it
/// from here, so the System page's grant rows and the Health table agree.
public enum HealthRules {
    /// A macOS permission, or something set up outside KoffeeLid that a feature needs (the sleep lock, the
    /// watchdog agent, the hooks): green while it is in place; missing, **red when the onboarding marks it
    /// required** (a closed Mac cannot be kept awake safely without it) and orange otherwise (the feature
    /// that needs it cannot work, and the rest can).
    public static func grant(held: Bool, required: Bool) -> HealthLevel {
        if held { return .good }
        return required ? .failure : .warning
    }

    /// macOS's lid sleep, which the kernel flag turns off. Off while armed and on while not is as it should
    /// be, and nothing to report. On while armed is an arm that holds nothing: red. Still off after the arm
    /// ended is a Mac that will not sleep when its lid closes, which KoffeeLid keeps retrying: orange, as the
    /// menu bar cup is. Nil while it is as it should be: the line is on the table only while it is wrong.
    public static func lidSleep(armed: Bool, flagSet: Bool, restorePending: Bool) -> HealthLevel? {
        if restorePending { return .warning }
        if armed { return flagSet ? nil : .failure }
        return flagSet ? .warning : nil
    }

    /// The lid-angle sensor: the gesture and the effect need it, and everything else works without it.
    public static func lidSensor(present: Bool) -> HealthLevel {
        present ? .good : .warning
    }
}

extension HealthRules {
    /// Whether a file in `~/Library/Logs/DiagnosticReports` is a crash report of the process named
    /// `process`: the name, a dash, the date the system stamps (`KoffeeLid-2026-09-21-101010.ips`), and the
    /// extension of a crash report old or new. A user fault of the same process (`ExcUserFault_…`), or
    /// another process whose name merely starts the same way (`KoffeeLidWatchdog-…`), is not.
    public static func isCrashReport(fileName: String, process: String) -> Bool {
        guard fileName.hasPrefix(process + "-"), fileName.hasSuffix(".ips") || fileName.hasSuffix(".crash")
        else { return false }
        let stamp = fileName.dropFirst(process.count + 1)
        // yyyy-MM-dd-HHmmss, digits where the date's digits go.
        let pattern = Array("0000-00-00-000000")
        guard stamp.count > pattern.count else { return false }
        return zip(stamp, pattern).allSatisfy { char, slot in slot == "-" ? char == "-" : char.isASCII && char.isNumber }
    }
}

/// The crash reports macOS wrote for a process. They are the user's own files, readable without any
/// permission, and the one record of a crash the app itself cannot keep: it was not running to write it.
public enum CrashReports {
    /// Where macOS writes a user process's crash reports, and the folder it moves them to once they have
    /// been read or sent.
    public static var folders: [URL] {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// When each crash report of `process` written after `since` was written, newest first. A folder that
    /// cannot be read counts nothing: the Health page then says there was no crash, which is what the only
    /// evidence says.
    public static func recent(process: String, since: Date, in folders: [URL] = folders) -> [Date] {
        var dates: [Date] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where HealthRules.isCrashReport(fileName: file.lastPathComponent, process: process) {
                guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, date > since else { continue }
                dates.append(date)
            }
        }
        return dates.sorted(by: >)
    }
}
