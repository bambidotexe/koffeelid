import XCTest
import KoffeeLidCore

/// Codex's trust of a hook, reproduced: the key of its state table, the hash the table must carry, and the
/// edit of `~/.codex/config.toml` that records it. The hashes are pinned to what Codex 0.157.0 itself
/// reported over `hooks/list` for a hook of this shape, so a drift in the reproduction fails here, not
/// silently on a Mac where the hooks never run.
final class CodexHookTrustTests: XCTestCase {
    /// The command Codex was asked about, and the answers it gave.
    let probe = "/private/tmp/claude-501/-Users-Rubens-Projects-koffeelid/06d6e8d6-fd59-4a31-b855-8094a2a2b94e/scratchpad/testhook.sh"
    let codexAnswers: [(event: String, timeout: Int, hash: String)] = [
        ("PreToolUse", 5, "sha256:2c30a06cc37f32528fecde123d8223cd874d7ab50fe8c2cfbdbc82831a9c316a"),
        ("PermissionRequest", 5, "sha256:9381549f316e016c53bc5ceae6c8323740f42a9662e13b853398a44a9ebd5780"),
        ("SessionStart", 5, "sha256:65211240189033d000225b26d67f09317f629852f60c6844fa5e1227918a8e66"),
        ("SessionEnd", 3, "sha256:b86e88d865e45ee4373b287ed300748b51a5a59380a77db1dd610d5669a5e14c"),
        ("Stop", 5, "sha256:2644a7e90e43da4c54a88e8616b6455a690df2cda9a94aaee26f9940403c2a90"),
        ("Interrupt", 3, "sha256:cebc4f4e0b6fbbdeb2eda506c8b22d15767d3b254967b869c3e19adfc36c543e"),
    ]
    let cmd = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook codex"
    let file = "/Users/me/.codex/hooks.json"

