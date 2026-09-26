import Foundation
import KoffeeLidCore

/// `koffeelid install-hooks` / `uninstall-hooks` and the Settings buttons share this. Edits Claude Code's
/// `~/.claude/settings.json` through `HookConfig.claude`, and Codex's `~/.codex/hooks.json` through
/// `HookConfig.codex` together with the trust Codex wants in `~/.codex/config.toml` (`CodexHookTrust`);
/// backs every file up first, and reports what actually landed. Writes Copilot's whole
/// `~/.copilot/hooks/koffeelid.json` (`CopilotHookFile`) and OpenCode's whole
/// `~/.config/opencode/plugins/koffeelid.js` (`OpencodePlugin`): each file is wholly ours, so there is
/// nothing to merge and no backup to take, and a pre-existing file that is not recognisably ours is left
/// untouched.
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
    static var codexCommand: String { "\(hookPath) hook codex" }
    static var snippet: String { ShellInit.zsh(hookPath: hookPath) }

    /// Codex's home, symlinks resolved as Codex resolves it: the hooks file's path is part of every trust key.
    static var codexHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").resolvingSymlinksInPath() }
    static var codexHooksURL: URL { codexHome.appendingPathComponent("hooks.json") }
    static var codexHooksBackupURL: URL { codexHome.appendingPathComponent("hooks.json.backup-koffeelid") }
    static var codexConfigURL: URL { codexHome.appendingPathComponent("config.toml") }
    static var codexConfigBackupURL: URL { codexHome.appendingPathComponent("config.toml.backup-koffeelid") }
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
            let edited = HookConfig.claude.install(into: root, command: command)
            try HookSettingsFile.write(edited, to: settingsURL)
            let n = HookConfig.claude.installedCount(in: edited, command: command), total = HookConfig.claude.events.count
            if n == total { return (true, "Installed \(total) Claude Code hooks -> \(command)") }
            let missing = HookConfig.claude.events.filter { HookConfig.claude.installedCommand(in: edited, event: $0) != command }
            return (false, "Installed \(n) of \(total) hooks -> \(command)\nDeclined to touch: \(missing.joined(separator: ", ")) (their value in ~/.claude/settings.json has a shape this tool does not rewrite)")
        } catch { return (false, "install-hooks failed: \(error)\nYour settings file was not modified.") }
    }

    static func uninstall() -> (ok: Bool, message: String) {
        do {
            guard let root = try HookSettingsFile.load(at: settingsURL) else { return (true, "No settings file found — nothing to remove.") }
            try HookSettingsFile.backup(from: settingsURL, to: backupURL)
            try HookSettingsFile.write(HookConfig.claude.uninstall(from: root), to: settingsURL)
            return (true, "Removed KoffeeLid hooks.")
        } catch { return (false, "uninstall-hooks failed: \(error)\nYour settings file was not modified.") }
    }

    /// How many of the 15 events currently point at THIS bundle's hook binary; nil if settings.json is
    /// unreadable/invalid. An absent file is not an error: it counts as an empty settings object (0 installed).
    static func installedCount() -> Int? {
        let root: [String: Any]?
        do { root = try HookSettingsFile.load(at: settingsURL) } catch { return nil }
        return HookConfig.claude.installedCount(in: root ?? [:], command: command)
    }

    // MARK: Codex

    enum CodexFailure: Error, CustomStringConvertible {
        case configUnreadable, stateNotRewritable
        var description: String {
            switch self {
            case .configUnreadable: return "could not read ~/.codex/config.toml as UTF-8; refusing to touch it"
            case .stateNotRewritable: return "~/.codex/config.toml holds a hook state in a form this tool does not rewrite (an inline `state` table); trust the hooks from Codex's /hooks screen instead"
            }
        }
    }

    /// `~/.codex/config.toml` as text; empty when absent, an error when it cannot be read as UTF-8.
    private static func codexConfigText() throws -> String {
        guard FileManager.default.fileExists(atPath: codexConfigURL.path) else { return "" }
        guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { throw CodexFailure.configUnreadable }
        return text
    }

    /// The 12 hooks into `~/.codex/hooks.json`, then their trust into `~/.codex/config.toml`: without the
    /// second, Codex lists the hooks and never runs them. Both files are read and every refusal decided
    /// before either is written; a failure between the two writes says which file landed.
    static func installCodex() -> (ok: Bool, message: String) {
        let config = HookConfig.codex, total = config.events.count
        var written: [String] = []
        do {
            let root = try HookSettingsFile.load(at: codexHooksURL) ?? [:]
            let configText = try codexConfigText()
            let edited = config.install(into: root, command: codexCommand)
            let entries = CodexHookTrust.entries(hooksFile: codexHooksURL.path, root: edited, config: config, command: codexCommand)
            guard let trusted = CodexHookTrust.trusting(configText, entries: entries, ourHashes: CodexHookTrust.hashes(config: config, command: codexCommand)) else {
                throw CodexFailure.stateNotRewritable
            }
            try HookSettingsFile.backup(from: codexHooksURL, to: codexHooksBackupURL)
            try HookSettingsFile.write(edited, to: codexHooksURL)
            written.append("~/.codex/hooks.json")
            try HookSettingsFile.backup(from: codexConfigURL, to: codexConfigBackupURL)
            try trusted.write(to: codexConfigURL, atomically: true, encoding: .utf8)
            written.append("~/.codex/config.toml")
            let n = config.installedCount(in: edited, command: codexCommand)
            if n == total { return (true, "Installed \(total) Codex hooks -> \(codexCommand), trusted in ~/.codex/config.toml") }
            let missing = config.events.filter { config.installedCommand(in: edited, event: $0) != codexCommand }
            return (false, "Installed \(n) of \(total) hooks -> \(codexCommand)\nDeclined to touch: \(missing.joined(separator: ", ")) (their value in ~/.codex/hooks.json has a shape this tool does not rewrite)")
        } catch { return (false, "install-hooks codex failed: \(error)\n" + outcome(written)) }
    }

    /// The trust goes first, named after the hooks as they still sit in the file, then the hooks.
    static func uninstallCodex() -> (ok: Bool, message: String) {
        let config = HookConfig.codex
        var written: [String] = []
        do {
            let root = try HookSettingsFile.load(at: codexHooksURL)
            let configText = try codexConfigText()
            let entries = CodexHookTrust.entries(hooksFile: codexHooksURL.path, root: root ?? [:], config: config, command: codexCommand)
            if let untrusted = CodexHookTrust.untrusting(configText, keys: Set(entries.map(\.key)), ourHashes: CodexHookTrust.hashes(config: config, command: codexCommand)) {
                try HookSettingsFile.backup(from: codexConfigURL, to: codexConfigBackupURL)
                try untrusted.write(to: codexConfigURL, atomically: true, encoding: .utf8)
                written.append("~/.codex/config.toml")
            }
            guard let root else { return (true, "No Codex hooks file found — nothing to remove.") }
            try HookSettingsFile.backup(from: codexHooksURL, to: codexHooksBackupURL)
            try HookSettingsFile.write(config.uninstall(from: root), to: codexHooksURL)
            return (true, "Removed KoffeeLid hooks from Codex.")
        } catch { return (false, "uninstall-hooks codex failed: \(error)\n" + outcome(written)) }
    }

    private static func outcome(_ written: [String]) -> String {
        written.isEmpty ? "Your Codex files were not modified." : "Written before the failure: \(written.joined(separator: ", ")) (a .backup-koffeelid copy sits beside it)."
    }

    /// How many of the 12 events point at THIS bundle's hook binary and are trusted by Codex; nil when
    /// either file is unreadable or invalid. Absent files count as empty.
    static func codexInstalledCount() -> Int? {
        codexInstalledCount(hooksURL: codexHooksURL, configURL: codexConfigURL, command: codexCommand)
    }

    /// The same, told its paths: file IO only, so the Health page can ask off the main thread (`hookPath`
    /// reads the bundle on the main actor).
    static func codexInstalledCount(hooksURL: URL, configURL: URL, command: String) -> Int? {
        let root: [String: Any]?, configText: String
        do {
            root = try HookSettingsFile.load(at: hooksURL)
            if FileManager.default.fileExists(atPath: configURL.path) {
                guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
                configText = text
            } else { configText = "" }
        } catch { return nil }
        let config = HookConfig.codex
        let states = CodexHookTrust.states(in: configText)
        return CodexHookTrust.entries(hooksFile: hooksURL.path, root: root ?? [:], config: config, command: command)
            .filter { states[$0.key]?.trustedHash == $0.hash && states[$0.key]?.enabled != false }.count
    }

    // MARK: Copilot

    /// Copilot's home, symlinks resolved like the others.
    static var copilotHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot").resolvingSymlinksInPath() }
    static var copilotHooksURL: URL { copilotHome.appendingPathComponent("hooks/koffeelid.json") }
    static var copilotSettingsURL: URL { copilotHome.appendingPathComponent("settings.json") }
    static var copilotConfigURL: URL { copilotHome.appendingPathComponent("config.json") }
    /// Copilot's own session folder: evidence Copilot itself created, unlike `copilotHome` (`~/.copilot`),
    /// which `installCopilot()` creates too when it writes the hooks file.
    static var copilotSessionStateURL: URL { copilotHome.appendingPathComponent("session-state") }

    /// Writes the whole `~/.copilot/hooks/koffeelid.json`: the file is wholly ours, so there is no backup to
    /// take. Refuses, unchanged, when a file already sits there and does not look like one of ours.
    static func installCopilot() -> (ok: Bool, message: String) {
        let path = copilotHooksURL
        if FileManager.default.fileExists(atPath: path.path) {
            guard let root = try? HookSettingsFile.load(at: path), CopilotHookFile.isOurs(root) else {
                return (false, "~/.copilot/hooks/koffeelid.json already exists and is not a file KoffeeLid wrote; left it untouched.")
            }
        }
        do {
            try HookSettingsFile.write(CopilotHookFile.root(hookPath: hookPath), to: path)
            return (true, "Installed \(CopilotHookFile.events.count) Copilot hooks -> \(hookPath) hook copilot")
        } catch { return (false, "install-hooks copilot failed: \(error)\nYour Copilot hooks file was not modified.") }
    }

    /// Absent is success: there is nothing of ours left to remove. Refuses, unchanged, a file that is not
    /// ours or cannot even be parsed: never delete what might be a stranger's.
    static func uninstallCopilot() -> (ok: Bool, message: String) {
        let path = copilotHooksURL
        guard FileManager.default.fileExists(atPath: path.path) else { return (true, "No Copilot hooks file found — nothing to remove.") }
        guard let root = try? HookSettingsFile.load(at: path) else {
            return (false, "~/.copilot/hooks/koffeelid.json could not be read as JSON; left it untouched.")
        }
        guard CopilotHookFile.isOurs(root) else {
            return (false, "~/.copilot/hooks/koffeelid.json does not look like a file KoffeeLid wrote; left it untouched.")
        }
        do {
            try FileManager.default.removeItem(at: path)
            removeIfEmpty(path.deletingLastPathComponent())
            return (true, "Removed the Copilot hooks file.")
        } catch { return (false, "uninstall-hooks copilot failed: \(error)\nYour Copilot hooks file was not modified.") }
    }

    /// Removes `dir` only when it is now empty, never a folder with anything left in it and never anything
    /// above it: `uninstallCopilot`'s `~/.copilot/hooks/`, `uninstallOpencode`'s
    /// `~/.config/opencode/plugins/`, and nothing else. `~/.copilot` and `~/.config/opencode` are left alone
    /// either way, whatever else Copilot or OpenCode keeps there.
    private static func removeIfEmpty(_ dir: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// A file sits at `~/.copilot/hooks/koffeelid.json`, whether or not it matches this bundle's own path:
    /// the gate Reset and Uninstall use to decide whether to attempt a removal at all (which then reports its
    /// own success or refusal). `copilotInstalledCount() == events.count` is the stricter, byte-exact "is this
    /// copy's own set-up still there" the menu gate and the Settings/Health rows ask instead.
    static func copilotHooksPresent() -> Bool { FileManager.default.fileExists(atPath: copilotHooksURL.path) }

    /// How many of the 7 events point at THIS bundle's hook binary; nil if the file is unreadable/invalid.
    /// An absent file counts as empty.
    static func copilotInstalledCount() -> Int? { copilotInstalledCount(hooksURL: copilotHooksURL, hookPath: hookPath) }

    /// The same, told its path and the hook path: file IO only, so the Health page can ask off the main
    /// thread (`hookPath` reads the bundle on the main actor).
    static func copilotInstalledCount(hooksURL: URL, hookPath: String) -> Int? {
        let root: [String: Any]?
        do { root = try HookSettingsFile.load(at: hooksURL) } catch { return nil }
        return CopilotHookFile.installedCount(in: root ?? [:], hookPath: hookPath)
    }

    /// `disableAllHooks` in either `~/.copilot/settings.json` or `~/.copilot/config.json`; both absent reads
    /// as not disabled.
    static func copilotHooksDisabled() -> Bool {
        let settingsText = (try? String(contentsOf: copilotSettingsURL, encoding: .utf8)) ?? ""
        let configText = (try? String(contentsOf: copilotConfigURL, encoding: .utf8)) ?? ""
        return CopilotHookFile.disabled(settingsText: settingsText, configText: configText)
    }

    // MARK: OpenCode

    /// OpenCode's config directory, symlinks resolved like the others.
    static var opencodeConfigDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode").resolvingSymlinksInPath() }
    static var opencodePluginURL: URL { opencodeConfigDir.appendingPathComponent("plugins/koffeelid.js") }

    /// Writes the whole `~/.config/opencode/plugins/koffeelid.js`: the file is wholly ours, so there is no
    /// backup to take. Refuses, unchanged, when a file already sits there and does not look like one of ours.
    static func installOpencode() -> (ok: Bool, message: String) {
        let path = opencodePluginURL
        if FileManager.default.fileExists(atPath: path.path) {
            guard let existing = try? String(contentsOf: path, encoding: .utf8), OpencodePlugin.isOurs(existing) else {
                return (false, "~/.config/opencode/plugins/koffeelid.js already exists and is not a file KoffeeLid wrote; left it untouched.")
            }
        }
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try OpencodePlugin.source(hookPath: hookPath).write(to: path, atomically: true, encoding: .utf8)
            return (true, "Installed the OpenCode plugin -> \(hookPath) hook opencode")
        } catch { return (false, "install-hooks opencode failed: \(error)\nYour OpenCode plugin was not modified.") }
    }

    /// Absent is success: there is nothing of ours left to remove. Refuses, unchanged, a file that is not
    /// ours or cannot even be read as text: never delete what might be a stranger's.
    static func uninstallOpencode() -> (ok: Bool, message: String) {
        let path = opencodePluginURL
        guard FileManager.default.fileExists(atPath: path.path) else { return (true, "No OpenCode plugin found — nothing to remove.") }
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return (false, "~/.config/opencode/plugins/koffeelid.js could not be read as UTF-8; left it untouched.")
        }
        guard OpencodePlugin.isOurs(text) else {
            return (false, "~/.config/opencode/plugins/koffeelid.js does not look like a file KoffeeLid wrote; left it untouched.")
        }
        do {
            try FileManager.default.removeItem(at: path)
            removeIfEmpty(path.deletingLastPathComponent())
            return (true, "Removed the OpenCode plugin.")
        } catch { return (false, "uninstall-hooks opencode failed: \(error)\nYour OpenCode plugin was not modified.") }
    }

    /// A file sits at `~/.config/opencode/plugins/koffeelid.js`, whether or not it matches this bundle's own
    /// path: the gate Reset and Uninstall use to decide whether to attempt a removal at all (which then
    /// reports its own success or refusal). `opencodeInstalled()` (byte-exact) is what the menu gate and the
    /// Settings/Health rows ask instead.
    static func opencodePluginPresent() -> Bool { FileManager.default.fileExists(atPath: opencodePluginURL.path) }

    /// Whether the plugin at `~/.config/opencode/plugins/koffeelid.js` matches, byte for byte, what this
    /// bundle would write today.
    static func opencodeInstalled() -> Bool { opencodeInstalled(pluginURL: opencodePluginURL, hookPath: hookPath) }

    /// The same, told its path and the hook path: file IO only, so the Health page can ask off the main
    /// thread (`hookPath` reads the bundle on the main actor).
    static func opencodeInstalled(pluginURL: URL, hookPath: String) -> Bool {
        guard let text = try? String(contentsOf: pluginURL, encoding: .utf8) else { return false }
        return OpencodePlugin.isCurrent(text, hookPath: hookPath)
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
