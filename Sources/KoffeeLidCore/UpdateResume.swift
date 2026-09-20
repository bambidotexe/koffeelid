import Foundation

/// What Install and Relaunch leaves for the version it starts: the manual mode that was on when the user clicked.
/// Quitting disarms, as every quit does, and the user who clicked expects the app back the way it was. The
/// promise only holds for the relaunch the user is watching: one that comes later than `window` (the Mac slept
/// in between, the helper was held up) arms nothing behind their back. The auto level needs no such note: it
/// arms again by its own rule.
public struct UpdateResume: Equatable {
    /// Seconds from the click within which the new version still goes back to the mode.
    public static let window: TimeInterval = 120

    public let mode: ArmMode
    public let writtenAt: Date

    public init(mode: ArmMode, writtenAt: Date) { self.mode = mode; self.writtenAt = writtenAt }

    /// "<mode> <seconds since 1970>"; nil for anything else.
    public init?(contents: String) {
        let words = contents.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count == 2, let mode = ArmMode(rawValue: String(words[0])), let seconds = TimeInterval(words[1]) else { return nil }
        self.init(mode: mode, writtenAt: Date(timeIntervalSince1970: seconds))
    }

    public var contents: String { "\(mode.rawValue) \(Int(writtenAt.timeIntervalSince1970))" }

    /// The mode to go back to, or nil: it was Off, the relaunch came too late, or the clock moved back.
    public func modeToRestore(now: Date) -> ArmMode? {
        guard mode != .off else { return nil }
        let elapsed = now.timeIntervalSince(writtenAt)
        return (0...Self.window).contains(elapsed) ? mode : nil
    }
}
