import Foundation

/// The Updates group of the Settings window: one version row carrying the last answer as its mark, and one
/// button. The button looks for a release, and once a newer one is known it opens the update window instead.
/// The app also looks on its own (`UpdateSchedule`); what such a check finds shows here exactly as an answer to
/// a press would, and what it fails to find out stays silent.
public struct UpdatePanel: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle, checking, upToDate
        case available(ReleaseVersion)
        case checkFailed(String)
        /// How the last Install and Relaunch ended, when it did not end with the new version running.
        case installFailed(String)
    }

    /// What a press of the button starts.
    public enum Press: Equatable, Sendable {
        case check
        case update(LatestRelease)
    }

    public private(set) var state: State = .idle
    public private(set) var pendingRelease: LatestRelease?

    public init() {}

    public var isBusy: Bool { state == .checking }

    /// The button reads "Update", prominent, rather than "Check for Updates".
    public var offersUpdate: Bool { pendingRelease != nil }

    /// The version row's mark; nil before the first check, when there is nothing to report.
    public var severity: StatusSeverity? {
        switch state {
        case .idle: return nil
        case .checking: return .busy
        case .upToDate: return .good
        case .available: return .info
        case .checkFailed, .installFailed: return .warning
        }
    }

    /// nil while a check is in flight: a second press starts no second request. With a release known every
    /// press is the same request, which shows the update window again.
    public mutating func press() -> Press? {
        guard !isBusy else { return nil }
        if let release = pendingRelease { return .update(release) }
        state = .checking
        return .check
    }

    /// The answer to a press.
    public mutating func checked(_ decision: UpdateDecision) {
        switch decision {
        case .upToDate:
            pendingRelease = nil
            state = .upToDate
        case .available(let release):
            pendingRelease = release
            state = .available(release.version)
        }
    }

    public mutating func checkFailed(_ reason: String) {
        pendingRelease = nil
        state = .checkFailed(reason)
    }

    /// The answer to a check nobody asked for. It never interrupts a press, and after an install that failed it
    /// keeps the reason on the row while the release it finds again makes the button the retry.
    public mutating func autoChecked(_ decision: UpdateDecision) {
        guard !isBusy else { return }
        if case .installFailed = state, case .available(let release) = decision {
            pendingRelease = release
            return
        }
        checked(decision)
    }

    public mutating func installFailed(_ reason: String) { state = .installFailed(reason) }
}