    func testSHA256MatchesTheStandardVectors() {
        XCTAssertEqual(SHA256.hex(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex(of: Data(repeating: 0x61, count: 1_000_000)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testTheHashIsWhatCodexComputes() {
        for answer in codexAnswers {
            XCTAssertEqual(CodexHookTrust.hash(event: answer.event, command: probe, timeout: answer.timeout), answer.hash, answer.event)
        }
        XCTAssertEqual(CodexHookTrust.identityJSON(event: "PreToolUse", command: "/x/hook", timeout: 5),
                       #"{"event_name":"pre_tool_use","hooks":[{"async":false,"command":"/x/hook","timeout":5,"type":"command"}]}"#)
    }

    func testTheKeyAndTheLabel() {
        XCTAssertEqual(CodexHookTrust.key(hooksFile: file, event: "PreToolUse", groupIndex: 0), "/Users/me/.codex/hooks.json:pre_tool_use:0:0")
        XCTAssertEqual(CodexHookTrust.key(hooksFile: file, event: "Stop", groupIndex: 2, handlerIndex: 1), "/Users/me/.codex/hooks.json:stop:2:1")
        let labels = HookConfig.codex.events.map(CodexHookTrust.label)
        XCTAssertEqual(labels, ["session_start", "session_end", "user_prompt_submit", "pre_tool_use", "post_tool_use", "permission_request",
                                "stop", "subagent_start", "subagent_stop", "pre_compact", "post_compact", "interrupt"])
    }

    func testAJSONStringEscapesLikeSerde() {
        XCTAssertEqual(CodexHookTrust.json(#"a"b\c/d é"#), #""a\"b\\c/d é""#)
        XCTAssertEqual(CodexHookTrust.json("x\n\t\u{01}"), #""x\n\t\u0001""#)
    }

    func testEntriesFollowOurGroupsIndices() {
        let root = HookConfig.codex.install(into: ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]], command: cmd)
        let entries = CodexHookTrust.entries(hooksFile: file, root: root, config: HookConfig.codex, command: cmd)
        XCTAssertEqual(entries.count, 12)
        XCTAssertEqual(entries.first { $0.key.contains(":stop:") }?.key, "/Users/me/.codex/hooks.json:stop:1:0")
        XCTAssertEqual(entries.first { $0.key.contains(":pre_tool_use:") }?.key, "/Users/me/.codex/hooks.json:pre_tool_use:0:0")
        XCTAssertEqual(entries.first { $0.key.contains(":session_end:") }?.hash, CodexHookTrust.hash(event: "SessionEnd", command: cmd, timeout: 3))
        XCTAssertEqual(CodexHookTrust.hashes(config: HookConfig.codex, command: cmd).count, 12)
        XCTAssertTrue(CodexHookTrust.entries(hooksFile: file, root: [:], config: HookConfig.codex, command: cmd).isEmpty)
    }

    // MARK: config.toml

    /// Our entries in a hooks file where a stranger's Stop group comes first: our Stop key ends in `:1:0`.
    var entries: [CodexHookTrust.Entry] {
        let root = HookConfig.codex.install(into: ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]], command: cmd)
        return CodexHookTrust.entries(hooksFile: file, root: root, config: HookConfig.codex, command: cmd)
    }
    var hashes: Set<String> { CodexHookTrust.hashes(config: HookConfig.codex, command: cmd) }

    func testADottedKeyStateUnderTheHeaderIsRefusedLikeAnInlineOne() {
        // `"<key>".trusted_hash = …` under `[hooks.state]` defines the same table a `[hooks.state."<key>"]`
        // header would: adding ours beside it would define it twice and Codex would refuse the file.
        let key = entries.first!.key
        let ours = "[hooks.state]\n\"\(key)\".trusted_hash = \"sha256:old\"\n"
        XCTAssertNil(CodexHookTrust.trusting(ours, entries: entries, ourHashes: hashes))
        let theirs = "[hooks.state]\n\"/Users/me/.codex/hooks.json:stop:7:0\".trusted_hash = \"sha256:x\"\n"
        XCTAssertNotNil(CodexHookTrust.trusting(theirs, entries: entries, ourHashes: hashes), "another program's dotted state is no reason to refuse")
    }
    /// A real config.toml: a comment, a multi-line string holding a header-looking line, tables, the trust of
    /// the stranger's Stop hook (the first group of that event, so `:stop:0:0`).
    let config = """
    model = "gpt-6"   # the default
    notify = ["/Applications/Thing.app/Contents/MacOS/thing", "turn-ended"]
    instructions = \"\"\"
    [not a table]
    \"\"\"

    [tui]
    screen_reader_detection_done = true

    [hooks.state]

    [hooks.state."/Users/me/.codex/hooks.json:stop:0:0"]
    trusted_hash = "sha256:stranger"

    """

    func testTrustingAppendsCodexsOwnShapeAndReadsItBack() throws {
        let trusted = try XCTUnwrap(CodexHookTrust.trusting("", entries: entries, ourHashes: hashes))
        XCTAssertTrue(trusted.hasPrefix("[hooks.state]\n\n[hooks.state.\"/Users/me/.codex/hooks.json:session_start:0:0\"]\ntrusted_hash = \"sha256:"), trusted)
        XCTAssertEqual(trusted.components(separatedBy: "[hooks.state.\"").count - 1, 12)
        XCTAssertTrue(CodexHookTrust.allTrusted(trusted, entries: entries))
        XCTAssertEqual(CodexHookTrust.states(in: trusted).count, 12)
        XCTAssertEqual(CodexHookTrust.states(in: trusted)[entries[0].key], CodexHookTrust.State(trustedHash: entries[0].hash, enabled: nil))
    }

    func testTrustingKeepsEverythingElseAndTheStrangersTrust() throws {
        let trusted = try XCTUnwrap(CodexHookTrust.trusting(config, entries: entries, ourHashes: hashes))
        XCTAssertTrue(trusted.hasPrefix(config), "the file is only appended to")
        XCTAssertEqual(trusted.components(separatedBy: "[hooks.state]\n").count - 1, 1, "the header is there once")
        XCTAssertEqual(CodexHookTrust.states(in: trusted)["/Users/me/.codex/hooks.json:stop:0:0"]?.trustedHash, "sha256:stranger")
        XCTAssertTrue(CodexHookTrust.allTrusted(trusted, entries: entries))
        // Again: the same file, not twelve more tables.
        XCTAssertEqual(CodexHookTrust.trusting(trusted, entries: entries, ourHashes: hashes), trusted)
    }

    func testUntrustingRemovesOursAndAnEmptyHeaderButNothingElse() throws {
        let trusted = try XCTUnwrap(CodexHookTrust.trusting(config, entries: entries, ourHashes: hashes))
        let back = try XCTUnwrap(CodexHookTrust.untrusting(trusted, keys: Set(entries.map(\.key)), ourHashes: hashes))
        XCTAssertEqual(back, config, "the stranger's table and the header stay")
        XCTAssertNil(CodexHookTrust.untrusting(config, keys: Set(entries.map(\.key)), ourHashes: hashes), "nothing of ours: nothing to write")

        let alone = try XCTUnwrap(CodexHookTrust.trusting("model = \"gpt-6\"\n", entries: entries, ourHashes: hashes))
        XCTAssertEqual(CodexHookTrust.untrusting(alone, keys: Set(entries.map(\.key)), ourHashes: hashes), "model = \"gpt-6\"\n",
                       "a header left with nothing under it goes too")
    }

    func testATableOfOursUnderAnotherKeyIsRecognisedByItsHash() throws {
        let moved = "[hooks.state.\"/Users/me/.codex/hooks.json:stop:3:0\"]\ntrusted_hash = \"\(entries.first { $0.key.contains(":stop:") }!.hash)\"\n"
        let trusted = try XCTUnwrap(CodexHookTrust.trusting(moved, entries: entries, ourHashes: hashes))
        XCTAssertFalse(trusted.contains(":stop:3:0"), "the stale table is gone")
        XCTAssertEqual(CodexHookTrust.states(in: trusted).count, 12)
    }

    func testADisabledOrModifiedTrustDoesNotCount() throws {
        var trusted = try XCTUnwrap(CodexHookTrust.trusting("", entries: entries, ourHashes: hashes))
        XCTAssertTrue(CodexHookTrust.allTrusted(trusted, entries: entries))
        trusted += "enabled = false\n"                        // the last table, the way the /hooks screen switches one off
        XCTAssertFalse(CodexHookTrust.allTrusted(trusted, entries: entries))
        let modified = trusted.replacingOccurrences(of: entries[0].hash, with: "sha256:other")
        XCTAssertFalse(CodexHookTrust.allTrusted(modified, entries: entries))
        XCTAssertFalse(CodexHookTrust.allTrusted("", entries: entries))
        XCTAssertFalse(CodexHookTrust.allTrusted(trusted, entries: []))
    }

    func testAStateWrittenInlineIsReadAsAbsentAndNeverDuplicated() {
        let inlineUnderHooks = "[hooks]\nstate = { \"/Users/me/.codex/hooks.json:stop:0:0\" = { trusted_hash = \"x\" } }\n"
        XCTAssertNil(CodexHookTrust.trusting(inlineUnderHooks, entries: entries, ourHashes: hashes))
        let inlineUnderState = "[hooks.state]\n\"\(entries[0].key)\" = { trusted_hash = \"x\" }\n"
        XCTAssertNil(CodexHookTrust.trusting(inlineUnderState, entries: entries, ourHashes: hashes))
        XCTAssertTrue(CodexHookTrust.states(in: inlineUnderState).isEmpty)
        let strangerInline = "[hooks.state]\n\"/elsewhere/hooks.json:stop:0:0\" = { trusted_hash = \"x\" }\n"
        XCTAssertNotNil(CodexHookTrust.trusting(strangerInline, entries: entries, ourHashes: hashes), "a stranger's inline state is not in the way")
    }

    func testTheScannerReadsQuotesAndCommentsTheWayTOMLDoes() {
        let toml = """
        [hooks.state.'/Users/me/.codex/hooks.json:stop:0:0']   # literal quotes
        trusted_hash = "sha256:a" # trailing comment
        enabled = true
        [hooks.state."/Users/me/.codex/hooks.json:pre_tool_use:0:0"]
        trusted_hash = 'sha256:b'
        enabled = false
        [[hooks.state."/Users/me/.codex/hooks.json:x:0:0"]]
        trusted_hash = "sha256:c"
        """
        let states = CodexHookTrust.states(in: toml)
        XCTAssertEqual(states["/Users/me/.codex/hooks.json:stop:0:0"], CodexHookTrust.State(trustedHash: "sha256:a", enabled: true))
        XCTAssertEqual(states["/Users/me/.codex/hooks.json:pre_tool_use:0:0"], CodexHookTrust.State(trustedHash: "sha256:b", enabled: false))
        XCTAssertEqual(states.count, 2, "an array of tables is not a state table")
        XCTAssertEqual(CodexHookTrust.stateKey("[hooks.state.\"a\\\"b\"]"), "a\"b")
        XCTAssertNil(CodexHookTrust.stateKey("[hooks.state]")); XCTAssertNil(CodexHookTrust.stateKey("[hooks.state.unquoted]"))
    }
}
