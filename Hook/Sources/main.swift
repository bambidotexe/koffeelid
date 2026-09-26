import Foundation
import Darwin
import KoffeeLidCore

/// `KoffeeLidHook hook` runs inside every Claude Code turn, `hook codex` inside every Codex turn, `hook copilot
/// <event>` inside every Copilot turn and `hook opencode` for every OpenCode event a plugin forwards to it:
/// it must never block on anything but one append, never launch the app, and always exit 0, whatever its
/// arguments (Copilot denies a tool whose hook fails). `job begin|end` are the zsh snippet's primitives.
enum HookMain {
    static func run(_ args: [String]) -> Int32 {
        let disabled = ProcessInfo.processInfo.environment["KOFFEELID_DISABLE"] == "1"
        switch args.first {
        case "hook":
            // Every form reads its payload to the end first, the ones that write nothing included, so the agent
            // writing it never meets a closed pipe. Arguments no agent's hook sends write nothing.
            let input = readInput()
            guard !disabled, let call = HookCall(arguments: Array(args.dropFirst())) else { return 0 }
            return hook(call, input: input)
        case "job": return disabled ? 0 : job(Array(args.dropFirst()))
        default: return disabled ? 0 : usage()
        }
    }

    static func usage() -> Int32 {
        FileHandle.standardError.write(Data("usage: KoffeeLidHook hook [codex | copilot EVENT | opencode] | job begin --id ID --pid PID [--label TEXT] [--arm-after SECONDS] | job end --id ID\n".utf8))
        return 2
    }

    /// The hook's stdin, read to its end so the writer is never broken by a closed pipe; at most the cap is kept.
    static func readInput() -> Data {
        var input = Data()
        let stdin = FileHandle.standardInput
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            if input.count < ActivityConstants.hookStdinMaxBytes {
                input.append(chunk.prefix(ActivityConstants.hookStdinMaxBytes - input.count))
            }
        }
        return input
    }

    static func hook(_ call: HookCall, input: Data) -> Int32 {
        let now = Date()
        let trimmed: ActivityEvent?
        switch call {
        case .claude, .codex:
            trimmed = ActivityTrim.event(fromHookPayload: input, agent: call.agent, loggedAt: now)
        case .copilot(let name):
            // A subagent's line carries an id with no session folder: dropped. `COPILOT_HOME` moves the folders.
            let root = CopilotSessionState.root(environment: ProcessInfo.processInfo.environment,
                                                home: FileManager.default.homeDirectoryForCurrentUser.path)
            trimmed = CopilotSessionState.line(ActivityTrim.copilotEvent(fromHookPayload: input, named: name, loggedAt: now),
                                               root: root, directoryExists: isDirectory)
        case .opencode:
            trimmed = ActivityTrim.opencodeEvent(fromHookPayload: input, loggedAt: now)
        }
        guard var event = trimmed else { return 0 }
        // Ancestors from the parent: Claude Code and Codex spawn the hook through a shell, which may exec it
        // directly; Copilot and OpenCode's server spawn it themselves. OpenCode's payload names its server,
        // believed only when it is one of those ancestors.
        event.agentPid = ProcWalk.pid(of: call.agent, inChainFrom: getppid(), claimed: event.agentPid)
        if let line = try? ActivityTrim.cappedLine(event) { ActivityJournalWriter.append(line, to: AppSupport.activityJournalURL) }
        return 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    static func job(_ args: [String]) -> Int32 {
        guard let verb = args.first, verb == "begin" || verb == "end" else { return 2 }
        var id: String?; var pid: Int32 = getppid(); var label: String?; var armAfter: Double?
        var i = 1
        while i + 1 < args.count {
            let v = args[i + 1]
            switch args[i] {
            case "--id": id = v
            case "--pid": pid = Int32(v) ?? pid
            case "--label": label = v
            case "--arm-after": armAfter = Double(v)
            default: return 2
            }
            i += 2
        }
        guard let id, !id.isEmpty else { return 2 }
        var e = ActivityEvent(loggedAt: Date(), event: verb == "begin" ? .jobBegin : .jobEnd)
        e.jobId = String(id.prefix(ActivityConstants.metadataMaxChars))
        if verb == "begin" {
            e.jobPid = pid
            e.jobLabel = label.map(ActivityTrim.clampLabel)
            e.jobArmAfterSeconds = armAfter.map { max(0, $0) }
        }
        if let line = try? ActivityTrim.cappedLine(e) { ActivityJournalWriter.append(line, to: AppSupport.activityJournalURL) }
        return 0
    }
}

exit(HookMain.run(Array(CommandLine.arguments.dropFirst())))
