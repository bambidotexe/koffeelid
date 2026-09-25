import AppKit
import KoffeeLidCore

struct ActivitySnapshot: Equatable {
    var running = false
    var claudeSessions = 0
    var codexSessions = 0
    var runningJobs = 0
    /// The apps hosting the running commands' shells (`ActivityBadge.terminal(hosting:)`).
    var terminalBadges: Set<ActivityBadge> = []
    var workingSessions: Int { claudeSessions + codexSessions }
    /// The kinds with something running, for `ActivityArmPolicy`.
    var kinds: Set<ActivityKind> {
        var kinds: Set<ActivityKind> = []
        if claudeSessions > 0 { kinds.insert(.claude) }
        if codexSessions > 0 { kinds.insert(.codex) }
        if runningJobs > 0 { kinds.insert(.terminal) }
        return kinds
    }
    /// The apps at work, for the auto-armed cup and the menu's auto-arm line.
    var badges: Set<ActivityBadge> {
        var badges = terminalBadges
        if claudeSessions > 0 { badges.insert(.claude) }
        if codexSessions > 0 { badges.insert(.codex) }
        return badges
    }
    /// For the status line and the log. Not localized: it is CLI/log text.
    var summary: String {
        let s = workingSessions == 1 ? "1 session working" : "\(workingSessions) sessions working"
        let j = runningJobs == 1 ? "1 command" : "\(runningJobs) commands"
        return "\(s) (Claude Code \(claudeSessions), Codex \(codexSessions)), \(j)"
    }
}

/// Owns the two stores; tails the activity journal; watches agent and shell pids; runs the time rules, the
/// registry rescues and the rollout checks; reports the aggregate "running" level to the coordinator. Main
/// thread only.
@MainActor
final class ActivityMonitor {
    var onChange: ((ActivitySnapshot) -> Void)?
    var onLog: ((String) -> Void)?
    var jobArmAfterSeconds: Double = ActivityConstants.jobArmAfterDefaultSeconds
    private(set) var snapshot = ActivitySnapshot()
    /// The last Claude Code hook event, the last Codex hook event and the last terminal command event this
    /// monitor took in, from this boot's replay onwards: the Health page's proof that each hook still reports.
    private(set) var lastClaudeEvent: HookEventSeen?
    private(set) var lastCodexEvent: HookEventSeen?
    private(set) var lastTerminalEventAt: Date?

