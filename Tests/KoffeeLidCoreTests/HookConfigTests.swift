import XCTest
import KoffeeLidCore

final class HookConfigTests: XCTestCase {
    let cmd = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook claude"
    let codexCmd = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook codex"
    /// The form the hook was installed in before it had to name its agent: still ours to recognise and remove,
    /// never counted as set up.
    let bareCmd = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook"
    /// Shaped like a real settings.json with a stranger's hook that must survive untouched.
    var fixture: [String: Any] {
        ["model": "claude-fable-5-1",
         "hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff", "timeout": 10]]]]]]
    }
    func commands(_ root: [String: Any], _ event: String) -> [String] {
        let groups = (root["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        return groups.flatMap { g -> [String] in
            ((g as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    func testInstallAddsAllFifteenEventsAndKeepsForeignHooks() {
        let out = HookConfig.claude.install(into: fixture, command: cmd)
        XCTAssertEqual(HookConfig.claude.events.count, 15)
        XCTAssertEqual(HookConfig.claude.installedCount(in: out, command: cmd), 15)
        for event in HookConfig.claude.events { XCTAssertEqual(HookConfig.claude.installedCommand(in: out, event: event), cmd, event) }
        XCTAssertTrue(commands(out, "Stop").contains { $0.contains("Glass.aiff") })
        XCTAssertEqual(out["model"] as? String, "claude-fable-5-1")
    }
    func testInstalledEntryHasThePrescribedShape() {
        let out = HookConfig.claude.install(into: [:], command: cmd)
        let groups = (out["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["matcher"] as? String, "*")
        let item = (groups[0]["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["type"] as? String, "command"); XCTAssertEqual(item?["command"] as? String, cmd); XCTAssertEqual(item?["timeout"] as? Int, 5)
    }
    func testInstallIsIdempotentAndReplacesAnOlderPath() {
        let old = HookConfig.claude.install(into: fixture, command: "/old/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook claude")
        let out = HookConfig.claude.install(into: HookConfig.claude.install(into: old, command: cmd), command: cmd)
        XCTAssertEqual(commands(out, "Stop").filter { $0.contains("KoffeeLidHook") }, [cmd])
        XCTAssertEqual(HookConfig.claude.installedCount(in: out, command: cmd), 15)
    }
    func testABareEntryFromBeforeTheAgentWasNamedIsOursButNotSetUp() {
        // `KoffeeLidHook hook` with no agent writes nothing now: an entry of that form is recognised (so Health
        // says the hooks are there and wrong, and Set up replaces it) and never counted as set up.
        let old = HookConfig.claude.install(into: fixture, command: bareCmd)
        XCTAssertEqual(HookConfig.claude.installedCommand(in: old, event: "Stop"), bareCmd, "found: something of ours is there")
        XCTAssertEqual(HookConfig.claude.installedCount(in: old, command: cmd), 0, "not one event is set up")
        XCTAssertTrue(HookConfig.claude.isOurs(bareCmd)); XCTAssertTrue(HookConfig.claude.isOurs(cmd))
        XCTAssertFalse(HookConfig.claude.isOurs(codexCmd), "Codex's entry is the other spec's")
        XCTAssertFalse(HookConfig.codex.isOurs(bareCmd)); XCTAssertFalse(HookConfig.codex.isOurs(cmd))
        let out = HookConfig.claude.install(into: old, command: cmd)
        XCTAssertEqual(commands(out, "Stop").filter { $0.contains("KoffeeLidHook") }, [cmd], "Set up replaces the bare entry")
        XCTAssertEqual(commands(HookConfig.claude.uninstall(from: old), "Stop"), ["afplay /System/Library/Sounds/Glass.aiff"], "Remove takes it")
    }
    func testAReinstallKeepsOurGroupInItsPlace() {
        // Ours first, then a group the user added after it: a re-install replaces ours where it sits, so the
        // later group keeps its index (Codex names a hook's trust after it) and nothing of the user's moves.
        for (config, command, older) in [(HookConfig.codex, codexCmd, "/old/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook codex"),
                                         (HookConfig.claude, cmd, bareCmd)] {
            var root = config.install(into: [:], command: older)
            var hooks = root["hooks"] as! [String: Any]
            var stop = hooks["Stop"] as! [Any]
            stop.append(["hooks": [["type": "command", "command": "say done"]]])
            hooks["Stop"] = stop; root["hooks"] = hooks
            let out = config.install(into: root, command: command)
            XCTAssertEqual(commands(out, "Stop"), [command, "say done"], "\(config.agent): ours replaced at 0, theirs still at 1")
            XCTAssertEqual(config.installedGroupIndex(in: out, event: "Stop", command: command), 0)
            XCTAssertEqual(config.installedCount(in: out, command: command), config.events.count)
            let again = config.install(into: out, command: command)
            XCTAssertEqual(commands(again, "Stop"), [command, "say done"], "\(config.agent): and again")
        }
        // A group of ours found twice (an older layout) keeps the first and drops the rest.
        var root = HookConfig.codex.install(into: [:], command: codexCmd)
        var hooks = root["hooks"] as! [String: Any]
        hooks["Stop"] = (hooks["Stop"] as! [Any]) + [["hooks": [["type": "command", "command": "say done"]]], HookConfig.codex.entry(for: "Stop", command: codexCmd)]
        root["hooks"] = hooks
        XCTAssertEqual(commands(HookConfig.codex.install(into: root, command: codexCmd), "Stop"), [codexCmd, "say done"])
    }
    func testUninstallRemovesExactlyOurs() {
        let out = HookConfig.claude.uninstall(from: HookConfig.claude.install(into: fixture, command: cmd))
        XCTAssertEqual(HookConfig.claude.installedCount(in: out, command: cmd), 0)
        XCTAssertEqual(commands(out, "Stop"), ["afplay /System/Library/Sounds/Glass.aiff"])
        XCTAssertNil((out["hooks"] as? [String: Any])?["PreToolUse"], "an event left empty is dropped")
        XCTAssertEqual((HookConfig.claude.uninstall(from: ["model": "x"])["model"]) as? String, "x")
    }
    func testDeclinesShapesItDoesNotUnderstand() {
        let weird: [String: Any] = ["hooks": ["Stop": "not-an-array", "PreToolUse": [["hooks": [["type": "command", "command": "x"]]]]]]
        let out = HookConfig.claude.install(into: weird, command: cmd)
        XCTAssertEqual((out["hooks"] as? [String: Any])?["Stop"] as? String, "not-an-array")
        XCTAssertEqual(HookConfig.claude.installedCount(in: out, command: cmd), 14)
        let hooksNotObject: [String: Any] = ["hooks": "nope"]
        XCTAssertEqual(HookConfig.claude.install(into: hooksNotObject, command: cmd)["hooks"] as? String, "nope")
    }
    func testSettingsFileRoundTripBackupAndRefusals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("koffeelid-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json"), backup = dir.appendingPathComponent("settings.json.backup-koffeelid")
        XCTAssertNil(try HookSettingsFile.load(at: file), "absent file is nil, not an error")
        try HookSettingsFile.write(["a": 1], to: file)
        XCTAssertEqual(try HookSettingsFile.load(at: file)?["a"] as? Int, 1)
        try HookSettingsFile.backup(from: file, to: backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        try Data("{ not json".utf8).write(to: file)
        XCTAssertThrowsError(try HookSettingsFile.load(at: file)) { XCTAssertTrue("\($0)".contains("not valid JSON"), "\($0)") }
    }

    // MARK: Codex

    /// A real hooks.json of Codex's: a description at the root and a stranger's hook.
    var codexFixture: [String: Any] {
        ["description": "mine",
         "hooks": ["Stop": [["matcher": "*", "hooks": [["type": "command", "command": "say done"]]]]]]
    }

    func testCodexInstallsItsTwelveEventsAfterForeignGroupsAndKeepsTheDescription() {
        let out = HookConfig.codex.install(into: codexFixture, command: codexCmd)
        XCTAssertEqual(HookConfig.codex.events.count, 12)
        XCTAssertEqual(HookConfig.codex.installedCount(in: out, command: codexCmd), 12)
        XCTAssertEqual(commands(out, "Stop"), ["say done", codexCmd], "ours goes last, so the stranger's trust key keeps its index")
        XCTAssertEqual(HookConfig.codex.installedGroupIndex(in: out, event: "Stop", command: codexCmd), 1)
        XCTAssertEqual(HookConfig.codex.installedGroupIndex(in: out, event: "PreToolUse", command: codexCmd), 0)
        XCTAssertNil(HookConfig.codex.installedGroupIndex(in: out, event: "Notification", command: codexCmd))
        XCTAssertEqual(out["description"] as? String, "mine")
        XCTAssertFalse(HookConfig.codex.events.contains("Notification")); XCTAssertTrue(HookConfig.codex.events.contains("Interrupt"))
    }
    func testACodexEntryHasNoMatcherAndTheShortTimeoutsCodexCaps() {
        let out = HookConfig.codex.install(into: [:], command: codexCmd)
        for event in HookConfig.codex.events {
            let groups = (out["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
            XCTAssertEqual(groups.count, 1, event)
            XCTAssertNil(groups[0]["matcher"], event)
            let item = (groups[0]["hooks"] as? [[String: Any]])?.first
            XCTAssertEqual(item?["command"] as? String, codexCmd, event)
            XCTAssertEqual(item?["timeout"] as? Int, event == "SessionEnd" || event == "Interrupt" ? 3 : 5, event)
            XCTAssertEqual(HookConfig.codex.timeoutSeconds(for: event), item?["timeout"] as? Int, event)
        }
    }
    func testCodexUninstallLeavesTheStrangersHook() {
        let out = HookConfig.codex.uninstall(from: HookConfig.codex.install(into: codexFixture, command: codexCmd))
        XCTAssertEqual(HookConfig.codex.installedCount(in: out, command: codexCmd), 0)
        XCTAssertEqual(commands(out, "Stop"), ["say done"])
        XCTAssertNil((out["hooks"] as? [String: Any])?["Interrupt"])
    }
    func testTheTwoSpecsDoNotSeeEachOthersEntries() {
        let both = HookConfig.codex.install(into: HookConfig.claude.install(into: [:], command: cmd), command: codexCmd)
        XCTAssertEqual(HookConfig.codex.installedCount(in: both, command: codexCmd), 12)
        XCTAssertEqual(HookConfig.claude.installedCount(in: both, command: cmd), 15)
        XCTAssertEqual(HookConfig.of(.claude)?.marker, HookConfig.claude.marker); XCTAssertEqual(HookConfig.of(.codex)?.agent, .codex)
        XCTAssertNil(HookConfig.of(.copilot), "Copilot's hook file is not a `hooks` object of this shape")
        XCTAssertNil(HookConfig.of(.opencode), "OpenCode takes a plugin, not hooks")
    }
}
