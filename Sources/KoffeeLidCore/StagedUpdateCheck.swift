import Foundation

/// What the copy taken out of a release's disk image has to say about itself before it may replace the running
/// app. Its signature is the app layer's question; these are the three its `Info.plist` answers.
public enum StagedUpdateCheck {
    public struct Facts: Equatable, Sendable {
        public let bundleIdentifier: String?
        public let version: String?
        public let minimumSystemVersion: String?

        public init(bundleIdentifier: String?, version: String?, minimumSystemVersion: String?) {
            self.bundleIdentifier = bundleIdentifier; self.version = version; self.minimumSystemVersion = minimumSystemVersion
        }
    }

    public enum Rejection: Equatable, Error, Sendable {
        case wrongApp
        /// The copy's version as it states it. Installing the same or an older version would offer the same
        /// update again at the next check, for ever.
        case notNewer(String?)
        /// The macOS the copy asks for.
        case needsNewerSystem(String)
    }

    /// nil when the copy may be installed. A running version that does not parse is never replaced: a binary run
    /// outside its bundle has none, and it is not an installed app.
    public static func rejection(staged: Facts, runningIdentifier: String, runningVersion: String,
                                 systemVersion: ReleaseVersion) -> Rejection? {
        guard let identifier = staged.bundleIdentifier, identifier == runningIdentifier else { return .wrongApp }
        guard let running = ReleaseVersion(string: runningVersion),
              let version = staged.version.flatMap(ReleaseVersion.init(string:)), version > running
        else { return .notNewer(staged.version) }
        if let minimum = staged.minimumSystemVersion, let needed = ReleaseVersion(string: minimum), needed > systemVersion {
            return .needsNewerSystem(minimum)
        }
        return nil
    }
}
