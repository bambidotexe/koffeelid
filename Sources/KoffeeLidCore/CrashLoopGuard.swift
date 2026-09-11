import Foundation

/// Permits at most `maxRelaunches` within a sliding `window`.
public struct CrashLoopGuard {
    public let maxRelaunches: Int
    public let window: TimeInterval
    public private(set) var history: [Date]

    public init(maxRelaunches: Int = 3, window: TimeInterval = 600, history: [Date] = []) {
        self.maxRelaunches = maxRelaunches; self.window = window; self.history = history
    }

    public mutating func permitRelaunch(at now: Date) -> Bool {
        history.removeAll { now.timeIntervalSince($0) > window }
        guard history.count < maxRelaunches else { return false }
        history.append(now)
        return true
    }
}
