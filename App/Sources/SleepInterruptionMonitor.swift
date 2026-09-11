import AppKit

/// Fires on `willSleep` while we are armed. The coordinator reads the root domain's sleep reason to tell an
/// external request (pmset, Apple menu) from a clamshell evaluation powerd provoked (`SleepInterruptionPolicy`).
final class SleepInterruptionMonitor {
    var armed = false
    var onExternalSleep: (() -> Void)?
    private var observer: NSObjectProtocol?
    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.armed else { return }; self.onExternalSleep?()
        }
    }
    func stop() { if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }; observer = nil }
}
