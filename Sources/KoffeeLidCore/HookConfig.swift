import Foundation

/// Edits the `hooks` object of Claude Code's `~/.claude/settings.json`. Pure dictionary transforms;
/// file IO lives in `HookSettingsFile`. Shapes this code does not understand are left untouched, and the
/// caller counts what actually landed rather than assuming.
public enum HookConfig {
    public static let events: [String] = ActivityEventName.claudeCodeEvents.map(\.rawValue)
    /// Recognises our own entries whatever bundle path they were installed from.
    public static let ourMarker = "/Contents/MacOS/KoffeeLidHook hook"

    public static func install(into root: [String: Any], command: String) -> [String: Any] {
        var root = root
        if let existing = root["hooks"], !(existing is [String: Any]) { return root }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for (event, value) in hooks where value is [Any] { hooks[event] = scrubEventValue(value) }
        for event in events {
            if let existing = hooks[event], !(existing is [Any]) { continue }
            var groups = (hooks[event] as? [Any]) ?? []
            groups.append(["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 5]]] as [String: Any])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    public static func uninstall(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks where value is [Any] {
            let scrubbed = scrubEventValue(value)
            if scrubbed.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = scrubbed }
        }
        root["hooks"] = hooks
        return root
    }

    public static func installedCommand(in root: [String: Any], event: String) -> String? {
        guard let hooks = root["hooks"] as? [String: Any], let groups = hooks[event] as? [Any] else { return nil }
        for case let group as [String: Any] in groups {
            for case let hook as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                if let command = hook["command"] as? String, command.contains(ourMarker) { return command }
            }
        }
        return nil
    }
    public static func installedCount(in root: [String: Any], command: String) -> Int {
        events.filter { installedCommand(in: root, event: $0) == command }.count
    }

    static func scrubEventValue(_ value: Any) -> [Any] {
        guard let elements = value as? [Any] else { return [] }
        return elements.compactMap { element -> Any? in
            guard let group = element as? [String: Any] else { return element }
            return scrubGroup(group)
        }
    }
    /// Remove our items from one group; a group left empty is dropped; unknown shapes pass through.
    static func scrubGroup(_ group: [String: Any]) -> [String: Any]? {
        guard let items = group["hooks"] as? [Any] else { return group }
        let kept = items.filter { item in
            guard let hook = item as? [String: Any], let command = hook["command"] as? String else { return true }
            return !command.contains(ourMarker)
        }
        if kept.isEmpty { return nil }
        var group = group; group["hooks"] = kept; return group
    }
}
