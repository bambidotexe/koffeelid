import AppKit

/// Whether the login session is locked. macOS posts both edges as distributed notifications;
/// `LidReopenLockController.isScreenLocked` reads the current state (`CGSessionCopyCurrentDictionary`)
/// for the cases where no edge fires — a lid that reopens on an already locked screen, or a
/// notification missed in dark wake. Edges are delivered on main.
final class ScreenLockObserver {
    var onChange: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []
    var isLocked: Bool { LidReopenLockController.isScreenLocked }

    func start() {
        let center = DistributedNotificationCenter.default()
        tokens = [
            center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                self?.onChange?(true)
            },
            center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                self?.onChange?(false)
            },
        ]
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        tokens.forEach { center.removeObserver($0) }
        tokens = []
    }
}
