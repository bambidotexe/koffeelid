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
/// registry rescues and the Codex checks (its daemon, its rollouts); reports the aggregate "running" level
/// to the coordinator. Main thread only.
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
    /// What each Codex pid seen is (the managed daemon, a shared host), read once per pid: its path and
    /// arguments do not change.
    private var codexHosts: [Int32: (managed: Bool, shared: Bool)] = [:]
    /// The Codex sessions with a question out to the daemon, and when each may be asked again after an
    /// answer that decided nothing: until then its rollout decides.
    private var askingDaemon: Set<String> = []
    private var daemonAskAgainAt: [String: Date] = [:]
    private var warnedDaemonSilent = false
    private var warnedDaemonStatuses: Set<String> = []
    /// False until the launch checks have answered: nothing is counted or published before them.
    private var launched = false
    private var launchGeneration = 0
    private var wakeObserver: NSObjectProtocol?

    static var isDisabledByEnvironment: Bool { ProcessInfo.processInfo.environment["KOFFEELID_DISABLE_ACTIVITY"] == "1" }

    func start() {
        guard !started else { return }
        if Self.isDisabledByEnvironment { onLog?("activity: disabled by KOFFEELID_DISABLE_ACTIVITY"); return }
        started = true
        watcher.onExit = { [weak self] pid in self?.processExited(pid) }
        // Replay: events from this boot only, the app's own verdicts among them. Before anything counts: the
        // time rules drop what went stale while the app was down; the prune drops dead or recycled pids, a
        // Claude Code pid whose registry record names another session among them; the registry ends each
        // replayed Claude Code turn that ended meanwhile, whatever its quiet; then (`finishLaunch`) each replayed
        // Codex turn: first a thread Codex's managed daemon no longer holds, when it hosts a working session,
        // then the rollouts. These checks only end turns, but for a dialog the registry says was answered, which
        // works again as it would at the first check. Nothing is counted before they have run.
        let boot = Self.bootDate() ?? .distantPast
        let currentData = (try? Data(contentsOf: AppSupport.activityJournalURL)) ?? Data()
        let currentEvents = currentData.split(separator: 0x0A).compactMap { ActivityCodec.decodeLine(Data($0)) }
        let replayed = (ActivityJournalWriter.readAll(url: AppSupport.activityJournalRotatedURL) + currentEvents)
            .filter { $0.loggedAt >= boot }
        ingest(replayed)
        let launch = Date()
        sessions.tick(now: launch); jobs.tick(now: launch)
        let registryDirs = claudeRegistryDirs()
        sessions.pruneDead(isAlive: { pid, agent in ProcWalk.isAlive(pid: pid) && ProcWalk.looksLike(agent, pid: pid) },
                           registrySession: { pid in ClaudeProcessRegistry.read(pid: pid, configDir: registryDirs[pid])?.sessionId })
        for job in jobs.jobs.values { if let pid = job.ownerPid, !ProcWalk.isAlive(pid: pid) { jobs.processExited(pid: pid) } }
        onLog?("activity: replayed \(replayed.count) events, \(sessions.sessions.count) sessions, \(jobs.jobs.count) jobs")
        checkRegistry(now: launch, quietSeconds: 0)
        launched = false
        launchGeneration += 1
        let hosted = daemonHostedWorkingSessions()
        rotateIfNeeded()
        // Live: replay consumed currentData.count bytes of the current journal; the tailer begins exactly
        // there, so nothing already replayed is applied twice and anything appended since is still delivered.
        tailer.onEvents = { [weak self] events in Task { @MainActor in self?.apply(events) } }
        tailer.start(fromOffset: UInt64(currentData.count))
        onLog?("activity: hooks journal tailing")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The daemon answers within `CodexDaemonClient.deadlineSeconds`, or with nil.
        guard !hosted.isEmpty, CodexDaemonClient.socketExists else { return finishLaunch() }
        let generation = launchGeneration
        CodexDaemonClient.loadedThreadIds { [weak self] loaded in
            guard let self, self.started, self.launchGeneration == generation else { return }
            self.daemonListed(loaded, asked: hosted)
            self.finishLaunch()
        }
    }

    /// The rollout check of every working Codex session, then the first count.
    private func finishLaunch() {
        checkCodex(now: Date(), atLaunch: true)
        launched = true
        sync()
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.unwatchAll(except: []); watcher.onExit = nil
        tailer.stop()
        timer?.invalidate(); timer = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        // A question still out is answered into a stopped monitor and dropped; the next start asks afresh.
        askingDaemon.removeAll(); daemonAskAgainAt.removeAll()
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
        sessions.markCodexHosts(isManagedDaemon: { [self] pid in codexHost(pid).managed },
                                isSharedHost: { [self] pid in codexHost(pid).shared })
    }

    private func codexHost(_ pid: Int32) -> (managed: Bool, shared: Bool) {
        if let known = codexHosts[pid] { return known }
        var host = (managed: false, shared: false)
        if let info = ProcWalk.info(for: pid) {
            let arguments = ProcWalk.arguments(forPid: pid) ?? []
            host = (ProcWalk.isManagedCodexDaemon(path: info.path, arguments: arguments),
                    ProcWalk.isSharedCodexHost(path: info.path, arguments: arguments))
        }
        codexHosts[pid] = host
        return host
    }

    /// A line that could not be parsed proves nothing about either hook, and a verdict line is the app's own.
    private func noteSeen(_ e: ActivityEvent) {
        switch e.event {
        case .parseError, .verdict: break
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
        codexHosts.removeValue(forKey: pid)
        sync()
    }

    // MARK: time

    private func sync() {
        guard started, launched else { return }
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

    /// Esc/Ctrl-C fire no hook in Claude Code: ask its own registry, in the session's transcript's config
    /// directory, about quiet turns and open dialogs. The store hands over Claude Code sessions only; Codex's are
    /// `checkCodex`'s. At launch the quiet gate is 0.
    private func checkRegistry(now: Date, quietSeconds: TimeInterval = ActivityConstants.abandonQuietSeconds) {
        for (sid, pid) in sessions.abandonCandidates(at: now, quietSeconds: quietSeconds) {
            guard let session = sessions.sessions[sid] else { continue }
            guard let record = ClaudeProcessRegistry.read(pid: pid, configDir: ClaudeProcessRegistry.configDir(of: session)), record.sessionId == sid else {
                if warnedNoRegistry.insert(sid).inserted { onLog?("activity: no registry record for pid \(pid) (session \(sid.prefix(8))); only staleness can end it") }
                continue
            }
            if record.isIdle, let stamped = record.statusUpdatedAt, stamped > session.lastMainEventAt {
                onLog?("activity: quiet turn \(sid.prefix(8)) — registry idle, turn over")
                endTurn(sid, endedAt: stamped, now: now)
            } else if record.isBusy {
                if now.timeIntervalSince(session.lastMainEventAt) >= ActivityConstants.hooksSilentWarnSeconds, warnedHooksSilent.insert(sid).inserted {
                    onLog?("activity: hooks look dead for \(sid.prefix(8)) — registry busy, no hook for 5 min")
                }
                sessions.noteBusy(sessionId: sid, now: now)
            }
        }
        for (sid, pid, since) in sessions.openWaitCandidates() {
            guard let session = sessions.sessions[sid],
                  let record = ClaudeProcessRegistry.read(pid: pid, configDir: ClaudeProcessRegistry.configDir(of: session)), record.sessionId == sid, record.isBusy,
                  let stamped = record.statusUpdatedAt, stamped.timeIntervalSince(since) > ActivityConstants.dialogAnswerMinStampLeadSeconds else { continue }
            onLog?("activity: dialog answered without a hook (\(sid.prefix(8))); back to working")
            sessions.dialogAnswered(sessionId: sid, now: now)
            journal(.dialogAnswered, sid: sid, at: now)
        }
    }

    /// The registry directory of each replayed Claude Code pid whose session names its transcript, for the prune:
    /// read before it, since the prune's closure cannot reach the store it is filtering.
    private func claudeRegistryDirs() -> [Int32: URL] {
        var dirs: [Int32: URL] = [:]
        for s in sessions.sessions.values where s.agent == .claude {
            if let pid = s.agentPid, let dir = ClaudeProcessRegistry.configDir(of: s) { dirs[pid] = dir }
        }
        return dirs
    }

    /// A rescue found the turn over: it ends at the moment the turn ended (`rescueStamp`), and the verdict is
    /// journaled with that stamp, so a relaunch replays the same end.
    private func endTurn(_ sid: String, endedAt: Date, now: Date) {
        guard let session = sessions.sessions[sid] else { return }
        let at = ActivitySessionStore.rescueStamp(endedAt: endedAt, lastMainEventAt: session.lastMainEventAt, now: now)
        sessions.turnOver(sessionId: sid, now: at)
        journal(.turnOver, sid: sid, at: at)
    }

    /// One `KoffeeLidVerdict` line: the session, the verdict, its stamp, nothing else. The tailer hands it back to
    /// the store that already applied it, which changes nothing.
    private func journal(_ verdict: ActivityVerdict, sid: String, at: Date) {
        var line = ActivityEvent(loggedAt: at, event: .verdict)
        line.sessionId = sid; line.verdict = verdict.rawValue
        let written = (try? ActivityCodec.encodeLine(line)).map { ActivityJournalWriter.append($0, to: AppSupport.activityJournalURL) } ?? false
        if !written { onLog?("activity: could not journal the \(verdict.rawValue) verdict (\(sid.prefix(8))); a relaunch replays the session as it was") }
    }

    /// A lost `Stop` or `Interrupt` leaves a Codex turn working with nothing to end it, and the pid its hooks
    /// record is usually a shared Codex host, alive across every session. A session on Codex's managed daemon
    /// is asked about there first (`thread/read`); the daemon's answer arrives later, on main. Every other
    /// session (the desktop app's included), and one the daemon could not decide, is read from its rollout.
    /// At launch every working Codex session is read from its rollout, without the quiet gate, the daemon
    /// having answered `thread/loaded/list` already. Only ends turns.
    private func checkCodex(now: Date, atLaunch: Bool) {
        daemonAskAgainAt = daemonAskAgainAt.filter { sessions.sessions[$0.key] != nil }
        let daemonUp = !atLaunch && CodexDaemonClient.socketExists
        for (sid, recorded) in sessions.codexCandidates(at: now, quietSeconds: atLaunch ? 0 : ActivityConstants.abandonQuietSeconds) {
            guard let session = sessions.sessions[sid], !askingDaemon.contains(sid) else { continue }
            if daemonUp, session.hostedByManagedDaemon, daemonAskAgainAt[sid].map({ now >= $0 }) ?? true {
                askingDaemon.insert(sid)
                let asked = session.lastMainEventAt
                CodexDaemonClient.readThread(id: sid) { [weak self] record in
                    self?.daemonAnswered(sid: sid, record: record, asked: asked)
                }
                continue
            }
            checkRollout(sid: sid, recorded: recorded, now: now)
        }
    }

    /// The daemon's answer about `sid`, applied only while the session is still the one asked about: working,
    /// with no main-agent event since the question.
    private func daemonAnswered(sid: String, record: CodexThreadRecord?, asked: Date) {
        askingDaemon.remove(sid)
        guard started, launched, let session = sessions.sessions[sid], session.state == .working, !session.pendingDone,
              session.lastMainEventAt == asked else { return }
        let now = Date()
        let verdict = record?.verdict ?? .undecided
        if record == nil { noteDaemonSilent() }
        switch verdict {
        case .over:
            onLog?("activity: Codex daemon says thread \(sid.prefix(8)) has nothing running, turn over")
            endTurn(sid, endedAt: now, now: now)
        case .busy:
            if now.timeIntervalSince(session.lastMainEventAt) >= ActivityConstants.hooksSilentWarnSeconds, warnedHooksSilent.insert(sid).inserted {
                onLog?("activity: hooks look dead for \(sid.prefix(8)) — daemon says active, no hook for 5 min")
            }
            sessions.noteBusy(sessionId: sid, now: now)
        case .undecided:
            if let status = record?.status, warnedDaemonStatuses.insert(status).inserted {
                // The daemon's words, not ours: letters and digits only, and short, before they reach the log.
                let shown = String(String.UnicodeScalarView(status.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(40)))
                onLog?("activity: Codex daemon reports an unknown thread status \(shown)")
            }
            daemonAskAgainAt[sid] = now.addingTimeInterval(ActivityConstants.abandonRecheckSeconds)
            checkRollout(sid: sid, recorded: session.transcriptPath, daemonPath: record?.rolloutPath, now: now)
        }
        publish(now: now)
        scheduleNext(now: now)
    }

    /// At launch: a working session the managed daemon hosts whose thread it does not hold in memory has nothing
    /// running. A nil answer leaves every session to its rollout.
    private func daemonListed(_ loaded: Set<String>?, asked: [String: Date]) {
        guard let loaded else { noteDaemonSilent(); return }
        let now = Date()
        for (sid, lastMain) in asked where !loaded.contains(sid) {
            guard let session = sessions.sessions[sid], session.state == .working, !session.pendingDone, session.lastMainEventAt == lastMain else { continue }
            onLog?("activity: Codex daemon has not loaded thread \(sid.prefix(8)), turn over")
            endTurn(sid, endedAt: now, now: now)
        }
    }

    /// The working Codex sessions the managed daemon hosts, each with its last main-agent event; a held `Stop` is the
    /// time rules'.
    private func daemonHostedWorkingSessions() -> [String: Date] {
        var hosted: [String: Date] = [:]
        for s in sessions.sessions.values where s.agent == .codex && s.state == .working && !s.pendingDone && s.hostedByManagedDaemon {
            hosted[s.id] = s.lastMainEventAt
        }
        return hosted
    }

    private func noteDaemonSilent() {
        guard !warnedDaemonSilent else { return }
        warnedDaemonSilent = true
        onLog?("activity: Codex daemon not answering; using the rollout")
    }

    /// The rollout's verdict on a quiet Codex session: the path its hooks named, else the one the daemon
    /// named, each only where Codex keeps rollouts and named after the session; else the newest found.
    private func checkRollout(sid: String, recorded: String?, daemonPath: String? = nil, now: Date) {
        guard let session = sessions.sessions[sid] else { return }
        let path = [recorded, daemonPath].compactMap { $0 }.first {
            CodexRolloutTail.isInSessions($0, sessionsDirectory: CodexRollout.sessionsDirectory) && CodexRolloutTail.isRollout(path: $0, ofSession: sid)
        } ?? CodexRollout.locate(sessionId: sid)
        let verdict = path.flatMap(CodexRollout.read(path:)).map { CodexRolloutTail.verdict(tail: $0) } ?? .unreadable
        switch CodexRolloutTail.decision(verdict: verdict, lastMainEventAt: session.lastMainEventAt, lastMainTurnId: session.lastMainTurnId) {
        case .turnOver(let reason, let endedAt):
            onLog?("activity: quiet Codex turn \(sid.prefix(8)) — rollout says \(reason), turn over")
            endTurn(sid, endedAt: endedAt, now: now)
        case .busy:
            if now.timeIntervalSince(session.lastMainEventAt) >= ActivityConstants.hooksSilentWarnSeconds, warnedHooksSilent.insert(sid).inserted {
                onLog?("activity: hooks look dead for \(sid.prefix(8)) — rollout says running, no hook for 5 min")
            }
            sessions.noteBusy(sessionId: sid, now: now)
        case .nothing:
            if verdict == .unreadable, warnedNoRollout.insert(sid).inserted {
                onLog?("activity: no rollout for Codex session \(sid.prefix(8)); only staleness can end it")
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
