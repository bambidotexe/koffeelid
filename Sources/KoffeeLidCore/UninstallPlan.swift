import Foundation

/// What taking KoffeeLid off a Mac has to remove, and the one privileged command that removes the part of
/// it a user cannot.
///
/// Dragging the bundle to the Trash removes the app and nothing else: the sudoers rule, the wrapper on the
/// PATH, the login items, the Claude Code hooks and the zsh snippet stay, and the hooks go on running a
/// binary that is no longer there on every Claude Code event. Everything in that list is removable from the
/// app itself except the two files below, which are root-owned.
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
}
