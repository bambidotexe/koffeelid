import Foundation

/// The Updates group of the Settings window: one version row carrying the last answer as its mark, and
/// one button. The button looks for a release, and once a newer one is known it fetches that release
/// instead; the release stays the thing to fetch through a download and its outcome, so after a failed
/// download the same button is the retry. Nothing happens without a press.
public struct UpdatePanel: Equatable {
    public enum State: Equatable {
        case idle, checking, upToDate
        case available(ReleaseVersion)
        case checkFailed(String)
        case downloading, downloaded
        case downloadFailed(String)
    }

    /// What a press of the button starts.
    public enum Press: Equatable {
        case check
        case download(LatestRelease)
    }

    public private(set) var state: State = .idle
    public private(set) var pendingRelease: LatestRelease?

    public init() {}

    public var isBusy: Bool { state == .checking || state == .downloading }

    /// The button reads "Update" rather than "Check for Updates".
    public var offersUpdate: Bool { pendingRelease != nil }

    /// The button is the prominent one only while a newer release waits to be fetched.
    public var isProminent: Bool {
        if case .available = state { return true }
        return false
    }

    /// The version row's mark; nil before the first check, when there is nothing to report.
    public var severity: StatusSeverity? {
        switch state {
        case .idle: return nil
        case .checking, .downloading: return .busy
        case .upToDate, .downloaded: return .good
        case .available: return .info
        case .checkFailed, .downloadFailed: return .warning
        }
    }

    /// nil while a check or a download is in flight: a second press starts no second request.
    public mutating func press() -> Press? {
        guard !isBusy else { return nil }
        if let release = pendingRelease {
            state = .downloading
            return .download(release)
        }
        state = .checking
        return .check
    }

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

    public mutating func downloaded() { state = .downloaded }

    public mutating func downloadFailed(_ reason: String) { state = .downloadFailed(reason) }
}
