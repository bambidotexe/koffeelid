import Foundation

/// The crash watchdog (`KoffeeLidWatchdog`, run by the Background App Activity agent) of this copy of
/// KoffeeLid. While the app runs and the agent is enabled it should always be running: the app kickstarts it
/// at every launch, and launchd restarts it if it dies. Whether it runs is `ProcWalk.isRunning`, which reads
/// every process's path, so the Health page asks it off the main thread.
enum WatchdogProcess {
    static var executableURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KoffeeLidWatchdog") }
}
