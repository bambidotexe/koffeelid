import XCTest
import KoffeeLidCore

/// OpenCode's events, as KoffeeLid's plugin hands them to `hook opencode`, mapped onto the journal's names. A
/// session with a `parent_id` is a subagent, whose events become helper events of its parent.
final class OpencodeHookTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let parent = "ses_f250e485cffeL98O0E64vYlBAI", child = "ses_f250295d1ffe2LKJIwPvWIX4cW"

    func payload(_ type: String, _ sid: Any? = nil, parent: String? = nil, _ extra: [String: Any] = [:]) -> Data {
        var obj: [String: Any] = ["hook_event_name": type, "session_id": sid ?? self.parent, "event_time": 1_790_380_436_031, "opencode_pid": 86711]
        if let parent { obj["parent_id"] = parent }
        return try! JSONSerialization.data(withJSONObject: obj.merging(extra) { $1 })
    }
    func trim(_ type: String, _ sid: Any? = nil, parent: String? = nil, _ extra: [String: Any] = [:]) -> ActivityEvent? {
        ActivityTrim.opencodeEvent(fromHookPayload: payload(type, sid, parent: parent, extra), loggedAt: now)
    }

    func testTheMappingForATopLevelSession() {
        let table: [(String, [String: Any], ActivityEventName, String?)] = [
            ("session.created", [:], .sessionStart, nil),
            ("session.forked", [:], .sessionStart, nil),
            ("session.inbox.enqueued", ["delivery": "steer"], .userPromptSubmit, nil),
            ("session.execution.started", [:], .userPromptSubmit, nil),
            ("session.tool.called", ["tool_name": "shell", "tool_use_id": "call-1"], .preToolUse, nil),
            ("session.tool.success", ["tool_name": "shell", "tool_use_id": "call-1"], .postToolUse, nil),
            ("session.tool.failed", ["tool_name": "shell", "error_name": "aborted"], .postToolUseFailure, nil),
            ("permission.asked", ["permission": "shell"], .permissionRequest, nil),
            ("permission.replied", ["status": "once"], .postToolUse, nil),
            ("permission.replied", ["status": "always"], .postToolUse, nil),
            ("permission.replied", ["status": "reject"], .permissionDenied, nil),
            ("form.created", ["question": true], .notification, "elicitation_dialog"),
            ("form.replied", [:], .postToolUse, nil),
            ("form.cancelled", [:], .postToolUse, nil),
            ("session.compaction.started", ["reason": "auto"], .preCompact, nil),
            ("session.compaction.ended", ["reason": "auto"], .postCompact, nil),
            ("session.compaction.failed", ["reason": "manual"], .postCompact, nil),
            ("session.execution.succeeded", ["status": "succeeded"], .stop, nil),
            ("session.execution.failed", ["status": "failed", "error_name": "provider_error"], .stopFailure, nil),
            ("session.execution.interrupted", ["status": "interrupted", "reason": "user"], .interrupt, nil),
            ("session.execution.interrupted", ["status": "interrupted", "reason": "shutdown"], .interrupt, nil),
            ("session.deleted", [:], .sessionEnd, nil),
        ]
        for (type, extra, event, notification) in table {
            let e = trim(type, nil, extra)
            XCTAssertEqual(e?.event, event, "\(type) \(extra)")
            XCTAssertEqual(e?.notificationType, notification, type)
            XCTAssertEqual(e?.sessionId, parent, type); XCTAssertNil(e?.agentId, type)
            XCTAssertEqual(e?.agent, .opencode, type); XCTAssertNil(e?.turnId, "OpenCode has no turn id")
            XCTAssertTrue(ActivityEventName.hookEvents(for: .opencode).contains(event), type)
        }
    }
    func testASubagentsEventsAreHelperEventsOfItsParent() {
        let table: [(String, [String: Any], ActivityEventName)] = [
            ("session.created", [:], .subagentStart),
            ("session.forked", [:], .subagentStart),
            ("session.inbox.enqueued", [:], .userPromptSubmit),
            ("session.execution.started", [:], .userPromptSubmit),
            ("session.tool.called", ["tool_name": "read"], .preToolUse),
            ("session.tool.success", [:], .postToolUse),
            ("session.tool.failed", [:], .postToolUseFailure),
            ("permission.asked", ["permission": "edit"], .permissionRequest),
            ("permission.replied", ["status": "once"], .postToolUse),
            ("permission.replied", ["status": "reject"], .postToolUse),
            ("form.created", ["question": true], .permissionRequest),
            ("form.replied", [:], .postToolUse),
            ("form.cancelled", [:], .postToolUse),
            ("session.compaction.started", [:], .preCompact),
            ("session.compaction.ended", [:], .postCompact),
            ("session.compaction.failed", [:], .postCompact),
            ("session.execution.succeeded", [:], .subagentStop),
            ("session.execution.failed", [:], .subagentStop),
            ("session.execution.interrupted", ["reason": "user"], .subagentStop),
            ("session.deleted", [:], .subagentStop),
        ]
        for (type, extra, event) in table {
            let e = trim(type, child, parent: parent, extra)
            XCTAssertEqual(e?.event, event, "\(type) \(extra)")
            XCTAssertEqual(e?.sessionId, parent, "the parent's session: \(type)"); XCTAssertEqual(e?.agentId, child, "the child is the helper: \(type)")
            XCTAssertNil(e?.notificationType, type)
        }
        XCTAssertNil(trim("session.created", child, parent: "")?.agentId, "an empty parent id is no parent")
    }
    func testWhatWritesNothing() {
        for type in ["location.shutdown", "session.renamed", "session.step.started", "session.text.delta", "session.idle",
                     "session.status", "session.tool.input.started", "shell.created", "rpc.whatever", ""] {
            XCTAssertNil(trim(type), type)
        }
        XCTAssertNil(trim("form.created", nil, ["question": false]), "an MCP form is not a question to the user")
        XCTAssertNil(trim("form.created"), "nor is a form that does not say")
        XCTAssertNil(trim("form.created", child, parent: parent, ["question": false]))
        XCTAssertNil(trim("form.replied", "global"), "a form outside any session speaks for none")
        XCTAssertNil(trim("session.execution.succeeded", NSNull()), "an event of no session")
        XCTAssertNil(trim("session.execution.succeeded", ""))
    }
    func testAnUnparseableBodyIsAParseError() {
        for body in [String(repeating: "junk", count: 200), "[1]", #"{"session_id":"ses_1"}"#, ""] {
            let e = ActivityTrim.opencodeEvent(fromHookPayload: Data(body.utf8), loggedAt: now)
            XCTAssertEqual(e?.event, .parseError, body); XCTAssertEqual(e?.agent, .opencode)
            XCTAssertLessThanOrEqual(e?.rawPrefix?.count ?? .max, ActivityConstants.rawPrefixMaxChars)
        }
    }
    func testTheToolNameThePermissionAndTheClamps() {
        XCTAssertEqual(trim("session.tool.called", nil, ["tool_name": "subagent"])?.toolName, "subagent")
        XCTAssertEqual(trim("permission.asked", nil, ["permission": "external_directory"])?.toolName, "external_directory",
                       "a permission's action stands for its tool")
        XCTAssertNil(trim("permission.replied", nil, ["status": "once", "permission": "shell"])?.toolName)
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(trim("session.tool.called", nil, ["tool_name": long])?.toolName?.count, 200)
        XCTAssertEqual(trim("session.tool.called", "ses_" + long)?.sessionId?.count, 200)
        XCTAssertEqual(trim("session.tool.called", child, parent: "ses_" + long)?.sessionId?.count, 200)
    }
    func testTheServersPidIsKeptAsTheClaimTheHookChecks() {
        XCTAssertEqual(trim("session.created")?.agentPid, 86711)
        XCTAssertNil(trim("session.created", nil, ["opencode_pid": "86711"])?.agentPid, "not a number")
        XCTAssertNil(trim("session.created", nil, ["opencode_pid": 3_000_000_000])?.agentPid, "not a pid")
        XCTAssertNil(trim("session.created", nil, ["opencode_pid": -4])?.agentPid)
        let noPid = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "session.created", "session_id": parent])
        XCTAssertNil(ActivityTrim.opencodeEvent(fromHookPayload: noPid, loggedAt: now)?.agentPid)
    }
    func testNoPathAndNoTextReachesTheJournal() throws {
        let e = try XCTUnwrap(trim("session.created", nil, ["directory": "/Users/x/Projects/secret-project", "title": "secret title"]))
        let text = String(decoding: try ActivityCodec.encodeLine(e), as: UTF8.self)
        XCTAssertFalse(text.contains("secret"), text); XCTAssertNil(e.transcriptPath)
    }
}
