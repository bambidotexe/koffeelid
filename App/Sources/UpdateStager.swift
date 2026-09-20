import Foundation
import KoffeeLidCore

/// Takes the app out of a release's disk image and decides whether it may replace the running one, all of it
/// while the running one is still up: by the time "Install and Relaunch" is enabled, the copy that will be
/// moved into place is on the same volume, is this app, is newer, runs on this macOS and is signed by the same
/// team. Blocking: call it off the main thread.
struct UpdateStager {
    enum StagingError: Error {
        case cannotOpenImage
        case appMissing
        case rejected(StagedUpdateCheck.Rejection)
        case signature(CodeSignature.Failure)
    }

    let bundleIdentifier: String
    let runningVersion: String
    let log: (String) -> Void

    /// The staged bundle: `<directory>/staged/<Name>.app`.
    func stage(diskImage: URL, in directory: URL) throws -> URL {
        let files = FileManager.default
        let mountPoint = directory.appendingPathComponent("mount", isDirectory: true)
        let staging = directory.appendingPathComponent("staged", isDirectory: true)
        Self.detach(mountPoint)   // a mount left behind by a run that was killed
        try? files.removeItem(at: mountPoint)
        try? files.removeItem(at: staging)
        try files.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)

        guard Self.attach(diskImage, at: mountPoint) else { throw StagingError.cannotOpenImage }
        defer {
            Self.detach(mountPoint)
            try? files.removeItem(at: mountPoint)
        }

        let candidates = ((try? files.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        guard let source = candidates.first(where: { Self.facts(of: $0).bundleIdentifier == bundleIdentifier }) else {
            throw StagingError.appMissing
        }
        let staged = staging.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try files.copyItem(at: source, to: staged)

        let system = ProcessInfo.processInfo.operatingSystemVersion
        if let rejection = StagedUpdateCheck.rejection(staged: Self.facts(of: staged), runningIdentifier: bundleIdentifier,
                                                       runningVersion: runningVersion,
                                                       systemVersion: ReleaseVersion(system.majorVersion, system.minorVersion, system.patchVersion)) {
            throw StagingError.rejected(rejection)
        }
        do { try CodeSignature.verify(bundle: staged, requiredTeam: CodeSignature.runningTeamIdentifier()) }
        catch let failure as CodeSignature.Failure { throw StagingError.signature(failure) }
        log("update: staged \(staged.path)")
        return staged
    }

    static func facts(of bundle: URL) -> StagedUpdateCheck.Facts {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        return .init(bundleIdentifier: info?["CFBundleIdentifier"] as? String,
                     version: info?["CFBundleShortVersionString"] as? String,
                     minimumSystemVersion: info?["LSMinimumSystemVersion"] as? String)
    }

    /// Read-only, hidden from the Finder, at a mount point of our own. `hdiutil` first, which every macOS this app
    /// runs on has; `diskutil image`, its successor, where `hdiutil` no longer does it.
    private static func attach(_ image: URL, at mountPoint: URL) -> Bool {
        run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path]) == 0
            || run("/usr/sbin/diskutil", ["image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mountPoint.path, image.path]) == 0
    }

    /// Only ever asked of a folder something is mounted on: a plain folder's path names the volume it sits on,
    /// and that volume is the Mac's own.
    private static func detach(_ mountPoint: URL) {
        guard isMountPoint(mountPoint) else { return }
        if run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) != 0 {
            _ = run("/usr/sbin/diskutil", ["eject", mountPoint.path])
        }
    }

    private static func isMountPoint(_ url: URL) -> Bool {
        var here = stat(), parent = stat()
        guard stat(url.path, &here) == 0, stat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return here.st_dev != parent.st_dev
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
