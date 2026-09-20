import Foundation

/// Everything the helper that finishes an update is told. It runs after the app has quit, so it is told all of
/// it up front, as arguments: nothing is interpolated into the script's text.
public struct UpdateInstallPlan: Equatable, Sendable {
    /// The running app, whose exit the helper waits for.
    public var pid: Int32
    /// The installed bundle, and the new one that takes its place. Same volume, so each move is one rename.
    public var destination: URL
    public var staged: URL
    /// Where the previous bundle waits until the new version has been seen running.
    public var backup: URL
    public var resultFile: URL
    public var logFile: URL
    public var executableName: String
    public var version: String
    /// `gui/<uid>/<label>` when the app runs as a launchd job, which is then how it is started again: an app
    /// started by `open` instead would be nobody's job, and no crash would bring it back.
    public var launchdService: String?
    /// Seconds: for the app to quit, for the new version to show among the running processes, and how long after
    /// that it is looked for once more. The app itself stops the helper after `UpdateInstallPlan.stallNotice`,
    /// which is shorter than `quitWait`: the helper's own limit only ever serves an app too hung to do so.
    public var quitWait: Int
    public var launchWait: Int
    public var settle: Int

    public init(pid: Int32, destination: URL, staged: URL, backup: URL, resultFile: URL, logFile: URL, executableName: String,
                version: String, launchdService: String? = nil, quitWait: Int = 30, launchWait: Int = 15, settle: Int = 2) {
        self.pid = pid; self.destination = destination; self.staged = staged; self.backup = backup
        self.resultFile = resultFile; self.logFile = logFile; self.executableName = executableName; self.version = version
        self.launchdService = launchdService; self.quitWait = quitWait; self.launchWait = launchWait; self.settle = settle
    }

    /// Seconds after the click at which an app that is still running stops the helper and says it did not quit.
    public static let stallNotice: TimeInterval = 20

    /// The helper's arguments, in the order its text reads them.
    public var arguments: [String] {
        [String(pid), destination.path, staged.path, backup.path, resultFile.path, logFile.path, executableName, version,
         launchdService ?? "-", String(quitWait), String(launchWait), String(settle)]
    }
}

/// What the helper leaves for the next launch to read: one line. The launch that reads it renames the file to
/// `<result>.read`, which is how the helper knows a version that is gone again two seconds later had started
/// properly, and was quit, rather than crashed on its way up.
public enum UpdateResult: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The new bundle could not be put in place; the previous one never moved, or was moved back.
        case replace
        /// The new version was put in place and did not start; the previous one was put back.
        case launch
        /// The previous bundle could not be put back. It is still in `updates/previous/`.
        case stranded
    }

    case installed(version: String)
    case failed(version: String, reason: Reason)

    /// How long an outcome is news. A line found later than that was left behind by an install nobody is
    /// waiting on any more, and opens no window.
    public static let shelfLife: TimeInterval = 600

    /// `age` is the time since the line was written; a negative one means the clock moved, which proves nothing.
    public static func isNews(age: TimeInterval) -> Bool { (0...shelfLife).contains(age) }

    /// The mark a launch leaves in place of the result it has read.
    public static func readMark(for result: URL) -> URL { result.appendingPathExtension("read") }

    public init?(line: String) {
        let words = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        switch (words.first, words.count) {
        case ("installed", 2): self = .installed(version: words[1])
        case ("failed", 3):
            guard let reason = Reason(rawValue: words[2]) else { return nil }
            self = .failed(version: words[1], reason: reason)
        default: return nil
        }
    }

    public var line: String {
        switch self {
        case .installed(let version): return "installed \(version)"
        case .failed(let version, let reason): return "failed \(version) \(reason.rawValue)"
        }
    }
}

/// The helper itself: a POSIX shell script, run by `/bin/sh` in a process group of its own so that it outlives
/// the app that started it. Everything that can be refused (the download, the disk image, the signature, the
/// version, the folder's permissions) was settled while the app was still running; what is left for after the
/// quit is two renames and a launch, and a way back if the new version does not start.
///
/// The three tools are taken from the environment when it names them, which is how the tests stand in for
/// `open`, `ps` and `launchctl`. The app starts the helper with an environment of its own making.
public enum UpdateInstallScript {
    public static let text = #"""
    #!/bin/sh
    #  $1 pid of the app          $5 result file        $9  launchd service to start it through, or -
    #  $2 the installed bundle    $6 log file           $10 seconds to wait for the app to quit
    #  $3 the new bundle          $7 executable name    $11 seconds to wait for the new version to show
    #  $4 where the previous      $8 the new version    $12 seconds after which it is looked for once more
    #     bundle waits
    set -u
    pid="$1"; dest="$2"; staged="$3"; backup="$4"; result="$5"; log="$6"; exe="$7"; version="$8"; service="$9"
    shift 9
    quit_wait="$1"; launch_wait="$2"; settle="$3"
    open_tool="${UPDATE_HELPER_OPEN:-/usr/bin/open}"
    ps_tool="${UPDATE_HELPER_PS:-/bin/ps}"
    launchctl_tool="${UPDATE_HELPER_LAUNCHCTL:-/bin/launchctl}"
    read_mark="$result.read"
    failed="$backup.failed"

