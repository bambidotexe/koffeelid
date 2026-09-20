import Foundation

/// When the app looks for a release without being asked: once shortly after launch, then a week after the last
/// check that got an answer, whoever asked. The app puts the question on a coarse tick and at every wake rather
/// than arming one week-long timer, so a Mac that sleeps through the date is asked again as soon as it is awake.
/// A check that could not reach GitHub is tried again an hour later; nothing of this is kept across launches,
/// because every launch checks anyway.
public struct UpdateSchedule: Equatable, Sendable {
    /// After launch, so a Mac that starts the app at login has had time to find its network.
    public static let launchDelay: TimeInterval = 10
    public static let interval: TimeInterval = 7 * 24 * 3600
    public static let retryDelay: TimeInterval = 3600
    /// How often the app asks `isDue`. Shorter than `retryDelay`, so a retry is never a whole tick late.
    public static let tick: TimeInterval = 1800

    public private(set) var lastAnswer: Date?
    public private(set) var lastFailure: Date?

    public init() {}

    public func isDue(now: Date) -> Bool {
        // A date ahead of `now` means the clock was set back: it holds nothing.
        if let lastFailure, lastFailure <= now, now.timeIntervalSince(lastFailure) < Self.retryDelay { return false }
        guard let lastAnswer, lastAnswer <= now else { return true }
        return now.timeIntervalSince(lastAnswer) >= Self.interval
    }

    /// GitHub answered, whatever the answer and whoever asked.
    public mutating func answered(at now: Date) { lastAnswer = now; lastFailure = nil }

    public mutating func failed(at now: Date) { lastFailure = now }
}
