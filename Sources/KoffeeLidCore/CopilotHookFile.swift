import Foundation

/// The whole `~/.copilot/hooks/koffeelid.json` file: one `command` entry per subscribed event, camelCase
/// keys, `exec` (no shell), the event name riding in `args` since a camelCase payload carries none
/// (`ActivityEventName.copilotHookEvents` names them). Pure dictionary building; file IO lives in
/// `HookInstaller`.
public enum CopilotHookFile {
    /// The 7 events Copilot's hooks subscribe to, in the order the file lists them.
    public static let events = ActivityEventName.copilotHookEvents

    /// The whole file for `hookPath` (the hook binary's absolute path).
    public static func root(hookPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events { hooks[event] = [entry(hookPath: hookPath, event: event)] }
        return ["version": 1, "hooks": hooks]
    }

    static func entry(hookPath: String, event: String) -> [String: Any] {
        ["type": "command", "exec": hookPath, "args": ["hook", "copilot", event], "timeoutSec": 5]
    }

    /// An entry is ours when `exec` ends in our binary's path inside a bundle, whatever bundle path it was
    /// installed from, and `args` starts `["hook","copilot"]`.
    private static func isOurEntry(_ entry: [String: Any]) -> Bool {
        guard let exec = entry["exec"] as? String, exec.hasSuffix("/Contents/MacOS/KoffeeLidHook"),
              let args = entry["args"] as? [String], args.count >= 2, args[0] == "hook", args[1] == "copilot"
        else { return false }
        return true
    }

    /// Whether every hook entry `root` holds is ours: the file KoffeeLid writes at this path is wholly its
    /// own, so a pre-existing file there is installed over only when it already looks like one of ours. A
    /// `hooks` key that is not an object, or an event whose value is not an array of our shape, fails this.
    public static func isOurs(_ root: [String: Any]) -> Bool {
        if root.isEmpty { return true }
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let array = value as? [Any] else { return false }
            for element in array {
                guard let entry = element as? [String: Any], isOurEntry(entry) else { return false }
            }
        }
        return true
    }

    /// How many of the 7 events already hold an entry pointing at exactly `hookPath`: not just "ours"
    /// (`isOurs`, any bundle path), but current — this bundle's own path, so a stale entry left by a moved
    /// or older bundle does not count as installed.
    public static func installedCount(in root: [String: Any], hookPath: String) -> Int {
        guard let hooks = root["hooks"] as? [String: Any] else { return 0 }
        return events.filter { event in
            guard let array = hooks[event] as? [Any] else { return false }
            return array.contains { element in
                guard let entry = element as? [String: Any], let exec = entry["exec"] as? String,
                      let args = entry["args"] as? [String] else { return false }
                return exec == hookPath && args == ["hook", "copilot", event]
            }
        }.count
    }

    /// True when `disableAllHooks` is `true` in either `~/.copilot/settings.json` or `~/.copilot/config.json`
    /// (whole-line `//` comments stripped first: `config.json` starts with one, and is otherwise plain
    /// JSON). Empty text is an absent file; unparseable text decides nothing.
    public static func disabled(settingsText: String, configText: String) -> Bool {
        isDisabled(settingsText) || isDisabled(configText)
    }

    private static func isDisabled(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let stripped = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String(line)
        }.joined(separator: "\n")
        guard let data = stripped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["disableAllHooks"] as? Bool == true
    }
}
