import Foundation

/// One terminal command reported by the zsh hooks. Not journaled for replay purposes beyond the
/// current boot; its outcome is irrelevant — only whether it is still running, which its shell is asked.
public struct ActivityJob: Equatable {
    public var id: String
    /// The shell that owns the job: watched for death, and the eviction slot (one job per shell).
    public var ownerPid: Int32?
    public var label: String?
    /// Not counted until this instant; nil once elapsed.
    public var armAfter: Date?
    public var since: Date
    /// When a probe first found the shell at its prompt with no child (`ShellJobLiveness.judge`).
    public var promptSeenAt: Date?
}

public struct ActivityJobStore {
    public private(set) var jobs: [String: ActivityJob] = [:]
    public init() {}

    public mutating func begin(id: String, pid: Int32?, label: String?, armAfterSeconds: Double, now: Date) {
        if let pid { jobs = jobs.filter { $0.value.ownerPid != pid } }
        var job = ActivityJob(id: id, ownerPid: pid, label: label, armAfter: nil, since: now)
        if armAfterSeconds > 0 { job.armAfter = now.addingTimeInterval(armAfterSeconds) }
        jobs[id] = job
    }
    public mutating func end(id: String) { jobs.removeValue(forKey: id) }
    public mutating func processExited(pid: Int32) { jobs = jobs.filter { $0.value.ownerPid != pid } }
    /// What the job's shell answered (`ShellJobLiveness`); the reason when that drops the job, else nil.
    public mutating func probe(id: String, _ probe: ShellJobLiveness.Probe, now: Date) -> String? {
        guard var job = jobs[id] else { return nil }
        switch ShellJobLiveness.judge(probe, promptSeenAt: &job.promptSeenAt, now: now) {
        case .keep: jobs[id] = job; return nil
        case .drop(let reason): jobs.removeValue(forKey: id); return reason
        }
    }

    public mutating func tick(now: Date) {
        for (id, original) in jobs {
            var job = original
            if let a = job.armAfter, a <= now { job.armAfter = nil }
            if job.ownerPid == nil, now.timeIntervalSince(job.since) >= ActivityConstants.jobStaleSeconds { jobs.removeValue(forKey: id); continue }
            jobs[id] = job
        }
    }
    /// The next arm-after, settle or staleness instant, and the next probe while any job has a shell.
    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for job in jobs.values {
            if let a = job.armAfter { deadlines.append(a) }
            if job.ownerPid == nil { deadlines.append(job.since.addingTimeInterval(ActivityConstants.jobStaleSeconds)) }
            else { deadlines.append(now.addingTimeInterval(ActivityConstants.jobProbeSeconds)) }
            if let seen = job.promptSeenAt { deadlines.append(seen.addingTimeInterval(ActivityConstants.jobPromptSettleSeconds)) }
        }
        return deadlines.filter { $0 > now }.min()
    }
    public func runningCount(at now: Date) -> Int { jobs.values.filter { ($0.armAfter ?? .distantPast) <= now }.count }
    public func isRunning(at now: Date) -> Bool { runningCount(at: now) > 0 }
    /// The shells of the running jobs, once each: their process chains name the terminals hosting them.
    public func runningOwnerPids(at now: Date) -> [Int32] {
        Array(Set(jobs.values.filter { ($0.armAfter ?? .distantPast) <= now }.compactMap(\.ownerPid))).sorted()
    }
    public var trackedPids: Set<Int32> { Set(jobs.values.compactMap(\.ownerPid)) }
}
