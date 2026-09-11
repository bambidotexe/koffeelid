import Foundation

public struct LidReopenLockRetryPolicy {
    public var delays: [TimeInterval]
    public init(delays: [TimeInterval] = [0.5, 1, 2, 4, 8]) { self.delays = delays }
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        attempt >= 0 && attempt < delays.count ? delays[attempt] : nil
    }
}
