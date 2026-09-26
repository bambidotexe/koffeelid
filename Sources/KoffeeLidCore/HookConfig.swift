import Foundation

/// Edits the `hooks` object of an agent's hook file: Claude Code's `~/.claude/settings.json` and Codex's
/// `~/.codex/hooks.json` hold the events under the same key, in the same shape. Pure dictionary transforms;
/// file IO lives in `HookSettingsFile`. Shapes this code does not understand are left untouched, and the
/// caller counts what actually landed rather than assuming.
public struct HookConfig {
    public let agent: ActivityAgent
    /// The events the hook subscribes to, in the order they are written.
    public let events: [String]
    /// Recognises our own entries whatever bundle path they were installed from.
    public let marker: String
    /// Claude Code takes an explicit match-all matcher. Codex reads a missing one as match-all and hashes
    /// an entry's identity for its trust, so the smaller entry is the one it gets.
    let matcher: String?
    /// Seconds the agent gives the hook. Codex caps SessionEnd and Interrupt at 3 s and warns above it.
    let timeout: (String) -> Int

    public static let claude = HookConfig(
        agent: .claude, events: ActivityEventName.claudeCodeEvents.map(\.rawValue),
        marker: "/Contents/MacOS/KoffeeLidHook hook", matcher: "*", timeout: { _ in 5 })
    public static let codex = HookConfig(
        agent: .codex, events: ActivityEventName.codexEvents.map(\.rawValue),
        marker: "/Contents/MacOS/KoffeeLidHook hook codex", matcher: nil,
        timeout: { $0 == "SessionEnd" || $0 == "Interrupt" ? 3 : 5 })
    /// The spec of an agent whose hooks live in such a `hooks` object; nil for Copilot, whose hook file has
    /// another shape, and OpenCode, which takes a plugin.
    public static func of(_ agent: ActivityAgent) -> HookConfig? {
        switch agent {
        case .claude: return claude
        case .codex: return codex
        case .copilot, .opencode: return nil
        }
    }

    public func timeoutSeconds(for event: String) -> Int { timeout(event) }

    /// The group written for one event: one command hook, and Claude Code's matcher.
    public func entry(for event: String, command: String) -> [String: Any] {
        var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout(event)] as [String: Any]]]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    public func install(into root: [String: Any], command: String) -> [String: Any] {
        var root = root
        if let existing = root["hooks"], !(existing is [String: Any]) { return root }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for (event, value) in hooks where value is [Any] { hooks[event] = scrubEventValue(value) }
        for event in events {
            if let existing = hooks[event], !(existing is [Any]) { continue }
            var groups = (hooks[event] as? [Any]) ?? []
            groups.append(entry(for: event, command: command))
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    public func uninstall(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks where value is [Any] {
            let scrubbed = scrubEventValue(value)
            if scrubbed.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = scrubbed }
        }
        root["hooks"] = hooks
        return root
    }

    public func installedCommand(in root: [String: Any], event: String) -> String? {
        guard let hooks = root["hooks"] as? [String: Any], let groups = hooks[event] as? [Any] else { return nil }
        for case let group as [String: Any] in groups {
            for case let hook as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                if let command = hook["command"] as? String, command.contains(marker) { return command }
            }
        }
        return nil
    }
    public func installedCount(in root: [String: Any], command: String) -> Int {
        events.filter { installedCommand(in: root, event: $0) == command }.count
    }

    /// The index, in the event's array, of the group holding `command`: Codex names a hook's trust after it.
    public func installedGroupIndex(in root: [String: Any], event: String, command: String) -> Int? {
        guard let hooks = root["hooks"] as? [String: Any], let groups = hooks[event] as? [Any] else { return nil }
        return groups.firstIndex { element in
            guard let group = element as? [String: Any] else { return false }
            return ((group["hooks"] as? [Any]) ?? []).contains { ($0 as? [String: Any])?["command"] as? String == command }
        }
    }

    func scrubEventValue(_ value: Any) -> [Any] {
        guard let elements = value as? [Any] else { return [] }
        return elements.compactMap { element -> Any? in
            guard let group = element as? [String: Any] else { return element }
            return scrubGroup(group)
        }
    }
    /// Remove our items from one group; a group left empty is dropped; unknown shapes pass through.
    func scrubGroup(_ group: [String: Any]) -> [String: Any]? {
        guard let items = group["hooks"] as? [Any] else { return group }
        let kept = items.filter { item in
            guard let hook = item as? [String: Any], let command = hook["command"] as? String else { return true }
            return !command.contains(marker)
        }
        if kept.isEmpty { return nil }
        var group = group; group["hooks"] = kept; return group
    }
}
