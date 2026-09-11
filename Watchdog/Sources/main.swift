import Foundation
import Darwin
import KoffeeLidCore

let diagnostics = DiagnosticFileWriter(url: AppSupport.diagnosticsURL)
func log(_ m: String) { diagnostics.append(DiagnosticLine.render(Date(), "watchdog: " + m)) }

func bootTime() -> Date? {
    var tv = timeval(); var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
}

func pidFileExists() -> Bool { FileManager.default.fileExists(atPath: AppSupport.pidFileURL.path) }

func readPidFile() -> PidFileRecord? {
    guard let s = try? String(contentsOf: AppSupport.pidFileURL, encoding: .utf8) else { return nil }
    return PidFileRecord(contents: s)
}

/// Full path of the running process at `pid`, or nil if it can't be resolved (e.g. no such process).
func executablePath(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return n > 0 ? String(cString: buffer) : nil
}

/// True if `record.pid` is alive AND still the same executable we observed — pids get reused,
/// so a live pid whose executable no longer matches the recorded one means the app we were
/// watching is actually gone.
func isAlive(_ record: PidFileRecord) -> Bool {
    if kill(record.pid, 0) != 0 && errno != EPERM { return false }
    if let path = executablePath(of: record.pid) {
        let actual = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let expected = URL(fileURLWithPath: record.executablePath).resolvingSymlinksInPath().path
        if actual != expected {
            log("pid \(record.pid) now belongs to a different executable; treating app as dead")
            return false
        }
    }
    return true
}

/// The app bundle is three levels up from Contents/MacOS/KoffeeLidWatchdog — but argv[0] is
/// not a path we can walk up: launchd's BundleProgram form starts us with a *relative* argv[0]
/// ("Contents/MacOS/KoffeeLidWatchdog") and cwd "/", which resolved to "/" and made every
/// launchd-started watchdog (RunAtLoad and kickstart alike) stand down at once. proc_pidpath
/// reports the real absolute path whatever argv[0] says.
let exe = URL(fileURLWithPath: executablePath(of: getpid()) ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
let bundleURL = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard bundleURL.pathExtension == "app" else { log("not running from an app bundle (\(bundleURL.path)); standing down"); exit(0) }

log("started (pid \(getpid())) for \(bundleURL.lastPathComponent) from \(exe.path)")

func relaunch() -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [bundleURL.path]
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { log("open failed: \(error.localizedDescription)"); return false }
}

let historyStore = RelaunchHistoryStore(url: AppSupport.relaunchHistoryURL)
var guardState = CrashLoopGuard(maxRelaunches: 3, window: 600, history: historyStore.load())

while true {
    guard let record = readPidFile() else { log("no app pid file; standing down"); exit(0) }
    if let boot = bootTime(), let mtime = try? FileManager.default.attributesOfItem(atPath: AppSupport.pidFileURL.path)[.modificationDate] as? Date, mtime < boot {
        log("pid file predates this boot; clearing it and standing down")
        try? FileManager.default.removeItem(at: AppSupport.pidFileURL); exit(0)
    }
    log("app pid \(record.pid) observed")
    while isAlive(record) { Thread.sleep(forTimeInterval: 1) }

    // The app removes its pid file on clean exit, so a surviving pid file means it died.
    guard pidFileExists() else { log("app exited cleanly; standing down"); exit(0) }
    if let after = readPidFile() {
        if after.pid != record.pid { log("pid file changed to \(after.pid); following new instance"); continue }
        log("app pid \(record.pid) died with pid file present (unclean); relaunching")
    } else {
        log("pid file unreadable after exit; treating as unclean")
    }

    guard guardState.permitRelaunch(at: Date()) else {
        log("crash loop detected (\(guardState.history.count) relaunches in 10 min); standing down"); exit(0)
    }
    // Persist the attempt before calling open(1), on purpose: a failed relaunch attempt
    // still consumes crash-loop budget, so a bundle that fails to launch repeatedly
    // still trips the guard instead of retrying forever.
    try? historyStore.save(guardState.history)
    guard relaunch() else { log("relaunch failed; standing down"); exit(0) }

    let deadline = Date().addingTimeInterval(30)
    var fresh: PidFileRecord?
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.5)
        if let r = readPidFile(), r.pid != record.pid, isAlive(r) { fresh = r; break }
    }
    guard fresh != nil else { log("relaunched app wrote no pid file within 30s; standing down"); exit(0) }
}
