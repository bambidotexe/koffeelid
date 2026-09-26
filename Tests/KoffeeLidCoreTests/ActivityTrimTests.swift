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
        ]), agent: .claude, loggedAt: now)
        XCTAssertEqual(e.event, .preToolUse); XCTAssertEqual(e.sessionId, "s1"); XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.agentId, "a1"); XCTAssertEqual(e.source, "startup"); XCTAssertEqual(e.notificationType, "idle_prompt")
        let text = String(decoding: try! ActivityCodec.encodeLine(e), as: UTF8.self)
        XCTAssertFalse(text.contains("secret")); XCTAssertLessThan(text.utf8.count, 400)
    }
    func testClampsMetadataTo200Chars() {
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": String(repeating: "s", count: 500)]), agent: .claude, loggedAt: now)
        XCTAssertEqual(e.sessionId?.count, 200)
    }
    func testBackgroundTasksKeepOnlyShellOrUntypedIdsCapped() {
        var tasks: [Any] = [["id": "shell-1", "type": "shell"], ["id": "agent-1", "type": "subagent"], ["task_id": "untyped"], "plain-string"]
        tasks += (0..<20).map { ["id": "extra-\($0)-" + String(repeating: "y", count: 60), "type": "shell"] }
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s", "background_tasks": tasks]), agent: .claude, loggedAt: now)
        let ids = e.backgroundTaskIds ?? []
        XCTAssertTrue(ids.contains("shell-1")); XCTAssertTrue(ids.contains("untyped")); XCTAssertTrue(ids.contains("plain-string"))
        XCTAssertFalse(ids.contains("agent-1"))
        XCTAssertLessThanOrEqual(ids.count, 16)
        XCTAssertTrue(ids.allSatisfy { $0.count <= 40 })
    }
    func testAbsentBackgroundTasksLeavesNil() {
        XCTAssertNil(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s"]), agent: .claude, loggedAt: now).backgroundTaskIds)
    }
    func testGarbageBecomesParseErrorWithPrefix() {
        let e = ActivityTrim.event(fromHookPayload: Data(String(repeating: "junk", count: 200).utf8), agent: .claude, loggedAt: now)
        XCTAssertEqual(e.event, .parseError); XCTAssertEqual(e.rawPrefix?.count, 300)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Unknown"]), agent: .claude, loggedAt: now).event, .parseError)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "JobBegin"]), agent: .claude, loggedAt: now).event, .parseError,
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
    func testTheMinimalLineKeepsTheTurnId() throws {
        var e = ActivityEvent(loggedAt: now, event: .postToolUse)
        e.sessionId = String(repeating: "s", count: 5_000)
        e.turnId = String(repeating: "t", count: 5_000)
        e.jobId = "j1"
        let line = try ActivityTrim.cappedLine(e)
        XCTAssertLessThanOrEqual(line.count, ActivityConstants.journalLineMaxBytes)
        let decoded = try XCTUnwrap(ActivityCodec.decodeLine(line))
        XCTAssertEqual(decoded.event, .postToolUse)
        XCTAssertEqual(decoded.sessionId?.count, 64); XCTAssertEqual(decoded.jobId, "j1")
        XCTAssertEqual(decoded.turnId, String(repeating: "t", count: ActivityConstants.metadataMaxChars),
                       "the turn id decides whether the line belongs to a closed turn")
    }
    func testAnAgentOnlyPassesItsOwnEvents() {
        let interrupt = payload(["hook_event_name": "Interrupt", "session_id": "c1", "turn_id": "t1"])
        let codex = ActivityTrim.event(fromHookPayload: interrupt, agent: .codex, loggedAt: now)
        XCTAssertEqual(codex.event, .interrupt); XCTAssertEqual(codex.agent, .codex); XCTAssertEqual(codex.sessionId, "c1")
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: interrupt, agent: .claude, loggedAt: now).event, .parseError, "Claude Code has no Interrupt")
        let notification = payload(["hook_event_name": "Notification", "session_id": "c1", "notification_type": "idle_prompt"])
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: notification, agent: .codex, loggedAt: now).event, .parseError, "Codex has no Notification")
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: notification, agent: .claude, loggedAt: now).event, .notification)
        let stop = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "c1", "stop_hook_active": false, "last_assistant_message": "secret"]), agent: .codex, loggedAt: now)
        XCTAssertEqual(stop.agent, .codex)
        XCTAssertFalse(String(decoding: try! ActivityCodec.encodeLine(stop), as: UTF8.self).contains("secret"))
    }
    func testTheHooksArgumentsSayWhichAgentSpeaks() {
        XCTAssertEqual(HookCall(arguments: ["claude"]), .claude)
        XCTAssertEqual(HookCall(arguments: ["codex"]), .codex)
        XCTAssertEqual(HookCall(arguments: ["copilot", "agentStop"]), .copilot(event: "agentStop"))
        XCTAssertEqual(HookCall(arguments: ["copilot", "preToolUse"]), .copilot(event: "preToolUse"), "the trim, not the arguments, refuses the name")
        XCTAssertEqual(HookCall(arguments: ["opencode"]), .opencode)
        XCTAssertEqual([HookCall.claude, .codex, .copilot(event: "x"), .opencode].map(\.agent), [.claude, .codex, .copilot, .opencode])
        for arguments in [[], ["copilot"], ["copilot", "agentStop", "extra"], ["codex", "extra"], ["opencode", "x"], ["claude", "x"], ["job"], [""]] {
            XCTAssertNil(HookCall(arguments: arguments), "\(arguments): the hook names no agent, writes nothing and still exits 0")
        }
    }
    func testLabelIsTrimmedTo60() {
        XCTAssertEqual(ActivityTrim.clampLabel(String(repeating: "a", count: 100)).count, 60)
    }
    func testFiltersBeforeCappingShellAfterSubagents() {
        let tasks: [Any] = (0..<16).map { ["id": "agent-\($0)", "type": "subagent"] } + [["id": "shell-late", "type": "shell"]]
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s", "background_tasks": tasks]), agent: .claude, loggedAt: now)
        let ids = e.backgroundTaskIds ?? []
        XCTAssertEqual(ids, ["shell-late"])
    }
    func testCapsAt16AfterFiltering() {
        let tasks: [Any] = (0..<20).map { ["id": "shell-\($0)", "type": "shell"] }
        let e = ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "s", "background_tasks": tasks]), agent: .claude, loggedAt: now)
        let ids = e.backgroundTaskIds ?? []
        XCTAssertEqual(ids.count, 16)
        XCTAssertEqual(ids, (0..<16).map { "shell-\($0)" })
    }
    func testTurnIdIsKeptFromTurnIdOrPromptIdAndClamped() {
        func turn(_ extra: [String: Any], _ agent: ActivityAgent = .codex) -> String? {
            ActivityTrim.event(fromHookPayload: payload(["hook_event_name": "PostToolUse", "session_id": "s"].merging(extra) { $1 }), agent: agent, loggedAt: now).turnId
        }
        XCTAssertEqual(turn(["turn_id": "t1"]), "t1", "Codex's turn id")
        XCTAssertEqual(turn(["prompt_id": "p1"], .claude), "p1", "Claude Code's turn id")
        XCTAssertEqual(turn(["turn_id": "t1", "prompt_id": "p1"]), "t1", "turn_id wins")
        XCTAssertNil(turn([:]))
        XCTAssertEqual(turn(["turn_id": String(repeating: "t", count: 300)])?.count, 200)
    }
    func testTheTranscriptPathIsKeptOnTheFourBoundaryEventsOnly() {
        let path = "/Users/x/.codex/sessions/2026/09/25/rollout-2026-09-25T18-00-00-s.jsonl"
        func kept(_ name: String, _ agent: ActivityAgent = .codex, _ value: String = path) -> String? {
            ActivityTrim.event(fromHookPayload: payload(["hook_event_name": name, "session_id": "s", "transcript_path": value]), agent: agent, loggedAt: now).transcriptPath
        }
        for name in ["SessionStart", "UserPromptSubmit", "Stop", "Interrupt"] { XCTAssertEqual(kept(name), path, name) }
        for name in ["SessionStart", "UserPromptSubmit", "Stop"] { XCTAssertEqual(kept(name, .claude), path, "Claude Code's \(name)") }
        XCTAssertNil(kept("PreToolUse")); XCTAssertNil(kept("PostToolUse", .claude)); XCTAssertNil(kept("SessionEnd"))
        XCTAssertEqual(kept("Stop", .codex, String(repeating: "p", count: 2000))?.count, ActivityConstants.pathMaxChars)
        XCTAssertEqual(ActivityConstants.pathMaxChars, 1024)
    }
}
