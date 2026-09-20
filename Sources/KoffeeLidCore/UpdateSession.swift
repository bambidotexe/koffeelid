import Foundation

/// The update window, from the press of Update to the moment the app quits: the release is fetched, then made
/// ready (checked, unpacked, checked again) while the app is still running, so the one thing left for after the
/// quit is to swap two folders. "Install and Relaunch" is enabled in `ready` and nowhere else.
public struct UpdateSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case downloading(received: Int64, expected: Int64?)
        case preparing
        case ready
        /// Fetched, but the app cannot replace itself where it is installed: the disk image is the way.
        case manual
        case installing
        case failed(String)
    }

    public let release: LatestRelease
    public private(set) var phase: Phase
    /// The last Install and Relaunch did not get the app to quit; the window says so until the next try.
    public private(set) var stalled = false

    public init(release: LatestRelease) {
        self.release = release
        phase = .downloading(received: 0, expected: release.dmgSize)
    }

    /// The bar, 0 to 1; nil when there is no total to measure against, which draws it indeterminate.
    public var fraction: Double? {
        switch phase {
        case .downloading(let received, let expected):
            guard let expected, expected > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(expected)))
        case .ready, .manual: return 1
        case .preparing, .installing, .failed: return nil
        }
    }

    public var canInstall: Bool { phase == .ready }
    public var canCancel: Bool { phase != .installing }

    /// A response that states no length (`expected` ≤ 0) leaves GitHub's own figure for the asset as the total.
    public mutating func received(_ bytes: Int64, of expected: Int64) {
        guard case .downloading = phase else { return }
        phase = .downloading(received: bytes, expected: expected > 0 ? expected : release.dmgSize)
    }

    public mutating func downloaded() {
        guard case .downloading = phase else { return }
        phase = .preparing
    }

    public mutating func prepared() {
        guard phase == .preparing else { return }
        phase = .ready
    }

    public mutating func cannotReplace() {
        guard phase == .preparing else { return }
        phase = .manual
    }

    /// True once: the click that starts the install. Anything else, a second click included, starts nothing.
    public mutating func install() -> Bool {
        guard phase == .ready else { return false }
        phase = .installing
        stalled = false
        return true
    }

    /// The app is still running well after it was asked to quit. What was prepared is still good.
    public mutating func installStalled() {
        guard phase == .installing else { return }
        phase = .ready
        stalled = true
    }

    public mutating func failed(_ reason: String) {
        guard phase != .installing else { return }
        phase = .failed(reason)
    }

    /// True when there was a failure to retry: the release is fetched again from the start.
    public mutating func retry() -> Bool {
        guard case .failed = phase else { return false }
        phase = .downloading(received: 0, expected: release.dmgSize)
        return true
    }
}
