import Foundation

/// What taking KoffeeLid off a Mac has to remove, and the one privileged command that removes the part of
/// it a user cannot.
///
/// Dragging the bundle to the Trash removes the app and nothing else: the sudoers rule, the wrapper on the
/// PATH, the login items, the Claude Code and Codex hooks and the zsh snippet stay, and the hooks go on
/// running a binary that is no longer there on every Claude Code and Codex event. Everything in that list
/// is removable from the app itself except the two files below, which are root-owned.
public enum UninstallPlan {
    /// The root-owned files, in the order a script removes them: the sudoers rule that backs the sleep lock
    /// and the `koffeelid` wrapper. They go in one script so that one administrator dialog covers both.
    public static let privilegedPaths: [String] = [SleepLockSetup.sudoersFile, "/usr/local/bin/koffeelid"]

    /// No dialog when there is nothing for it to remove.
    public static func needsPrivilege(present: (String) -> Bool) -> Bool {
        privilegedPaths.contains(where: present)
    }

    /// `rm -f` on two paths that are literals in this file: nothing is interpolated into it, and it never
    /// recurses, so the worst a bug in the caller can do is remove one of these two files.
    public static var privilegedScript: String {
        "/bin/rm -f " + privilegedPaths.joined(separator: " ")
    }

    /// How long the helper waits for this process to go before giving up, in tenths of a second. A helper
    /// that could spin for ever is worse than one that stops: what it does after the wait is a handful of
    /// removals of paths nothing holds open.
    public static let helperWaitTenths = 600

    /// What only a process that outlives this one can do, and why none of it can be done here.
    ///
    /// **Everything removed while the app is still running comes back.** The way out through `shutdown()`
    /// recreates the activity journal, and so the Application Support folder with it; and `cfprefsd` writes
    /// the preferences domain out again as the process exits, leaving an empty plist where a Mac that never
    /// had KoffeeLid has no file at all. So the last removals wait for the pid.
    ///
    /// The caches, the HTTP storage and the saved window state go too. They are not dangerous, but they are
    /// named after the bundle identifier and belong to nothing else, and an uninstall that leaves them is
    /// not the fresh Mac it claims to be.
    public static func helperScript(pid: Int32, domain: String, supportDirectory: String, home: String) -> String {
        let library = home + "/Library"
        let paths = [
            supportDirectory,
            "\(library)/Preferences/\(domain).plist",
            "\(library)/Caches/\(domain)",
            "\(library)/HTTPStorages/\(domain)",
            "\(library)/HTTPStorages/\(domain).binarycookies",
            "\(library)/Saved Application State/\(domain).savedState",
        ]
        return ([
            "i=0",
            "while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt \(helperWaitTenths) ]; do /bin/sleep 0.1; i=$((i+1)); done",
            // Before the file is removed, or cfprefsd writes its cache back over the gap.
            "/usr/bin/defaults delete \(domain) 2>/dev/null",
            "/bin/rm -rf " + paths.map(shellQuoted).joined(separator: " "),
            // One per host identifier, so a glob rather than a path; `find` keeps the glob away from a home
            // folder whose name has a space in it.
            "/usr/bin/find \(shellQuoted(library + "/Preferences/ByHost")) -maxdepth 1 -name \(shellQuoted(domain + ".*.plist")) -delete 2>/dev/null",
        ] as [String]).joined(separator: "\n") + "\n"
    }

    /// Single quotes, with any quote in the path closed and reopened around an escaped one. The home folder
    /// is the user's to name, spaces and all.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
