import Foundation
import KoffeeLidCore

/// `koffeelid install-hooks` / `uninstall-hooks` and the Settings button share this. Edits
/// `~/.claude/settings.json` through `HookConfig`, backs it up first, and reports what actually landed.
enum HookInstaller {
    /// Resolved like `zshrcURL`: a dotfiles-managed `~/.claude/settings.json` is often a symlink, and
    /// reading/writing through the resolved path keeps the link intact instead of replacing it.
    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath() }
    static var backupURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json.backup-koffeelid").resolvingSymlinksInPath() }
    /// The hook binary's resolved absolute path: a hook pointing at a nonexistent path fails silently.
    /// `ActivityMonitor` is `@MainActor`; the CLI path (`main.swift`, before `app.run()`) is single-threaded
    /// on the main thread already, so this synchronous read is safe.
    static var hookPath: String {
        MainActor.assumeIsolated { ActivityMonitor.hookBinaryURL }.resolvingSymlinksInPath().standardizedFileURL.path
    }
    static var command: String { "\(hookPath) hook" }
    static var snippet: String { ShellInit.zsh(hookPath: hookPath) }
    /// Guarded, so a shell on a Mac where the app (or the wrapper) is gone stays silent.
    static var zshLine: String {
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/koffeelid") {
            return "command -v koffeelid >/dev/null 2>&1 && eval \"$(koffeelid shell-init zsh)\""
        }
        let binary = "\(Bundle.main.bundleURL.path)/Contents/MacOS/KoffeeLid"
        return "[ -x \"\(binary)\" ] && eval \"$(\"\(binary)\" shell-init zsh)\""
    }

    static func install() -> (ok: Bool, message: String) {
        do {
            let root = try HookSettingsFile.load(at: settingsURL) ?? [:]
            try HookSettingsFile.backup(from: settingsURL, to: backupURL)
            let edited = HookConfig.install(into: root, command: command)
            try HookSettingsFile.write(edited, to: settingsURL)
            let n = HookConfig.installedCount(in: edited, command: command), total = HookConfig.events.count
            if n == total { return (true, "Installed \(total) Claude Code hooks -> \(command)") }
            let missing = HookConfig.events.filter { HookConfig.installedCommand(in: edited, event: $0) != command }
            return (false, "Installed \(n) of \(total) hooks -> \(command)\nDeclined to touch: \(missing.joined(separator: ", ")) (their value in ~/.claude/settings.json has a shape this tool does not rewrite)")
        } catch { return (false, "install-hooks failed: \(error)\nYour settings file was not modified.") }
    }

    static func uninstall() -> (ok: Bool, message: String) {
        do {
            guard let root = try HookSettingsFile.load(at: settingsURL) else { return (true, "No settings file found — nothing to remove.") }
            try HookSettingsFile.backup(from: settingsURL, to: backupURL)
            try HookSettingsFile.write(HookConfig.uninstall(from: root), to: settingsURL)
            return (true, "Removed KoffeeLid hooks.")
        } catch { return (false, "uninstall-hooks failed: \(error)\nYour settings file was not modified.") }
    }

    /// How many of the 15 events currently point at THIS bundle's hook binary; nil if settings.json is
    /// unreadable/invalid. An absent file is not an error: it counts as an empty settings object (0 installed).
    static func installedCount() -> Int? {
        let root: [String: Any]?
        do { root = try HookSettingsFile.load(at: settingsURL) } catch { return nil }
        return HookConfig.installedCount(in: root ?? [:], command: command)
    }

    // MARK: ~/.zshrc

    /// Resolved like `hookPath`: a dotfiles-managed `~/.zshrc` is often a symlink, and reading/writing
    /// through the resolved path keeps the link intact instead of replacing it with a plain file.
    static var zshrcURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc").resolvingSymlinksInPath() }

    /// True when ~/.zshrc already sources the snippet (`ShellInit.zshrcSourcesSnippet`). False on an
    /// unreadable file so the row still offers the button rather than hiding it behind a false "installed".
    static func zshrcHasSnippet() -> Bool {
        (try? String(contentsOf: zshrcURL, encoding: .utf8)).map(ShellInit.zshrcSourcesSnippet) ?? false
    }

    /// Appends the marker and the eval line to ~/.zshrc (creating the file if needed). Idempotent.
    /// Refuses to touch a file it cannot read as UTF-8 rather than silently overwriting it: a `try?`
    /// coalesced to `""` would make an unreadable (e.g. Latin-1) file look empty and the atomic write
    /// would then replace the user's whole file with just the new block.
    static func addToZshrc() -> (ok: Bool, message: String) {
        let existing: String
        if FileManager.default.fileExists(atPath: zshrcURL.path) {
            guard let current = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
                return (false, "Could not read ~/.zshrc (not UTF-8?); left it untouched.")
            }
            existing = current
        } else { existing = "" }
        guard let text = ShellInit.zshrcAppending(zshLine, to: existing) else {
            return (true, "~/.zshrc already sources the KoffeeLid snippet.")
        }
        do {
            try text.write(to: zshrcURL, atomically: true, encoding: .utf8)
            return (true, "Added the KoffeeLid line to ~/.zshrc. Open a new terminal for it to take effect.")
        } catch { return (false, "Could not write ~/.zshrc: \(error.localizedDescription)") }
    }

    /// Removes the block `addToZshrc` added (and any hand-written uncommented KoffeeLid `shell-init zsh` line;
    /// another tool's is left alone). Same read guard as `addToZshrc`: a file that cannot be read is left alone.
    static func removeFromZshrc() -> (ok: Bool, message: String) {
        guard FileManager.default.fileExists(atPath: zshrcURL.path) else { return (true, "~/.zshrc does not exist; nothing to remove.") }
        guard let existing = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
            return (false, "Could not read ~/.zshrc (not UTF-8?); left it untouched.")
        }
        guard let text = ShellInit.zshrcRemoving(from: existing) else { return (true, "~/.zshrc does not source the KoffeeLid snippet.") }
        do {
            try text.write(to: zshrcURL, atomically: true, encoding: .utf8)
            return (true, "Removed the KoffeeLid line from ~/.zshrc. Open a new terminal for it to take effect.")
        } catch { return (false, "Could not write ~/.zshrc: \(error.localizedDescription)") }
    }
}
