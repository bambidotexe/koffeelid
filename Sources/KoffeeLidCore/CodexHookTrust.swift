import Foundation

/// Codex runs a hook of the user's only once the user has trusted it: `~/.codex/config.toml` holds, per
/// hook, a `[hooks.state."<key>"]` table whose `trusted_hash` must equal the hash Codex computes from the
/// hook's identity, or the hook is listed and never run. Codex's own `/hooks` screen writes that table;
/// `install-hooks codex` writes the same one, with the same key and the same hash, so the hooks run without
/// a visit to that screen. The key and the hash follow Codex's source (`codex-rs/hooks/src/lib.rs`,
/// `engine/discovery.rs`, `config/src/fingerprint.rs`) and `CodexHookTrustTests` holds them to a hash Codex
/// itself reported for a hook of this shape.
public enum CodexHookTrust {
    /// One trusted hook: the key of its state table and the hash the table must carry.
    public struct Entry: Equatable {
        public let key: String
        public let hash: String
        public init(key: String, hash: String) { self.key = key; self.hash = hash }
    }

    /// `<hooks file>:<event label>:<group index>:<handler index>`, the hooks file being the path Codex
    /// resolved its home to (symlinks resolved).
    public static func key(hooksFile: String, event: String, groupIndex: Int, handlerIndex: Int = 0) -> String {
        "\(hooksFile):\(label(event)):\(groupIndex):\(handlerIndex)"
    }

    /// `PreToolUse` reads `pre_tool_use` in a state key.
    public static func label(_ event: String) -> String {
        var out = ""
        for (i, ch) in event.enumerated() {
            if ch.isUppercase { if i > 0 { out.append("_") }; out.append(ch.lowercased()) } else { out.append(ch) }
        }
        return out
    }

    /// The hash Codex computes for a command hook: SHA-256 of the canonical JSON (keys sorted, no spaces)
    /// of its normalised identity, `{event_name, hooks: [{type: "command", command, timeout, async: false}]}`.
    /// No matcher is written, so none is hashed, and every optional field Codex leaves out of a normalised
    /// entry is left out here.
    public static func hash(event: String, command: String, timeout: Int) -> String {
        "sha256:" + SHA256.hex(of: Data(identityJSON(event: event, command: command, timeout: timeout).utf8))
    }

    public static func identityJSON(event: String, command: String, timeout: Int) -> String {
        "{\"event_name\":\(json(label(event))),\"hooks\":[{\"async\":false,\"command\":\(json(command)),\"timeout\":\(timeout),\"type\":\"command\"}]}"
    }