    private var sessions = ActivitySessionStore()
    private var jobs = ActivityJobStore()
    private let tailer = ActivityJournalTailer(url: AppSupport.activityJournalURL)
    private let watcher = ActivityProcessWatcher(queue: .main)
    private var timer: Timer?
    private var started = false
    private var warnedNoRegistry: Set<String> = []
    private var warnedHooksSilent: Set<String> = []
    private var warnedNoRollout: Set<String> = []
    /// Whether each Codex pid seen is Codex's managed daemon, read once per pid (its arguments do not change).
    private var codexDaemonPids: [Int32: Bool] = [:]
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
        sessions.pruneDead { pid, agent in ProcWalk.isAlive(pid: pid) && ProcWalk.looksLike(agent, pid: pid) }
        for job in jobs.jobs.values { if let pid = job.ownerPid, !ProcWalk.isAlive(pid: pid) { jobs.processExited(pid: pid) } }
        onLog?("activity: replayed \(replayed.count) events, \(sessions.sessions.count) sessions, \(jobs.jobs.count) jobs")
        // Before anything counts: a replayed Codex turn that ended while the app was down ends here. This
        // check only ends turns; nothing replayed is started by it.
        checkCodex(now: Date(), atLaunch: true)
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
            noteSeen(e)
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
        sessions.markDaemonHosted { [self] pid in isCodexDaemon(pid) }
    }

    private func isCodexDaemon(_ pid: Int32) -> Bool {
        if let known = codexDaemonPids[pid] { return known }
        let daemon = ProcWalk.info(for: pid).map(ProcWalk.isCodexDaemon) ?? false
        codexDaemonPids[pid] = daemon
        return daemon
    }

    /// A line that could not be parsed proves nothing about either hook.
    private func noteSeen(_ e: ActivityEvent) {
        switch e.event {
        case .parseError: break
        case .jobBegin, .jobEnd:
            if lastTerminalEventAt.map({ e.loggedAt > $0 }) ?? true { lastTerminalEventAt = e.loggedAt }
        default:
            let seen = HookEventSeen(name: e.event.rawValue, at: e.loggedAt)
            switch e.effectiveAgent {
            case .claude: if lastClaudeEvent.map({ e.loggedAt > $0.at }) ?? true { lastClaudeEvent = seen }
            case .codex: if lastCodexEvent.map({ e.loggedAt > $0.at }) ?? true { lastCodexEvent = seen }
            }
        }
    }

    private func apply(_ events: [ActivityEvent]) {
        ingest(events)
        sync()
    }

    private func processExited(_ pid: Int32) {
        sessions.processExited(pid: pid); jobs.processExited(pid: pid)
        codexDaemonPids.removeValue(forKey: pid)
        sync()
    }

    // MARK: time

    private func sync() {
        guard started else { return }
        let now = Date()
        sessions.tick(now: now); jobs.tick(now: now)
        checkRegistry(now: now)
        checkCodex(now: now, atLaunch: false)
        watcher.unwatchAll(except: sessions.trackedPids.union(jobs.trackedPids))
        for pid in sessions.trackedPids.union(jobs.trackedPids) { watcher.watch(pid: pid) }
        rotateIfNeeded()
        publish(now: now)
        scheduleNext(now: now)
    }

    private func publish(now: Date) {
        let new = ActivitySnapshot(running: sessions.isRunning || jobs.isRunning(at: now),
                                   claudeSessions: sessions.workingCount(of: .claude), codexSessions: sessions.workingCount(of: .codex),
                                   runningJobs: jobs.runningCount(at: now),
                                   terminalBadges: Set(jobs.runningOwnerPids(at: now).map { ActivityBadge.terminal(hosting: ProcWalk.chain(from: $0)) }))
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

    /// Esc/Ctrl-C fire no hook in Claude Code: ask its own registry about quiet turns and open dialogs. The
    /// store hands over Claude Code sessions only; Codex's are `checkCodex`'s.
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

    /// A lost `Stop` or `Interrupt` leaves a Codex turn working with nothing to end it, and the pid its hooks
    /// record is usually Codex's daemon, alive across every session: read the session's rollout instead. At
    /// launch every working Codex session is read, without the quiet gate. Only ends turns.
    private func checkCodex(now: Date, atLaunch: Bool) {
        for (sid, recorded) in sessions.codexCandidates(at: now, quietSeconds: atLaunch ? 0 : ActivityConstants.abandonQuietSeconds) {
            guard let session = sessions.sessions[sid] else { continue }
            let path = recorded.flatMap { CodexRolloutTail.isRollout(path: $0, ofSession: sid) ? $0 : nil } ?? CodexRollout.locate(sessionId: sid)
            let verdict = path.flatMap(CodexRollout.read(path:)).map { CodexRolloutTail.verdict(tail: $0) } ?? .unreadable
            switch verdict {
            case .complete(let at) where at > session.lastMainEventAt:
                onLog?("activity: quiet Codex turn \(sid.prefix(8)) — rollout says finished, turn over")
                sessions.turnOver(sessionId: sid, now: now)
            case .aborted(let at) where at > session.lastMainEventAt:
                onLog?("activity: quiet Codex turn \(sid.prefix(8)) — rollout says aborted, turn over")
                sessions.turnOver(sessionId: sid, now: now)
            case .running:
                if now.timeIntervalSince(session.lastMainEventAt) >= ActivityConstants.hooksSilentWarnSeconds, warnedHooksSilent.insert(sid).inserted {
                    onLog?("activity: hooks look dead for \(sid.prefix(8)) — rollout says running, no hook for 5 min")
                }
                sessions.noteBusy(sessionId: sid, now: now)
            case .unreadable:
                if warnedNoRollout.insert(sid).inserted { onLog?("activity: no rollout for Codex session \(sid.prefix(8)); only staleness can end it") }
            case .complete, .aborted:
                break // an end stamped before our last event is the previous turn's
            }
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
