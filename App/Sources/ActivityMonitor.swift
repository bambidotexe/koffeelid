import AppKit
import KoffeeLidCore

struct ActivitySnapshot: Equatable {
    var running = false
    var workingSessions = 0
    var runningJobs = 0
    /// The kinds with something running, for `ActivityArmPolicy`.
    var kinds: Set<ActivityKind> { Set((workingSessions > 0 ? [ActivityKind.claude] : []) + (runningJobs > 0 ? [.terminal] : [])) }
    /// For the status line and the Advanced page. Not localized: it is CLI/log text.
    var summary: String {
        let s = workingSessions == 1 ? "1 session working" : "\(workingSessions) sessions working"
        let j = runningJobs == 1 ? "1 command" : "\(runningJobs) commands"
        return "\(s), \(j)"
    }
}

/// Owns the two stores; tails the activity journal; watches Claude and shell pids; runs the time rules and
/// the registry rescues; reports the aggregate "running" level to the coordinator. Main thread only.
@MainActor
final class ActivityMonitor {
    var onChange: ((ActivitySnapshot) -> Void)?
    var onLog: ((String) -> Void)?
    var jobArmAfterSeconds: Double = ActivityConstants.jobArmAfterDefaultSeconds
    private(set) var snapshot = ActivitySnapshot()

    private var sessions = ActivitySessionStore()
    private var jobs = ActivityJobStore()
    private let tailer = ActivityJournalTailer(url: AppSupport.activityJournalURL)
    private let watcher = ActivityProcessWatcher(queue: .main)
    private var timer: Timer?
    private var started = false
    private var warnedNoRegistry: Set<String> = []
    private var warnedHooksSilent: Set<String> = []
    private var wakeObserver: NSObjectProtocol?

    static var isDisabledByEnvironment: Bool { ProcessInfo.processInfo.environment["KOFFEELID_DISABLE_ACTIVITY"] == "1" }

