import Darwin
import Foundation
import KoffeeLidCore

/// What the kernel says about this process: when it started and how much memory it holds. Both are cheap
/// reads of the process's own record, answered at once. The Health page's App group.
enum ProcessStats {
    /// When this process started. Nil if the kernel would not say.
    static var launchDate: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// The memory this process holds, as Activity Monitor's Memory column counts it (`phys_footprint`). Nil if
    /// the kernel would not say.
    static var memoryFootprint: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// Where the running bundle is, in the terms the Health page reports it in. The decision is
/// `HealthRules.location`; this reads the two facts it needs.
enum InstallLocation {
    static func current(bundleURL: URL = Bundle.main.bundleURL) -> AppLocation {
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return HealthRules.location(bundlePath: bundleURL.path,
                                    home: FileManager.default.homeDirectoryForCurrentUser.path,
                                    readOnlyVolume: readOnly)
    }
}

/// The crash watchdog (`KoffeeLidWatchdog`, run by the Background App Activity agent) of this copy of
/// KoffeeLid. While the app runs and the agent is enabled it should always be running: the app kickstarts it
/// at every launch, and launchd restarts it if it dies.
enum WatchdogProcess {
    static var executableURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KoffeeLidWatchdog") }

    /// Reads every process's path (`ProcWalk.isRunning`): a few milliseconds, so off the main thread.
    static var isRunning: Bool { ProcWalk.isRunning(executableAt: executableURL) }
}
