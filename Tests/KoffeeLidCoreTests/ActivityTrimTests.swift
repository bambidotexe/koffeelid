import XCTest
import KoffeeLidCore

final class ActivityTrimTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func payload(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    func testKeepsMetadataDropsBodies() {
        let e = ActivityTrim.event(fromHookPayload: payload([
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_input": ["command": String(repeating: "x", count: 100_000)],
            "prompt": "secret", "last_assistant_message": "secret", "agent_id": "a1", "source": "startup",
            "notification_type": "idle_prompt",
        ]), loggedAt: now)
        XCTAssertEqual(e.event, .preToolUse); XCTAssertEqual(e.sessionId, "s1"); XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.agentId, "a1"); XCTAssertEqual(e.source, "startup"); XCTAssertEqual(e.notificationType, "idle_prompt")
        let text = String(decoding: try! ActivityCodec.encodeLine(e), as: UTF8.self)
        XCTAssertFalse(text.contains("secret")); XCTAssertLessThan(text.utf8.count, 400)
    }
    func testClampsMetadataTo200Chars() {
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": String(repeating: "s", count: 500)]), loggedAt: now)
        XCTAssertEqual(e.sessionId?.count, 200)
    }
    func testBackgroundTasksKeepOnlyShellOrUntypedIdsCapped() {
        var tasks: [Any] = [["id": "shell-1", "type": "shell"], ["id": "agent-1", "type": "subagent"], ["task_id": "untyped"], "plain-string"]
        tasks += (0..<20).map { ["id": "extra-\($0)-" + String(repeating: "y", count: 60), "type": "shell"] }
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s", "background_tasks": tasks]), loggedAt: now)
        let ids = e.backgroundTaskIds ?? []
        XCTAssertTrue(ids.contains("shell-1")); XCTAssertTrue(ids.contains("untyped")); XCTAssertTrue(ids.contains("plain-string"))
        XCTAssertFalse(ids.contains("agent-1"))
        XCTAssertLessThanOrEqual(ids.count, 16)
        XCTAssertTrue(ids.allSatisfy { $0.count <= 40 })
    }
    func testAbsentBackgroundTasksLeavesNil() {
        XCTAssertNil(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s"]), loggedAt: now).backgroundTaskIds)
    }
    func testGarbageBecomesParseErrorWithPrefix() {
        let e = ActivityTrim.event(fromHookPayload: Data(String(repeating: "junk", count: 200).utf8), loggedAt: now)
        XCTAssertEqual(e.event, .parseError); XCTAssertEqual(e.rawPrefix?.count, 300)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Unknown"]), loggedAt: now).event, .parseError)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "JobBegin"]), loggedAt: now).event, .parseError,
                       "our own line kinds must not be injectable through a hook payload")
    }
    func testCappedLineNeverExceeds4KB() throws {
        var e = ActivityEvent(loggedAt: now, event: .stop)
        e.sessionId = String(repeating: "s", count: 200)
        e.rawPrefix = String(repeating: "r", count: 300)
        e.backgroundTaskIds = (0..<16).map { _ in String(repeating: "b", count: 40) }
        e.jobLabel = String(repeating: "l", count: 60)
        XCTAssertLessThanOrEqual(try ActivityTrim.cappedLine(e).count, ActivityConstants.journalLineMaxBytes)
        // A pathological event still yields a decodable line with event + time + session id.
        var huge = e; huge.jobLabel = String(repeating: "L", count: 10_000)
        let line = try ActivityTrim.cappedLine(huge)
        XCTAssertLessThanOrEqual(line.count, ActivityConstants.journalLineMaxBytes)
        XCTAssertEqual(ActivityCodec.decodeLine(line)?.event, .stop)
    }
    func testLabelIsTrimmedTo60() {
        XCTAssertEqual(ActivityTrim.clampLabel(String(repeating: "a", count: 100)).count, 60)
    }
    func testFiltersBeforeCappingShellAfterSubagents() {
        let tasks: [Any] = (0..<16).map { ["id": "agent-\($0)", "type": "subagent"] } + [["id": "shell-late", "type": "shell"]]
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s", "background_tasks": tasks]), loggedAt: now)
        let ids = e.backgroundTaskIds ?? []
        XCTAssertEqual(ids, ["shell-late"])
    }
    func testCapsAt16AfterFiltering() {
        let tasks: [Any] = (0..<20).map { ["id": "shell-\($0)", "type": "shell"] }
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s", "background_tasks": tasks]), loggedAt: now)
        let ids = e.backgroundTaskIds ?? []
        XCTAssertEqual(ids.count, 16)
        XCTAssertEqual(ids, (0..<16).map { "shell-\($0)" })
    }
}
