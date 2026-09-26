import Foundation

/// Reads the process ancestor chain via sysctl — microseconds, no subprocesses. Used by the hook to find
/// the agent process (Claude Code, Codex, Copilot, OpenCode) it runs under, and by the app to prune sessions
/// whose pid died or was recycled and to tell Codex's shared hosts apart.
public enum ProcWalk {
    public struct ProcInfo: Equatable {
        public let pid: Int32, ppid: Int32, name: String, path: String?
        /// The process group, and the foreground process group of its controlling terminal (0 without one).
        /// A shell at its prompt owns its terminal's foreground group; one running a foreground command has
        /// handed it to that command's group.
        public let pgid: Int32, tpgid: Int32
        /// When the process was forked; an `exec` keeps it.
        public let startedAt: Date?
        public init(pid: Int32, ppid: Int32, name: String, path: String?, pgid: Int32 = 0, tpgid: Int32 = 0, startedAt: Date? = nil) {
            self.pid = pid; self.ppid = ppid; self.name = name; self.path = path
            self.pgid = pgid; self.tpgid = tpgid; self.startedAt = startedAt
        }
        /// An interactive shell's `p_comm`, a login shell's leading `-` stripped.
        public var isShell: Bool {
            let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
            return ProcWalk.shellNames.contains(bare)
        }
    }
    static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh"]

