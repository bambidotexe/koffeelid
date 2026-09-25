import Foundation

/// Whether a terminal job's shell still runs a command, asked of the shell itself: the journal can lose a
/// `job end` (a snippet re-read mid-command, a hook binary missing at that instant), and only the shell
/// knows. A shell at its prompt owns its terminal's foreground process group; one running a foreground
/// command has handed that group to the command.
public enum ShellJobLiveness {
    public struct Probe: Equatable {
        /// The job's shell pid still names the process that began the job.
        public var alive: Bool
        /// That process is still a shell (not replaced by `exec` into a program).
        public var isShell: Bool
        /// It owns its terminal's foreground process group.
        public var atPrompt: Bool
        public var hasChildren: Bool
        public init(alive: Bool, isShell: Bool, atPrompt: Bool, hasChildren: Bool) {
            self.alive = alive; self.isShell = isShell; self.atPrompt = atPrompt; self.hasChildren = hasChildren
        }
    }

    public enum Verdict: Equatable { case keep, drop(reason: String) }

    /// Gone → drop. Replaced by its program → keep; its exit ends the job (kqueue). At its prompt with no
    /// child, seen so `jobPromptSettleSeconds` apart → drop: the end was lost. Anything else is a command
    /// running → keep, the settle forgotten. `promptSeenAt` is the job's own first sighting at the prompt.
    public static func judge(_ probe: Probe, promptSeenAt: inout Date?, now: Date) -> Verdict {
        guard probe.alive else { return .drop(reason: "shell gone") }
        guard probe.isShell else { promptSeenAt = nil; return .keep }
        guard probe.atPrompt, !probe.hasChildren else { promptSeenAt = nil; return .keep }
        guard let seen = promptSeenAt else { promptSeenAt = now; return .keep }
        return now.timeIntervalSince(seen) >= ActivityConstants.jobPromptSettleSeconds ? .drop(reason: "shell at its prompt") : .keep
    }

    /// The probe of a job begun at `jobSince` whose shell pid reads as `info` (nil: no such process). A
    /// process forked after the job began is a recycled pid, not the shell that began it.
    public static func probe(_ info: ProcWalk.ProcInfo?, hasChildren: Bool, jobSince: Date) -> Probe {
        guard let info, info.startedAt.map({ $0 <= jobSince }) ?? true else {
            return Probe(alive: false, isShell: false, atPrompt: false, hasChildren: false)
        }
        return Probe(alive: true, isShell: info.isShell, atPrompt: info.pgid > 0 && info.tpgid == info.pgid, hasChildren: hasChildren)
    }
}
