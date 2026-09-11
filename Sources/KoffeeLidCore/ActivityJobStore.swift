import Foundation

/// One terminal command reported by the zsh hooks. Not journaled for replay purposes beyond the
/// current boot; its outcome is irrelevant — only whether it is still running.
public struct ActivityJob: Equatable {
    public var id: String
    /// The shell that owns the job: watched for death, and the eviction slot (one job per shell).
    public var ownerPid: Int32?
    public var label: String?
    /// Not counted until this instant; nil once elapsed.
    public var armAfter: Date?
    public var since: Date
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

    public mutating func tick(now: Date) {
        for (id, original) in jobs {
            var job = original
            if let a = job.armAfter, a <= now { job.armAfter = nil }
            if now.timeIntervalSince(job.since) >= ActivityConstants.jobStaleSeconds { jobs.removeValue(forKey: id); continue }
            jobs[id] = job
        }
    }
    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for job in jobs.values {
            if let a = job.armAfter { deadlines.append(a) }
            deadlines.append(job.since.addingTimeInterval(ActivityConstants.jobStaleSeconds))
        }
        return deadlines.filter { $0 > now }.min()
    }
    public func runningCount(at now: Date) -> Int { jobs.values.filter { ($0.armAfter ?? .distantPast) <= now }.count }
    public func isRunning(at now: Date) -> Bool { runningCount(at: now) > 0 }
    public var trackedPids: Set<Int32> { Set(jobs.values.compactMap(\.ownerPid)) }
}
