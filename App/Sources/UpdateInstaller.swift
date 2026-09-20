import Foundation
import KoffeeLidCore

/// Whether this app can replace itself where it is installed, and the start of the helper that does it once the
/// app has quit (`UpdateInstallScript`).
enum UpdateInstaller {
    enum Obstacle: String {
        /// Not running from an app bundle: a binary started out of a build folder.
        case notInstalled
        /// Started from a quarantined download: macOS runs it from a read-only copy somewhere else.
        case translocated
        case notWritable
        /// The update is unpacked on another volume than the app's, where a move is a copy and not one rename.
        case otherVolume
    }

    /// nil when the app can be replaced in place; otherwise the disk image is the way, by hand.
    static func obstacle(bundle: URL = Bundle.main.bundleURL, updatesDirectory: URL) -> Obstacle? {
        guard bundle.pathExtension == "app" else { return .notInstalled }
        guard !bundle.path.contains("/AppTranslocation/") else { return .translocated }
        let files = FileManager.default
        let folder = bundle.deletingLastPathComponent()
        guard files.isWritableFile(atPath: folder.path), files.isWritableFile(atPath: bundle.path) else { return .notWritable }
        try? files.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
        let here = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let there = try? updatesDirectory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let here, let there, here.isEqual(there) else { return .otherVolume }
        return nil
    }

    /// Writes the helper next to the update and starts it on its own: it waits for this process to exit. The
    /// helper's pid, for `stop`.
    static func start(_ plan: UpdateInstallPlan, script: URL) throws -> Int32 {
        try UpdateInstallScript.text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return try DetachedProcess.spawn(executable: "/bin/sh", arguments: [script.path] + plan.arguments,
                                         environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    /// Ends a helper that is still waiting for this app to quit. While the app runs the helper can be nowhere
    /// else than in that wait, where it has touched nothing; and a child's pid is not given to another process
    /// before its parent has gone.
    static func stop(_ helper: Int32) { kill(helper, SIGTERM) }
}