    public static func info(for pid: Int32) -> ProcInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return ProcInfo(pid: pid, ppid: proc.kp_eproc.e_ppid, name: name, path: length > 0 ? String(cString: buffer) : nil,
                        pgid: proc.kp_eproc.e_pgid, tpgid: proc.kp_eproc.e_tpgid, startedAt: startedAt(of: proc))
    }

    static func startedAt(of proc: kinfo_proc) -> Date? {
        let start = proc.kp_proc.p_un.__p_starttime
        return start.tv_sec > 0 ? Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000) : nil
    }

    /// When each child of `pid` was forked, for the children that can still be read; empty when it has none or
    /// cannot be read. A shell's children include helpers that live beside it from its start (Powerlevel10k's
    /// `gitstatusd`), so the start is what tells them from the command's.
    public static func childStartTimes(pid: Int32) -> [Date] {
        var children = [Int32](repeating: 0, count: 256)
        let count = children.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return children.prefix(Int(count)).compactMap { child in
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, child]
            var proc = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
            guard child > 0, sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
            return startedAt(of: proc)
        }
    }

    public static func chain(from pid: Int32, maxHops: Int = 15) -> [ProcInfo] {
        var out: [ProcInfo] = []; var current = pid
        while out.count < maxHops, current > 1, let info = info(for: current) { out.append(info); current = info.ppid }
        return out
    }

    /// The KERN_PROCARGS2 buffer: argc, exec path, NULs, argv strings, then KEY=VALUE environment strings.
    static func procArgs(_ pid: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]; var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// The exec path as recorded (a symlink launcher shows the symlink, unlike proc_pidpath).
    static func execPath(for pid: Int32) -> String? {
        guard let buffer = procArgs(pid) else { return nil }
        let start = MemoryLayout<Int32>.size; var end = start
        while end < buffer.count, buffer[end] != 0 { end += 1 }
        guard end > start else { return nil }
        return String(decoding: buffer[start..<end], as: UTF8.self)
    }

    /// The argument vector, argv[0] first, from a same-user process's KERN_PROCARGS2 buffer: argc, the exec
    /// path, NUL padding, then argc NUL-terminated strings. Nil when the process cannot be read.
    public static func arguments(forPid pid: Int32) -> [String]? {
        guard let buffer = procArgs(pid) else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer.prefix(MemoryLayout<Int32>.size)) }
        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // exec path
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // padding
        var out: [String] = []
        while out.count < Int(argc), index < buffer.count {
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            out.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return out
    }

    /// Both real install shapes: the launcher `~/.local/bin/claude` and the versioned target
    /// `~/.local/share/claude/versions/<version>` (whose p_comm is the version string).
    public static func isClaudePath(_ path: String) -> Bool {
        path.hasSuffix("/claude") || path.split(separator: "/").contains("claude")
    }
    public static func isClaudeProcess(_ info: ProcInfo) -> Bool {
        if info.name == "claude" { return true }
        if let path = info.path, isClaudePath(path) { return true }
        if let argv0 = execPath(for: info.pid), isClaudePath(argv0) { return true }
        return false
    }
    /// Codex's two install shapes: the launcher `~/.local/bin/codex` (a symlink) and the binary it points
    /// at, `~/.codex/packages/standalone/<version>/bin/codex`; the app-server daemon runs its own copy under
    /// `~/.codex/packages/app-server-daemon/`.
    public static func isCodexPath(_ path: String) -> Bool {
        path.hasSuffix("/codex") || path.split(separator: "/").contains("codex")
    }
    public static func isCodexProcess(_ info: ProcInfo) -> Bool {
        if info.name == "codex" { return true }
        if let path = info.path, isCodexPath(path) { return true }
        if let argv0 = execPath(for: info.pid), isCodexPath(argv0) { return true }
        return false
    }
    /// Codex's managed daemon, `codex app-server --listen unix:// --managed-daemon`, installed under
    /// `~/.codex/packages/app-server-daemon/`: one per user, started by the first TUI, parented by launchd,
    /// and the process every TUI session's hooks run under. Recognised by its flag or its install path; the
    /// only Codex process whose control socket KoffeeLid asks about a thread.
    public static func isManagedCodexDaemon(path: String?, arguments: [String]) -> Bool {
        if let path, path.contains("/app-server-daemon/") { return true }
        return arguments.dropFirst().contains("--managed-daemon")
    }
    /// Any `codex app-server`: the managed daemon, or the desktop app's own long-lived `codex`. Either hosts
    /// many threads and outlives them, so its pid alive proves nothing about one session.
    public static func isSharedCodexHost(path: String?, arguments: [String]) -> Bool {
        isManagedCodexDaemon(path: path, arguments: arguments) || arguments.dropFirst().contains("app-server")
    }
    /// Copilot CLI's executable is `copilot` wherever it lives: `~/.local/bin/copilot`, or the copy GitHub
    /// Copilot.app runs its sessions in, `~/Library/Caches/github-copilot-sdk/cli/<version>/copilot`. That process
    /// is the hook's parent; one can hold several sessions, and no daemon outlives them.
    public static func isCopilotPath(_ path: String) -> Bool { executableName(path) == "copilot" }
    public static func isCopilotProcess(_ info: ProcInfo) -> Bool {
        if info.name == "copilot" { return true }
        if let path = info.path, isCopilotPath(path) { return true }
        if let argv0 = execPath(for: info.pid), isCopilotPath(argv0) { return true }
        return false
    }
    /// OpenCode's server, the hook's parent, runs one of three executables: `opencode` (`~/.opencode/bin/`,
    /// Homebrew), `opencode-cli` (inside OpenCode.app, and the copy it stages under Application Support) or
    /// `.opencode` (the npm package's). The desktop app's own window process and the `opencode2` launcher are not
    /// it. One server hosts every session of every client.
    static let opencodeExecutables: Set<String> = ["opencode", "opencode-cli", ".opencode"]
    public static func isOpencodePath(_ path: String) -> Bool { opencodeExecutables.contains(executableName(path)) }
    public static func isOpencodeProcess(_ info: ProcInfo) -> Bool {
        if opencodeExecutables.contains(info.name) { return true }
        if let path = info.path, isOpencodePath(path) { return true }
        if let argv0 = execPath(for: info.pid), isOpencodePath(argv0) { return true }
        return false
    }
    static func executableName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "" }

    public static func isProcess(of agent: ActivityAgent, _ info: ProcInfo) -> Bool {
        switch agent {
        case .claude: return isClaudeProcess(info)
        case .codex: return isCodexProcess(info)
        case .copilot: return isCopilotProcess(info)
        case .opencode: return isOpencodeProcess(info)
        }
    }
    /// The ancestor of `pid` (inclusive) running `agent` that the hook ran under, or nil: `claimed` when the
    /// chain holds it running `agent` (OpenCode's payload names its server), else the nearest one. A Codex
    /// started from a Claude Code tool call, or the reverse, has both in its chain, and the nearest of the asked
    /// kind is the one the hook ran under.
    public static func pid(of agent: ActivityAgent, inChainFrom pid: Int32, claimed: Int32? = nil) -> Int32? {
        self.pid(of: agent, claimed: claimed, in: chain(from: pid))
    }
    /// `pid(of:inChainFrom:claimed:)` over a chain already read.
    public static func pid(of agent: ActivityAgent, claimed: Int32?, in chain: [ProcInfo]) -> Int32? {
        if let claimed, let info = chain.first(where: { $0.pid == claimed }), isProcess(of: agent, info) { return claimed }
        return chain.first { isProcess(of: agent, $0) }?.pid
    }
    /// The nearest Claude Code ancestor of `pid` (inclusive), or nil.
    public static func claudePid(inChainFrom pid: Int32) -> Int32? { self.pid(of: .claude, inChainFrom: pid) }
    /// kill(0) proves a process, not THE process: a pid recycled while the app was down must not keep a dead session alive.
    public static func looksLike(_ agent: ActivityAgent, pid: Int32) -> Bool { info(for: pid).map { isProcess(of: agent, $0) } ?? false }
    public static func looksLikeClaude(pid: Int32) -> Bool { looksLike(.claude, pid: pid) }
    public static func isAlive(pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Whether any process runs the executable at `url`. Compared by file identity (device and inode), not
    /// by path: the path the kernel reports and the one a bundle was opened from can differ by a link or a
    /// firmlink and still name the same file, and two copies of the app at two paths are two files. Reads
    /// every process's path once; a few milliseconds.
    public static func isRunning(executableAt url: URL) -> Bool {
        var target = stat()
        guard stat(url.path, &target) == 0 else { return false }
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        // Room for processes started between the two calls.
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return false }
        let suffix = "/" + url.lastPathComponent
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            guard path.hasSuffix(suffix) else { continue }
            var candidate = stat()
            if stat(path, &candidate) == 0, candidate.st_dev == target.st_dev, candidate.st_ino == target.st_ino {
                return true
            }
        }
        return false
    }
}
