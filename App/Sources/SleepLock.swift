import Foundation
import KoffeeLidCore

/// Root-backed sleep kill switch: `pmset disablesleep 1` sets `SleepDisabled` on `IOPMrootDomain`, which
/// the kernel checks before *every* sleep request (`checkSystemSleepAllowed`), clamshell evaluations
/// included. It is the only thing that keeps a closed armed Mac awake when powerd rewrites the shared
/// lid-sleep bit (charger attach, display hot-plug — see docs/platform-notes.md). `pmset` needs root, so
/// the commands run through `sudo -n` and depend on the sudoers rule from `SleepLockSetup`; without it
/// the lock is simply unavailable. The setting persists in /Library/Preferences/com.apple.PowerManagement.plist
/// (across reboots), hence the marker file: the next launch that finds it releases the lock.
final class SleepLock {
    var onLog: ((String) -> Void)?
    private(set) var engaged = false
    private let markerURL: URL

    init(markerURL: URL = AppSupport.sleepLockMarkerURL) { self.markerURL = markerURL }

    /// True when sudoers lets this user run the two pmset commands without a password (`sudo -n -l`).
    var isAvailable: Bool { sudo(["-n", "-l"] + SleepLockSetup.pmsetArguments(engaged: true)).status == 0 }

    @discardableResult
    func engage() -> Bool {
        guard !engaged else { return true }
        let r = sudo(["-n"] + SleepLockSetup.pmsetArguments(engaged: true))
        guard r.status == 0 else { onLog?("sleep lock engage FAILED (sudo exit \(r.status): \(r.output))"); return false }
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: markerURL, atomically: true, encoding: .utf8)
        engaged = true
        return true
    }

    @discardableResult
    func release() -> Bool {
        let r = sudo(["-n"] + SleepLockSetup.pmsetArguments(engaged: false))
        guard r.status == 0 else { onLog?("sleep lock release FAILED (sudo exit \(r.status): \(r.output))"); return false }
        try? FileManager.default.removeItem(at: markerURL)
        engaged = false
        return true
    }

    /// Launch recovery: a marker means a previous instance died with the lock on and the Mac cannot sleep.
    func releaseIfMarkerPresent(reason: String) {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        if release() { onLog?("\(reason): stale sleep-lock marker found; sleep re-enabled (pmset disablesleep 0)") }
        else { onLog?("\(reason): stale sleep-lock marker found but pmset could not run; run `sudo pmset disablesleep 0`") }
    }

    // MARK: sudoers rule (Settings / onboarding)

    enum RuleChange { case done, cancelled, failed(String) }

    /// Writes the sudoers rule through macOS's administrator-password dialog (AppleScript
    /// `do shell script … with administrator privileges`, runs as root). Main thread, modal.
    static func installRule() -> RuleChange {
        let user = NSUserName()
        guard SleepLockSetup.isValidUserName(user) else { return .failed(L("The account name cannot be written into a sudoers rule.")) }
        return runPrivileged(SleepLockSetup.privilegedInstallScript(user: user))
    }
    static func removeRule() -> RuleChange { runPrivileged(SleepLockSetup.privilegedRemoveScript) }

    private static func runPrivileged(_ shell: String) -> RuleChange {
        let source = "do shell script \(SleepLockSetup.appleScriptLiteral(shell)) with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed("bad AppleScript source") }
        script.executeAndReturnError(&error)
        guard let error else { return .done }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }   // user cancelled the dialog
        return .failed((error[NSAppleScript.errorMessage] as? String) ?? "\(error)")
    }

    private func sudo(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
