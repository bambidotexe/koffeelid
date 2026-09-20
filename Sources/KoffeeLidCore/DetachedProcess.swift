import Foundation
import Darwin

/// Starts a process meant to outlive this one. It is put in a process group of its own: when a launchd job's
/// main process exits, launchd kills whatever is left in that job's process group (measured: a plain
/// `posix_spawn` child of a job dies with it, a child with its own group runs on). It inherits none of this
/// process's descriptors, reads `/dev/null`, writes to it, and gets the given environment and nothing else.
public enum DetachedProcess {
    public struct SpawnError: Error, Equatable, CustomStringConvertible {
        public let code: Int32
        public var description: String { "posix_spawn: \(String(cString: strerror(code)))" }
    }

    /// The child's pid. `arguments` does not include the executable's own path.
    @discardableResult
    public static func spawn(executable: String, arguments: [String], environment: [String: String]) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard code == 0 else { throw SpawnError(code: code) }
        return pid
    }
}
