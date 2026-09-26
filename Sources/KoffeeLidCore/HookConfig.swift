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
    /// A whole command of ours from before the hook named its agent (`… KoffeeLidHook hook`, nothing after):
    /// still ours to replace and remove, never counted as set up, since such a hook writes nothing now.
    let legacySuffix: String?
    /// Claude Code takes an explicit match-all matcher. Codex reads a missing one as match-all and hashes
    /// an entry's identity for its trust, so the smaller entry is the one it gets.
    let matcher: String?
    /// Seconds the agent gives the hook. Codex caps SessionEnd and Interrupt at 3 s and warns above it.
    let timeout: (String) -> Int

    public static let claude = HookConfig(
        agent: .claude, events: ActivityEventName.claudeCodeEvents.map(\.rawValue),
        marker: "/Contents/MacOS/KoffeeLidHook hook claude", legacySuffix: "/Contents/MacOS/KoffeeLidHook hook",
        matcher: "*", timeout: { _ in 5 })
    public static let codex = HookConfig(
        agent: .codex, events: ActivityEventName.codexEvents.map(\.rawValue),
        marker: "/Contents/MacOS/KoffeeLidHook hook codex", legacySuffix: nil, matcher: nil,
        timeout: { $0 == "SessionEnd" || $0 == "Interrupt" ? 3 : 5 })

    /// Whether a hook command is one of ours, in any form this spec ever wrote.
    public func isOurs(_ command: String) -> Bool {
        command.contains(marker) || (legacySuffix.map { command.trimmingCharacters(in: .whitespaces).hasSuffix($0) } ?? false)
    }
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

    /// Our group goes after every existing group the first time and in its own place afterwards: a group of
    /// ours already in the event's array is replaced at its index, so no group after it moves (Codex names a
    /// hook's trust after that index). Any other trace of ours — a second group, a handler in a stranger's
    /// group, an entry under an event no longer subscribed — is scrubbed.
    public func install(into root: [String: Any], command: String) -> [String: Any] {
        var root = root
        if let existing = root["hooks"], !(existing is [String: Any]) { return root }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for (event, value) in hooks where value is [Any] && !events.contains(event) { hooks[event] = scrubEventValue(value) }
        for event in events {
            if let existing = hooks[event], !(existing is [Any]) { continue }
            let groups = (hooks[event] as? [Any]) ?? []
            let fresh = entry(for: event, command: command)
            if let index = groups.firstIndex(where: { ($0 as? [String: Any]).map { scrubGroup($0) == nil } ?? false }) {
                hooks[event] = groups.enumerated().compactMap { i, group -> Any? in
                    if i == index { return fresh }
                    guard let group = group as? [String: Any] else { return group }
                    return scrubGroup(group)
                }
            } else {
                hooks[event] = scrubEventValue(groups) + [fresh]
            }
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
                if let command = hook["command"] as? String, isOurs(command) { return command }
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
            return !isOurs(command)
        }
        if kept.isEmpty { return nil }
        var group = group; group["hooks"] = kept; return group
    }
}
