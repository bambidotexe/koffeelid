import Foundation

/// Reads the process ancestor chain via sysctl — microseconds, no subprocesses. Used by the hook to find
/// the Claude Code or Codex process it runs under, and by the app to prune sessions whose pid died or was
/// recycled.
public enum ProcWalk {
    public struct ProcInfo: Equatable {
        public let pid: Int32, ppid: Int32, name: String, path: String?
        public init(pid: Int32, ppid: Int32, name: String, path: String?) { self.pid = pid; self.ppid = ppid; self.name = name; self.path = path }
    }

    public static func info(for pid: Int32) -> ProcInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return ProcInfo(pid: pid, ppid: proc.kp_eproc.e_ppid, name: name, path: length > 0 ? String(cString: buffer) : nil)
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

    /// One variable from a same-user process's environment (CLAUDE_CONFIG_DIR: the registry dir is per account).
    public static func environmentValue(_ name: String, forPid pid: Int32) -> String? {
        guard let buffer = procArgs(pid) else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer.prefix(MemoryLayout<Int32>.size)) }
        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // exec path
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // padding
        var remaining = argc
        while remaining > 0, index < buffer.count {                      // argv[0]…argv[argc-1]
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            index += 1; remaining -= 1
        }
        let prefix = Array("\(name)=".utf8)
        while index < buffer.count {
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            if end == index { break }                                    // double NUL: past the environment
            if buffer[index..<end].starts(with: prefix) { return String(decoding: buffer[(index + prefix.count)..<end], as: UTF8.self) }
            index = end + 1
        }
        return nil
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
    /// at, `~/.codex/packages/standalone/<version>/bin/codex`; the app-server daemon runs the same binary.
    public static func isCodexPath(_ path: String) -> Bool {
        path.hasSuffix("/codex") || path.split(separator: "/").contains("codex")
    }
    public static func isCodexProcess(_ info: ProcInfo) -> Bool {
        if info.name == "codex" { return true }
        if let path = info.path, isCodexPath(path) { return true }
        if let argv0 = execPath(for: info.pid), isCodexPath(argv0) { return true }
        return false
    }
    public static func isProcess(of agent: ActivityAgent, _ info: ProcInfo) -> Bool {
        agent == .claude ? isClaudeProcess(info) : isCodexProcess(info)
    }
    /// The nearest ancestor of `pid` (inclusive) running `agent`, or nil. A Codex started from a Claude Code
    /// tool call, or the reverse, has both in its chain, and the nearest of the asked kind is the one the
    /// hook ran under.
    public static func pid(of agent: ActivityAgent, inChainFrom pid: Int32) -> Int32? {
        chain(from: pid).first { isProcess(of: agent, $0) }?.pid
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
