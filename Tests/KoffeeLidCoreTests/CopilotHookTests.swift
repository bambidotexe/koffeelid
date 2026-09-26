import XCTest
import KoffeeLidCore

/// Copilot CLI's hooks: the event rides in the hook's arguments (`hook copilot <event>`), the payload is
/// camelCase and names none, and a subagent's own lines carry an id that has no session folder. The payloads
/// are the ones Copilot CLI 1.0.88 sent on this Mac (`-p` run and interactive runs), paths shortened.
final class CopilotHookTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sid = "6c7e446d-c310-420c-8142-6a1be33e33ca"
    let root = "/Users/x/.copilot/session-state"
    func trim(_ name: String, _ json: String) -> ActivityEvent {
        ActivityTrim.copilotEvent(fromHookPayload: Data(json.utf8), named: name, loggedAt: now)
    }
    func text(_ e: ActivityEvent) -> String { String(decoding: try! ActivityCodec.encodeLine(e), as: UTF8.self) }

    // MARK: The trim

    func testEachSubscribedEventIsTrimmedFromItsNameAndItsCamelCaseBody() {
        let start = trim("sessionStart", #"{"sessionId":"\#(sid)","timestamp":1790379605505,"cwd":"/Users/x/repo1","source":"new","initialPrompt":"secret prompt"}"#)
        XCTAssertEqual(start.event, .sessionStart); XCTAssertEqual(start.source, "new"); XCTAssertEqual(start.sessionId, sid)
        let prompt = trim("userPromptSubmitted", #"{"sessionId":"\#(sid)","timestamp":1790379605324,"cwd":"/Users/x/repo1","prompt":"secret prompt"}"#)
        XCTAssertEqual(prompt.event, .userPromptSubmit)
        let post = trim("postToolUse", #"{"sessionId":"\#(sid)","timestamp":1790379607574,"cwd":"/Users/x/repo1","toolName":"bash","toolArgs":{"command":"secret command"},"toolResult":{"resultType":"success","textResultForLlm":"secret output"}}"#)
        XCTAssertEqual(post.event, .postToolUse); XCTAssertEqual(post.toolName, "bash")
        let failure = trim("postToolUseFailure", #"{"sessionId":"\#(sid)","timestamp":1,"cwd":"/x","toolName":"edit","toolArgs":{},"toolResult":{"resultType":"failure","textResultForLlm":"secret"}}"#)
        XCTAssertEqual(failure.event, .postToolUseFailure); XCTAssertEqual(failure.toolName, "edit")
        let permission = trim("notification", #"{"sessionId":"\#(sid)","timestamp":1,"cwd":"/x","message":"Run command: secret","title":"Permission needed","hook_event_name":"Notification","notification_type":"permission_prompt"}"#)
        XCTAssertEqual(permission.event, .notification); XCTAssertEqual(permission.notificationType, "permission_prompt")
        let question = trim("notification", #"{"sessionId":"\#(sid)","timestamp":1,"cwd":"/x","message":"secret question","title":"Information requested","hook_event_name":"Notification","notification_type":"elicitation_dialog"}"#)
        XCTAssertEqual(question.notificationType, "elicitation_dialog")
        let stop = trim("agentStop", #"{"sessionId":"\#(sid)","timestamp":1790379608403,"cwd":"/Users/x/repo1","transcriptPath":"\#(root)/\#(sid)/events.jsonl","stopReason":"end_turn","stop_hook_active":false}"#)
        XCTAssertEqual(stop.event, .stop); XCTAssertEqual(stop.transcriptPath, "\(root)/\(sid)/events.jsonl")
        let end = trim("sessionEnd", #"{"sessionId":"\#(sid)","timestamp":1790379608539,"cwd":"/Users/x/repo1","reason":"complete"}"#)
        XCTAssertEqual(end.event, .sessionEnd)
        for e in [start, prompt, post, failure, permission, question, stop, end] {
            XCTAssertEqual(e.agent, .copilot); XCTAssertEqual(e.sessionId, sid); XCTAssertNil(e.turnId, "Copilot's hooks carry no turn id")
            XCTAssertNil(e.agentId); XCTAssertNil(e.agentPid, "the hook finds the pid, not the payload")
            XCTAssertFalse(text(e).contains("secret"), "bodies never reach the journal: \(text(e))")
            XCTAssertFalse(text(e).contains("repo1"), "nor the working directory")
        }
    }
    func testTheSessionIdFallsBackToTheSnakeCaseKey() {
        XCTAssertEqual(trim("agentStop", #"{"session_id":"s2","timestamp":1}"#).sessionId, "s2")
        XCTAssertEqual(trim("agentStop", #"{"sessionId":"s1","session_id":"s2"}"#).sessionId, "s1", "the camelCase key wins")
    }
    func testTheTranscriptPathIsKeptOnTheTurnsBoundariesOnly() {
        let path = "\(root)/\(sid)/events.jsonl"
        for name in ["sessionStart", "userPromptSubmitted", "agentStop"] {
            XCTAssertEqual(trim(name, #"{"sessionId":"s","transcriptPath":"\#(path)"}"#).transcriptPath, path, name)
        }
        for name in ["postToolUse", "notification", "sessionEnd"] {
            XCTAssertNil(trim(name, #"{"sessionId":"s","transcriptPath":"\#(path)"}"#).transcriptPath, name)
        }
        let long = String(repeating: "p", count: 2_000)
        XCTAssertEqual(trim("agentStop", #"{"sessionId":"s","transcriptPath":"\#(long)"}"#).transcriptPath?.count, ActivityConstants.pathMaxChars)
    }
    func testEveryCopiedStringIsClamped() {
        let long = String(repeating: "x", count: 500)
        let e = trim("postToolUse", #"{"sessionId":"\#(long)","toolName":"\#(long)"}"#)
        XCTAssertEqual(e.sessionId?.count, 200); XCTAssertEqual(e.toolName?.count, 200)
        XCTAssertEqual(trim("notification", #"{"sessionId":"s","notification_type":"\#(long)"}"#).notificationType?.count, 200)
        XCTAssertEqual(trim("sessionStart", #"{"sessionId":"s","source":"\#(long)"}"#).source?.count, 200)
    }
    func testAnEventNotSubscribedOrABodyThatIsNoObjectIsAParseError() {
        for name in ["preToolUse", "permissionRequest", "errorOccurred", "subagentStop", "SessionStart", "Stop", ""] {
            let e = trim(name, #"{"sessionId":"s","toolName":"bash"}"#)
            XCTAssertEqual(e.event, .parseError, name); XCTAssertEqual(e.agent, .copilot); XCTAssertNotNil(e.rawPrefix)
            XCTAssertNil(e.sessionId, "a ParseError line names no session")
        }
        let junk = trim("agentStop", String(repeating: "junk", count: 200))
        XCTAssertEqual(junk.event, .parseError); XCTAssertEqual(junk.rawPrefix?.count, ActivityConstants.rawPrefixMaxChars)
        XCTAssertEqual(trim("agentStop", "[1,2]").event, .parseError)
        XCTAssertEqual(trim("agentStop", "").event, .parseError)
    }
    func testTheNamedPayloadReaderTakesNoCopilotOrOpencodePayload() {
        // Their payloads name no journal event: `copilotEvent` and `opencodeEvent` read them.
        let named = Data(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"permission_prompt"}"#.utf8)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: named, agent: .copilot, loggedAt: now).event, .parseError)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: named, agent: .opencode, loggedAt: now).event, .parseError)
        XCTAssertEqual(ActivityTrim.event(fromHookPayload: named, agent: .claude, loggedAt: now).event, .notification)
    }

    // MARK: The session-state folder

    func testTheSessionStateRootFollowsCopilotHome() {
        XCTAssertEqual(CopilotSessionState.root(environment: [:], home: "/Users/x"), "/Users/x/.copilot/session-state")
        XCTAssertEqual(CopilotSessionState.root(environment: ["COPILOT_HOME": ""], home: "/Users/x"), "/Users/x/.copilot/session-state")
        XCTAssertEqual(CopilotSessionState.root(environment: ["COPILOT_HOME": "/Volumes/w/copilot"], home: "/Users/x"), "/Volumes/w/copilot/session-state")
        XCTAssertEqual(CopilotSessionState.root(environment: ["COPILOT_HOME": "/Volumes/w/copilot/"], home: "/Users/x"), "/Volumes/w/copilot/session-state")
        XCTAssertEqual(CopilotSessionState.transcriptPath(root: root, sessionId: sid), "\(root)/\(sid)/events.jsonl")
    }
    func testASubagentsLineIsDroppedBecauseItsIdHasNoFolder() {
        let folders: Set<String> = [root, "\(root)/\(sid)"]
        let exists: (String) -> Bool = { folders.contains($0) }
        XCTAssertTrue(CopilotSessionState.keeps(sessionId: sid, root: root, directoryExists: exists))
        XCTAssertFalse(CopilotSessionState.keeps(sessionId: "819c2c3e-0000-4000-8000-000000000000", root: root, directoryExists: exists),
                       "a subagent's prompt and stop carry the subagent's id")
        XCTAssertTrue(CopilotSessionState.keeps(sessionId: nil, root: root, directoryExists: exists), "a ParseError line is kept")
        for odd in ["", ".", "..", "../\(sid)", "\(sid)/..", "a/b"] {
            XCTAssertFalse(CopilotSessionState.keeps(sessionId: odd, root: root, directoryExists: { _ in true }), "\(odd) names no session folder")
        }
        XCTAssertTrue(CopilotSessionState.keeps(sessionId: "819c2c3e", root: root, directoryExists: { _ in false }),
                      "without the root there is nothing to tell a subagent by: every line is kept")
    }
    func testTheLineGetsItsTranscriptPathBeforeTheFirstStop() {
        let folders: Set<String> = [root, "\(root)/\(sid)"]
        let exists: (String) -> Bool = { folders.contains($0) }
        let path = "\(root)/\(sid)/events.jsonl"
        for name in ["sessionStart", "userPromptSubmitted", "agentStop"] {
            let line = CopilotSessionState.line(trim(name, #"{"sessionId":"\#(sid)"}"#), root: root, directoryExists: exists)
            XCTAssertEqual(line?.transcriptPath, path, name)
        }
        for name in ["postToolUse", "notification", "sessionEnd"] {
            let line = CopilotSessionState.line(trim(name, #"{"sessionId":"\#(sid)"}"#), root: root, directoryExists: exists)
            XCTAssertNotNil(line, name); XCTAssertNil(line?.transcriptPath, name)
        }
        let named = CopilotSessionState.line(trim("agentStop", #"{"sessionId":"\#(sid)","transcriptPath":"/elsewhere/events.jsonl"}"#), root: root, directoryExists: exists)
        XCTAssertEqual(named?.transcriptPath, "/elsewhere/events.jsonl", "the payload's own path stands")
        // A subagent's agentStop names its parent's file under its own id: dropped all the same.
        let subagent = trim("agentStop", #"{"sessionId":"819c2c3e","transcriptPath":"\#(path)"}"#)
        XCTAssertNil(CopilotSessionState.line(subagent, root: root, directoryExists: exists))
        let parseError = trim("preToolUse", #"{"sessionId":"\#(sid)"}"#)
        XCTAssertEqual(CopilotSessionState.line(parseError, root: root, directoryExists: exists), parseError, "a ParseError line is written as it is")
    }
}
