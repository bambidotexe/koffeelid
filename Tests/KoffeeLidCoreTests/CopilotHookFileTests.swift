import XCTest
import KoffeeLidCore

/// `~/.copilot/hooks/koffeelid.json`: the whole file KoffeeLid writes, camelCase keys, `exec` (no shell),
/// the event riding in `args` since a camelCase payload carries none.
final class CopilotHookFileTests: XCTestCase {
    let hookPath = "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook"

    func testRootHasAllSevenEventsInOrderWithThePrescribedShape() {
        let root = CopilotHookFile.root(hookPath: hookPath)
        XCTAssertEqual(root["version"] as? Int, 1)
        let hooks = root["hooks"] as? [String: Any]
        XCTAssertEqual(hooks?.count, 7)
        XCTAssertEqual(CopilotHookFile.events, ["sessionStart", "userPromptSubmitted", "postToolUse", "postToolUseFailure", "notification", "agentStop", "sessionEnd"])
        for event in CopilotHookFile.events {
            let entries = hooks?[event] as? [[String: Any]]
            XCTAssertEqual(entries?.count, 1, event)
            let entry = entries?.first
            XCTAssertEqual(entry?["type"] as? String, "command", event)
            XCTAssertEqual(entry?["exec"] as? String, hookPath, event)
            XCTAssertEqual(entry?["args"] as? [String], ["hook", "copilot", event], event)
            XCTAssertEqual(entry?["timeoutSec"] as? Int, 5, event)
        }
    }
    func testInstalledCountIsSevenForOurRootAndZeroForAnUnrelatedOne() {
        let root = CopilotHookFile.root(hookPath: hookPath)
        XCTAssertEqual(CopilotHookFile.installedCount(in: root, hookPath: hookPath), 7)
        XCTAssertEqual(CopilotHookFile.installedCount(in: [:], hookPath: hookPath), 0)
        let stranger: [String: Any] = ["version": 1, "hooks": ["agentStop": [["type": "command", "exec": "/usr/bin/true", "args": ["hook", "copilot", "agentStop"], "timeoutSec": 5]]]]
        XCTAssertEqual(CopilotHookFile.installedCount(in: stranger, hookPath: hookPath), 0)
    }
    func testInstalledCountIsCurrentNotJustOurs() {
        // An entry from an older or moved bundle is "ours" but not "current": it does not count as installed
        // at this bundle's path, so a stale set-up shows as needing a fresh install rather than as done.
        let old = CopilotHookFile.root(hookPath: "/old/KoffeeLid.app/Contents/MacOS/KoffeeLidHook")
        XCTAssertEqual(CopilotHookFile.installedCount(in: old, hookPath: hookPath), 0)
        XCTAssertTrue(CopilotHookFile.isOurs(old))
    }
    func testIsOursRecognisesOnlyOurShapeWhateverTheBundlePath() {
        XCTAssertTrue(CopilotHookFile.isOurs(CopilotHookFile.root(hookPath: hookPath)))
        XCTAssertTrue(CopilotHookFile.isOurs(CopilotHookFile.root(hookPath: "/Volumes/x/KoffeeLid.app/Contents/MacOS/KoffeeLidHook")))
        XCTAssertTrue(CopilotHookFile.isOurs([:]), "an empty object holds nothing that is not ours")
        XCTAssertTrue(CopilotHookFile.isOurs(["version": 1, "hooks": [:]]))
        XCTAssertFalse(CopilotHookFile.isOurs(["hooks": "not-an-object"]))
        XCTAssertFalse(CopilotHookFile.isOurs(["notHooks": true]), "no hooks key at all")
        let strangerShell: [String: Any] = ["hooks": ["agentStop": [["type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"]]]]
        XCTAssertFalse(CopilotHookFile.isOurs(strangerShell), "a stranger's own hook, not ours")
        let mixed: [String: Any] = ["hooks": ["agentStop": [
            ["type": "command", "exec": hookPath, "args": ["hook", "copilot", "agentStop"], "timeoutSec": 5],
            ["type": "command", "command": "say done"],
        ]]]
        XCTAssertFalse(CopilotHookFile.isOurs(mixed), "one foreign entry is enough to refuse the whole file")
        let wrongArgs: [String: Any] = ["hooks": ["agentStop": [["type": "command", "exec": hookPath, "args": ["hook", "codex"]]]]]
        XCTAssertFalse(CopilotHookFile.isOurs(wrongArgs), "args must start [\"hook\",\"copilot\"]")
        let notExec: [String: Any] = ["hooks": ["agentStop": [["type": "command", "exec": "/usr/bin/env", "args": ["hook", "copilot", "agentStop"]]]]]
        XCTAssertFalse(CopilotHookFile.isOurs(notExec), "exec must end in our binary's path")
        let nonObjectElement: [String: Any] = ["hooks": ["agentStop": ["x"]]]
        XCTAssertFalse(CopilotHookFile.isOurs(nonObjectElement), "an element that is not one of our entries is not skipped over")
    }
    func testDisabledIsTrueWhenEitherFileSaysSo() {
        XCTAssertFalse(CopilotHookFile.disabled(settingsText: "", configText: ""), "absent files")
        XCTAssertFalse(CopilotHookFile.disabled(settingsText: "{}", configText: "{}"))
        XCTAssertTrue(CopilotHookFile.disabled(settingsText: #"{"disableAllHooks": true}"#, configText: ""))
        XCTAssertTrue(CopilotHookFile.disabled(settingsText: "", configText: #"{"disableAllHooks": true}"#))
        XCTAssertFalse(CopilotHookFile.disabled(settingsText: #"{"disableAllHooks": false}"#, configText: ""))
    }
    func testDisabledStripsWholeLineCommentsInConfigJson() {
        let config = """
        // User settings belong in settings.json.
        // This file is managed automatically.
        {
          "disableAllHooks": true
        }
        """
        XCTAssertTrue(CopilotHookFile.disabled(settingsText: "", configText: config))
        let notDisabled = """
        // a comment
        {"disableAllHooks": false, "other": "// not a comment inside a string"}
        """
        XCTAssertFalse(CopilotHookFile.disabled(settingsText: "", configText: notDisabled))
    }
    func testDisabledIgnoresUnparseableText() {
        XCTAssertFalse(CopilotHookFile.disabled(settingsText: "{ not json", configText: ""))
    }
}
