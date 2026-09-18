import Foundation
import Darwin
import KoffeeLidCore

/// `KoffeeLidHook hook` runs inside every Claude Code turn: it must never block on anything but one
/// append, never launch the app, and always exit 0. `job begin|end` are the zsh snippet's primitives.
enum HookMain {
    static func run(_ args: [String]) -> Int32 {
        if ProcessInfo.processInfo.environment["KOFFEELID_DISABLE"] == "1" { return 0 }
        switch args.first {
        case "hook": return hook()
        case "job": return job(Array(args.dropFirst()))
        default:
            FileHandle.standardError.write(Data("usage: KoffeeLidHook hook | job begin --id ID --pid PID [--label TEXT] [--arm-after SECONDS] | job end --id ID\n".utf8))
            return 2
        }
    }

    static func hook() -> Int32 {
        var input = Data()
        let stdin = FileHandle.standardInput
        // Read everything so the writer is never broken by a closed pipe, but retain at most the cap.
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            if input.count < ActivityConstants.hookStdinMaxBytes {
                input.append(chunk.prefix(ActivityConstants.hookStdinMaxBytes - input.count))
            }
        }
        var event = ActivityTrim.event(fromHookPayload: input, loggedAt: Date())
        // Ancestors from the parent: Claude Code spawns the hook through a shell.
        event.claudePid = ProcWalk.claudePid(inChainFrom: getppid())
        if let line = try? ActivityTrim.cappedLine(event) { ActivityJournalWriter.append(line, to: AppSupport.activityJournalURL) }
        return 0
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