    /// A JSON string as serde_json writes one: `"`, `\` and control characters escaped, `/` and non-ASCII kept.
    public static func json(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The entries for our hooks as they sit in the hooks file's object: one per event our group is in.
    public static func entries(hooksFile: String, root: [String: Any], config: HookConfig, command: String) -> [Entry] {
        config.events.compactMap { event in
            guard let group = config.installedGroupIndex(in: root, event: event, command: command) else { return nil }
            return Entry(key: key(hooksFile: hooksFile, event: event, groupIndex: group),
                         hash: hash(event: event, command: command, timeout: config.timeoutSeconds(for: event)))
        }
    }

    /// Every hash our hooks can carry: a state table holding one is ours whatever its key says, which is
    /// how a table left under a key from an earlier layout of the hooks file is recognised.
    public static func hashes(config: HookConfig, command: String) -> Set<String> {
        Set(config.events.map { hash(event: $0, command: command, timeout: config.timeoutSeconds(for: $0)) })
    }

    // MARK: config.toml

    /// What one state table says.
    public struct State: Equatable {
        public var trustedHash: String?
        public var enabled: Bool?
        public init(trustedHash: String? = nil, enabled: Bool? = nil) { self.trustedHash = trustedHash; self.enabled = enabled }
    }

    /// The `[hooks.state."<key>"]` tables of `toml`, by key. That is the shape Codex writes, and the only
    /// one read: a state written any other way (an inline table under `[hooks]` or `[hooks.state]`) reads
    /// as absent, and `trusting` refuses to add a table beside it.
    public static func states(in toml: String) -> [String: State] {
        var out: [String: State] = [:]
        for block in blocks(of: toml) {
            guard let key = block.stateKey else { continue }
            var state = State()
            for line in block.body {
                guard let (name, value) = keyValue(line) else { continue }
                if name == "trusted_hash" { state.trustedHash = unquote(value) }
                if name == "enabled" { state.enabled = value == "true" ? true : value == "false" ? false : nil }
            }
            out[key] = state
        }
        return out
    }

    /// Whether every entry is trusted by `toml` and none is disabled.
    public static func allTrusted(_ toml: String, entries: [Entry]) -> Bool {
        let states = states(in: toml)
        return !entries.isEmpty && entries.allSatisfy { states[$0.key]?.trustedHash == $0.hash && states[$0.key]?.enabled != false }
    }

    /// `toml` with our entries trusted: every table that is ours (by key, or by carrying one of `ourHashes`)
    /// removed, then one fresh table per entry at the end, under a `[hooks.state]` header when the file has
    /// none, as Codex writes them. Nil when the file defines a hook state in a form this code does not
    /// rewrite, where adding a table would make the file invalid.
    public static func trusting(_ toml: String, entries: [Entry], ourHashes: Set<String>) -> String? {
        guard !definesStateOtherwise(toml, keys: Set(entries.map(\.key))) else { return nil }
        var text = removingTables(from: toml, keys: Set(entries.map(\.key)), hashes: ourHashes, dropEmptyStateHeader: false)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !blocks(of: text).contains(where: { $0.isStateHeader }) { text += (text.isEmpty ? "" : "\n") + "[hooks.state]\n" }
        for entry in entries {
            text += "\n[hooks.state.\(quoted(entry.key))]\ntrusted_hash = \(quoted(entry.hash))\n"
        }
        return text
    }

    /// `toml` with every table that is ours removed, and the `[hooks.state]` header with them when nothing
    /// is left under it. Nil when there was nothing to remove.
    public static func untrusting(_ toml: String, keys: Set<String>, ourHashes: Set<String>) -> String? {
        let text = removingTables(from: toml, keys: keys, hashes: ourHashes, dropEmptyStateHeader: true)
        return text == toml ? nil : text
    }

    // MARK: the scanner

    struct Block {
        var header: String?
        var body: [String]
        /// The key of a `[hooks.state."<key>"]` header.
        var stateKey: String? { header.flatMap(CodexHookTrust.stateKey) }
        var isStateHeader: Bool { header.map { stripped($0) == "[hooks.state]" } ?? false }
        var isHooksHeader: Bool { header.map { stripped($0) == "[hooks]" } ?? false }
        var lines: [String] { (header.map { [$0] } ?? []) + body }
    }

    /// The preamble and every table, each a header line and the lines up to the next header. A header is a
    /// line beginning with `[` outside a multi-line string.
    static func blocks(of toml: String) -> [Block] {
        var blocks: [Block] = [Block(header: nil, body: [])]
        var inMultiline = false
        for line in toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let quotes = line.components(separatedBy: "\"\"\"").count - 1 + line.components(separatedBy: "'''").count - 1
            if !inMultiline, line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                blocks.append(Block(header: line, body: []))
            } else {
                blocks[blocks.count - 1].body.append(line)
            }
            if quotes % 2 == 1 { inMultiline.toggle() }
        }
        return blocks
    }

    static func removingTables(from toml: String, keys: Set<String>, hashes: Set<String>, dropEmptyStateHeader: Bool) -> String {
        var kept = blocks(of: toml).filter { block in
            guard let key = block.stateKey else { return true }
            if keys.contains(key) { return false }
            let hash = block.body.compactMap(keyValue).first { $0.0 == "trusted_hash" }.map { unquote($0.1) }
            return !(hash.map(hashes.contains) ?? false)
        }
        if dropEmptyStateHeader, !kept.contains(where: { $0.stateKey != nil }) {
            kept.removeAll { $0.isStateHeader && !$0.body.contains(where: { keyValue($0) != nil }) }
        }
        var lines = kept.flatMap(\.lines)
        // A file that ended in a newline gives an empty last element; keep exactly one newline at the end.
        while lines.count > 1, lines.last == "", lines[lines.count - 2] == "" { lines.removeLast() }
        var text = lines.joined(separator: "\n")
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// A `state` key under `[hooks]`, or a key of ours under `[hooks.state]` written inline: forms Codex
    /// would read and this code would duplicate.
    static func definesStateOtherwise(_ toml: String, keys: Set<String>) -> Bool {
        for block in blocks(of: toml) {
            if block.isHooksHeader, block.body.contains(where: { keyValue($0)?.0 == "state" }) { return true }
            if block.isStateHeader {
                for line in block.body {
                    guard let (name, _) = keyValue(line) else { continue }
                    if keys.contains(unquote(name)) || keys.contains(where: { unquote(name).hasPrefix($0) }) { return true }
                }
            }
        }
        return false
    }

    /// The key of a `[hooks.state."<key>"]` (or `'<key>'`) header, comment and spaces ignored.
    public static func stateKey(_ header: String) -> String? {
        let text = stripped(header)
        guard text.hasPrefix("[hooks.state."), text.hasSuffix("]") else { return nil }
        let inner = text.dropFirst("[hooks.state.".count).dropLast()
        guard let open = inner.first, open == "\"" || open == "'", inner.count >= 2, inner.last == open else { return nil }
        let raw = String(inner.dropFirst().dropLast())
        return open == "\"" ? raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") : raw
    }

    /// `name = value` with the comment and the spaces gone; nil for a blank, a comment or anything else.
    static func keyValue(_ line: String) -> (String, String)? {
        let text = stripped(line)
        guard let eq = text.firstIndex(of: "="), !text.hasPrefix("#") else { return nil }
        let name = text[..<eq].trimmingCharacters(in: .whitespaces)
        let value = text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, value)
    }

    /// A line without its trailing comment (a `#` outside quotes) and its outer spaces.
    static func stripped(_ line: String) -> String {
        var out = ""; var quote: Character?
        for ch in line {
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "#" { break }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return value }
        let raw = String(value.dropFirst().dropLast())
        return first == "\"" ? raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") : raw
    }

    /// A TOML basic string.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
