import XCTest
import KoffeeLidCore

final class HookConfigTests: XCTestCase {
    let cmd = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook"
    let codexCmd = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook codex"
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
        let old = HookConfig.claude.install(into: fixture, command: "/old/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook")
        let out = HookConfig.claude.install(into: HookConfig.claude.install(into: old, command: cmd), command: cmd)
        XCTAssertEqual(commands(out, "Stop").filter { $0.contains("KoffeeLidHook") }, [cmd])
        XCTAssertEqual(HookConfig.claude.installedCount(in: out, command: cmd), 15)
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
        XCTAssertEqual(HookConfig.of(.claude).marker, HookConfig.claude.marker); XCTAssertEqual(HookConfig.of(.codex).agent, .codex)
    }
}