    say() { printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log" 2>/dev/null; }
    record() { printf '%s\n' "$1" > "$result"; say "result: $1"; }

    # Still there, and not merely waiting to be reaped by whoever started it: a process that has exited
    # answers `kill -0` until then. Anything `ps` cannot say counts as still running, the safe way round.
    app_alive() {
        kill -0 "$pid" 2>/dev/null || return 1
        case "$("$ps_tool" -o stat= -p "$pid" 2>/dev/null)" in Z*) return 1 ;; esac
        return 0
    }

    # The new version, by the path it was installed at or by the one the system knows that folder by.
    running() {
        list="$("$ps_tool" -axo comm=)"
        printf '%s\n' "$list" | /usr/bin/grep -Fxq "$dest/Contents/MacOS/$exe" && return 0
        real="$(cd "$dest" 2>/dev/null && pwd -P)" || return 1
        [ "$real" != "$dest" ] && printf '%s\n' "$list" | /usr/bin/grep -Fxq "$real/Contents/MacOS/$exe"
    }

    launch() {
        if [ "$service" != "-" ]; then
            if "$launchctl_tool" kickstart "$service" >/dev/null 2>&1; then say "started through launchd: $service"; return 0; fi
            say "launchd would not start $service; opening the app instead"
        fi
        "$open_tool" "$dest" >/dev/null 2>&1
    }

    # The previous copy back at the app's path, whatever is there now. When it cannot be, whatever was there
    # stays there and the previous copy stays where it waits: nothing is ever deleted to make room.
    put_back() {
        /bin/rm -rf "$failed"
        if [ -e "$dest" ] && ! /bin/mv "$dest" "$failed" 2>>"$log"; then
            say "the new copy could not be moved out; the previous one stays at $backup"
            return 1
        fi
        if /bin/mv "$backup" "$dest" 2>>"$log"; then /bin/rm -rf "$failed"; return 0; fi
        say "the previous copy could not be put back; it stays at $backup"
        [ -e "$failed" ] && /bin/mv "$failed" "$dest" 2>>"$log"
        return 1
    }

    # The app's own quit is what ends it. Until it is gone nothing is touched, and if it never goes nothing is:
    # the app is still there to say so itself, and stops this helper when it does.
    n=0; ticks=$((quit_wait * 5))
    while app_alive; do
        if [ "$n" -ge "$ticks" ]; then say "app $pid still running after ${quit_wait}s; nothing touched"; exit 0; fi
        n=$((n + 1)); /bin/sleep 0.2
    done
    say "app $pid has quit; installing $version"

    if [ ! -x "$staged/Contents/MacOS/$exe" ]; then
        say "the new copy is missing or incomplete: $staged"
        record "failed $version replace"; launch; exit 0
    fi
    /bin/rm -rf "$backup" "$failed"
    /bin/rm -f "$read_mark"
    /bin/mkdir -p "$(/usr/bin/dirname "$backup")"
    if ! /bin/mv "$dest" "$backup" 2>>"$log"; then
        say "the installed copy could not be moved aside"
        record "failed $version replace"; launch; exit 0
    fi
    if ! /bin/mv "$staged" "$dest" 2>>"$log"; then
        say "the new copy could not be moved in; putting the previous one back"
        if put_back; then record "failed $version replace"; else record "failed $version stranded"; fi
        launch; exit 0
    fi
    # Written before the launch: the new version reads it as it starts, and leaves "$read_mark" in its place.
    record "installed $version"

    seen=0
    if launch; then
        n=0; ticks=$((launch_wait * 5))
        while [ "$n" -lt "$ticks" ]; do
            if running; then seen=1; break; fi
            n=$((n + 1)); /bin/sleep 0.2
        done
        if [ "$seen" -eq 1 ] && [ "$settle" -gt 0 ]; then
            /bin/sleep "$settle"
            # Gone again already. A version that had read the outcome had started: its quit is the user's
            # business. One that had not is either on its way back — an app that bootstraps a launchd job
            # quits so that the job's own copy can take its place, and nothing runs in between — or it
            # crashed on its way up. The second look lasts as long as the first before it is believed.
            if ! running && [ ! -e "$read_mark" ]; then
                seen=0; n=0
                while [ "$n" -lt "$ticks" ]; do
                    if running || [ -e "$read_mark" ]; then seen=1; break; fi
                    n=$((n + 1)); /bin/sleep 0.2
                done
            fi
        fi
    fi
    if [ "$seen" -eq 1 ]; then
        say "version $version is running"
        /bin/rm -rf "$backup"
        /bin/rm -f "$read_mark"
        exit 0
    fi

    say "version $version did not start; putting the previous one back"
    /bin/rm -f "$read_mark"
    if put_back; then record "failed $version launch"; else record "failed $version stranded"; fi
    launch
    exit 0

    """#
}
