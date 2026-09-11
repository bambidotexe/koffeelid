import Foundation
import CoreGraphics
import KoffeeLidCore

final class LidReopenLockController {
    private typealias LockFn = @convention(c) () -> Int32
    private let lockFn: LockFn?
    private let policy: LidReopenLockRetryPolicy
    private var attempt = 0
    private var timer: Timer?
    var onLog: ((String) -> Void)?
    var onGaveUp: (() -> Void)?

    init(policy: LidReopenLockRetryPolicy = .init()) {
        self.policy = policy
        let h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY)
        lockFn = h.flatMap { dlsym($0, "SACLockScreenImmediate") }.map { unsafeBitCast($0, to: LockFn.self) }
    }

    static var isScreenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func requestLock() {
        cancel()
        attempt = 0
        fire()
    }

    @discardableResult
    func cancel() -> Bool {
        let had = timer != nil
        timer?.invalidate()
        timer = nil
        return had
    }

    private func fire() {
        if Self.isScreenLocked { onLog?("lid-open lock confirmed"); return }
        if let f = lockFn {
            let r = f()
            onLog?(r == 0 ? "lid-open native Lock Screen requested through loginwindow" : "lid-open native Lock Screen request failed (\(r))")
        } else {
            onLog?("lid-open native Lock Screen request failed (login.framework symbol missing)")
        }
        guard let delay = policy.delay(forAttempt: attempt) else {
            onLog?("lid-open lock still unconfirmed; giving up"); onGaveUp?(); return
        }
        attempt += 1
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if Self.isScreenLocked { self.onLog?("lid-open lock confirmed") } else { self.onLog?("lid-open lock still unconfirmed; retrying until macOS reports locked"); self.fire() }
        }
    }
}