    func start() {
        guard !started else { return }
        if Self.isDisabledByEnvironment { onLog?("activity: disabled by KOFFEELID_DISABLE_ACTIVITY"); return }
        started = true
        watcher.onExit = { [weak self] pid in self?.processExited(pid) }
        // Replay: events from this boot only, then prune dead or recycled pids.
        let boot = Self.bootDate() ?? .distantPast
        let currentData = (try? Data(contentsOf: AppSupport.activityJournalURL)) ?? Data()
        let currentEvents = currentData.split(separator: 0x0A).compactMap { ActivityCodec.decodeLine(Data($0)) }
        let replayed = (ActivityJournalWriter.readAll(url: AppSupport.activityJournalRotatedURL) + currentEvents)
            .filter { $0.loggedAt >= boot }
        ingest(replayed)
        sessions.pruneDead { ProcWalk.isAlive(pid: $0) && ProcWalk.looksLikeClaude(pid: $0) }
        for job in jobs.jobs.values { if let pid = job.ownerPid, !ProcWalk.isAlive(pid: pid) { jobs.processExited(pid: pid) } }
        onLog?("activity: replayed \(replayed.count) events, \(sessions.sessions.count) sessions, \(jobs.jobs.count) jobs")
        rotateIfNeeded()
        // Live: replay consumed currentData.count bytes of the current journal; the tailer begins exactly
        // there, so nothing already replayed is applied twice and anything appended since is still delivered.
        tailer.onEvents = { [weak self] events in Task { @MainActor in self?.apply(events) } }
        tailer.start(fromOffset: UInt64(currentData.count))
        onLog?("activity: hooks journal tailing")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        sync()
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.unwatchAll(except: []); watcher.onExit = nil
        tailer.stop()
        timer?.invalidate(); timer = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    /// Re-run every time rule against the wall clock (wake, preference change).
    func refresh() { sync() }

    // MARK: ingestion

    private func ingest(_ events: [ActivityEvent]) {
        for e in events {
            switch e.event {
            case .jobBegin:
                guard let id = e.jobId else { continue }
                jobs.begin(id: id, pid: e.jobPid, label: e.jobLabel, armAfterSeconds: e.jobArmAfterSeconds ?? jobArmAfterSeconds, now: e.loggedAt)
            case .jobEnd:
                if let id = e.jobId { jobs.end(id: id) }
            case .parseError:
                onLog?("activity: unparseable hook payload (\(e.rawPrefix?.prefix(60) ?? ""))")
            default:
                sessions.apply(e)
            }
        }
    }

    private func apply(_ events: [ActivityEvent]) {
        ingest(events)
        sync()
    }

    private func processExited(_ pid: Int32) {
        sessions.processExited(pid: pid); jobs.processExited(pid: pid)
        sync()
    }

    // MARK: time

    private func sync() {
        guard started else { return }
        let now = Date()
        sessions.tick(now: now); jobs.tick(now: now)
        checkRegistry(now: now)
        watcher.unwatchAll(except: sessions.trackedPids.union(jobs.trackedPids))
        for pid in sessions.trackedPids.union(jobs.trackedPids) { watcher.watch(pid: pid) }
        rotateIfNeeded()
        publish(now: now)
        scheduleNext(now: now)
    }

    private func publish(now: Date) {
        let new = ActivitySnapshot(running: sessions.isRunning || jobs.isRunning(at: now),
                                   workingSessions: sessions.workingCount, runningJobs: jobs.runningCount(at: now))
        guard new != snapshot else { return }
        if new.running != snapshot.running { onLog?(new.running ? "activity: running (\(new.summary))" : "activity: idle") }
        snapshot = new
        onChange?(new)
    }

    private func scheduleNext(now: Date) {
        timer?.invalidate(); timer = nil
        let deadlines = [sessions.nextDeadline(after: now), jobs.nextDeadline(after: now)].compactMap { $0 }
        guard let next = deadlines.min() else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in Task { @MainActor in self?.sync() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Esc/Ctrl-C fire no hook: ask Claude Code's own registry about quiet turns and open dialogs.
    private func checkRegistry(now: Date) {
        for (sid, pid) in sessions.abandonCandidates(at: now) {
            guard let record = ClaudeProcessRegistry.read(pid: pid), record.sessionId == sid else {
                if warnedNoRegistry.insert(sid).inserted { onLog?("activity: no registry record for pid \(pid) (session \(sid.prefix(8))); only staleness can end it") }
                continue
            }
            guard let session = sessions.sessions[sid] else { continue }
            if record.isIdle, let stamped = record.statusUpdatedAt, stamped > session.lastMainEventAt {
                onLog?("activity: quiet turn \(sid.prefix(8)) — registry idle, turn over")
                sessions.turnOver(sessionId: sid, now: now)
            } else if record.isBusy {
                if now.timeIntervalSince(session.lastMainEventAt) >= ActivityConstants.hooksSilentWarnSeconds, warnedHooksSilent.insert(sid).inserted {
                    onLog?("activity: hooks look dead for \(sid.prefix(8)) — registry busy, no hook for 5 min")
                }
                sessions.noteBusy(sessionId: sid, now: now)
            }
        }
        for (sid, pid, since) in sessions.openWaitCandidates() {
            guard let record = ClaudeProcessRegistry.read(pid: pid), record.sessionId == sid, record.isBusy,
                  let stamped = record.statusUpdatedAt, stamped.timeIntervalSince(since) > ActivityConstants.dialogAnswerMinStampLeadSeconds else { continue }
            onLog?("activity: dialog answered without a hook (\(sid.prefix(8))); back to working")
            sessions.dialogAnswered(sessionId: sid, now: now)
        }
    }

    // MARK: journal housekeeping

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: AppSupport.activityJournalURL.path)[.size] as? Int) else { return }
        let idle = !sessions.isRunning && !jobs.isRunning(at: Date())
        guard size > ActivityConstants.journalRotateHardBytes || (idle && size > ActivityConstants.journalRotateIdleBytes) else { return }
        try? fm.removeItem(at: AppSupport.activityJournalRotatedURL)
        if (try? fm.moveItem(at: AppSupport.activityJournalURL, to: AppSupport.activityJournalRotatedURL)) != nil { onLog?("activity: journal rotated") }
    }

    static func bootDate() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]; var tv = timeval(); var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// The embedded hook binary next to the app binary — what `install-hooks` and `shell-init` point at.
    static var hookBinaryURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KoffeeLidHook") }
}
