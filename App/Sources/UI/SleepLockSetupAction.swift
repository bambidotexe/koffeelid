import AppKit

/// "Set up…" for the sleep lock: the administrator-password dialog, then the armed session (if any)
/// engages the lock at once. Failures other than Cancel get an alert; everything is logged.
enum SleepLockSetupAction {
    @MainActor @discardableResult
    static func run(from window: NSWindow?) -> Bool {
        switch SleepLock.installRule() {
        case .done:
            DiagnosticLog.shared.log("sleep lock sudoers rule installed from Settings/onboarding")
            KoffeeLidController.shared.sleepLockRuleChanged()
            return true
        case .cancelled:
            DiagnosticLog.shared.log("sleep lock setup cancelled by the user")
            return false
        case .failed(let message):
            DiagnosticLog.shared.log("sleep lock setup FAILED: \(message)")
            let a = NSAlert()
            a.messageText = L("The sleep lock could not be set up")
            a.informativeText = message
            a.alertStyle = .warning
            if let window { a.beginSheetModal(for: window) } else { a.runModal() }
            return false
        }
    }
}
