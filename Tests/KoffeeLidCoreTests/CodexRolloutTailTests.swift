import XCTest
import KoffeeLidCore

/// Fixtures mirror the shapes of Codex 0.157's rollout lines (`type`, `timestamp`, `payload.type`,
/// `payload.turn_id`); every other field, and all content, is made up or left out.
final class CodexRolloutTailTests: XCTestCase {
    func line(_ type: String, _ payloadType: String? = nil, at time: String, turn: String? = nil, extra: String = "") -> String {
        var payload = payloadType.map { "\"type\":\"\($0)\"" } ?? "\"role\":\"x\""
        if let turn { payload += ",\"turn_id\":\"\(turn)\"" }
        if !extra.isEmpty { payload += "," + extra }
        return "{\"timestamp\":\"\(time)\",\"type\":\"\(type)\",\"ordinal\":1,\"payload\":{\(payload)}}"
    }
    func tail(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    func testATurnAbortedAfterOurLastEventEndsTheTurn() {
        let rollout = tail([
            line("event_msg", "task_started", at: "2026-09-25T18:52:20.100Z", turn: "t1"),
            line("response_item", "custom_tool_call", at: "2026-09-25T18:52:21.000Z"),
            line("response_item", "custom_tool_call_output", at: "2026-09-25T18:52:34.665Z"),
            line("event_msg", "turn_aborted", at: "2026-09-25T18:52:34.702Z", turn: "t1", extra: "\"reason\":\"interrupted\""),
        ])
        XCTAssertEqual(CodexRolloutTail.verdict(tail: rollout), .aborted(at: date("2026-09-25T18:52:34.702Z"), turnId: "t1"))
    }
    func testTheEndMarkerDateIsTheCompleteOrAbortedStamp() {
        let at = date("2026-09-25T19:00:09.250Z")
        XCTAssertEqual(CodexRolloutTail.endMarkerDate(.complete(at: at, turnId: "t1")), at)
        XCTAssertEqual(CodexRolloutTail.endMarkerDate(.aborted(at: at, turnId: "t1")), at, "whatever ended it, its own stamp")
        XCTAssertNil(CodexRolloutTail.endMarkerDate(.running(turnId: "t1")), "still running: no end to date a verdict to")
        XCTAssertNil(CodexRolloutTail.endMarkerDate(.unreadable))
    }
    func testATaskCompleteIsAFinish() {
        let rollout = tail([
            line("event_msg", "task_started", at: "2026-09-25T19:00:00.000Z", turn: "t1"),
            line("event_msg", "token_count", at: "2026-09-25T19:00:05.000Z"),
            line("event_msg", "task_complete", at: "2026-09-25T19:00:09.250Z", turn: "t1"),
            line("event_msg", "token_count", at: "2026-09-25T19:00:09.300Z"),
        ])
        XCTAssertEqual(CodexRolloutTail.verdict(tail: rollout), .complete(at: date("2026-09-25T19:00:09.250Z"), turnId: "t1"))
    }
    func testAStrayItemCompletedAfterTheAbortIsNotATurnMarker() {
        let rollout = tail([
            line("event_msg", "task_started", at: "2026-09-25T18:52:20.100Z", turn: "t1"),
            line("event_msg", "turn_aborted", at: "2026-09-25T18:52:34.702Z", turn: "t1"),
            line("event_msg", "item_completed", at: "2026-09-25T18:52:47.344Z", turn: "t1"),
            line("event_msg", "thread_settings_applied", at: "2026-09-25T18:52:48.000Z"),
        ])
        XCTAssertEqual(CodexRolloutTail.verdict(tail: rollout), .aborted(at: date("2026-09-25T18:52:34.702Z"), turnId: "t1"))
    }
    func testTaskStartedWithoutAnEndIsStillRunning() {
        let rollout = tail([
            line("event_msg", "task_started", at: "2026-09-25T18:00:00.000Z", turn: "t1"),
            line("event_msg", "task_complete", at: "2026-09-25T18:00:30.000Z", turn: "t1"),
            line("event_msg", "task_started", at: "2026-09-25T18:05:00.000Z", turn: "t2"),
            line("response_item", "function_call", at: "2026-09-25T18:05:02.000Z"),
            line("event_msg", "item_completed", at: "2026-09-25T18:05:03.000Z", turn: "t2"),
        ])
        XCTAssertEqual(CodexRolloutTail.verdict(tail: rollout), .running(turnId: "t2"), "the last marker wins")
        XCTAssertEqual(CodexRolloutTail.verdict(tail: tail([line("event_msg", "task_started", at: "2026-09-25T18:05:00.000Z")])),
                       .running(turnId: nil))
    }
    func testAnUnreadableOrTruncatedTailDecidesNothing() {
        XCTAssertEqual(CodexRolloutTail.verdict(tail: Data()), .unreadable)
        XCTAssertEqual(CodexRolloutTail.verdict(tail: Data("not json\n{\"type\":".utf8)), .unreadable)
        XCTAssertEqual(CodexRolloutTail.verdict(tail: Data([0xFF, 0xFE, 0x0A, 0x00])), .unreadable)
        XCTAssertEqual(CodexRolloutTail.verdict(tail: tail([
            line("response_item", "message", at: "2026-09-25T18:00:00.000Z"),
            line("event_msg", "token_count", at: "2026-09-25T18:00:01.000Z"),
        ])), .unreadable, "no turn marker at all")
        XCTAssertEqual(CodexRolloutTail.verdict(tail: tail([
            line("event_msg", "task_complete", at: "yesterday", turn: "t1"),
        ])), .unreadable, "a finish without a readable stamp is not a marker")
        XCTAssertEqual(CodexRolloutTail.verdict(tail: tail([line("response_item", "task_complete", at: "2026-09-25T18:00:00.000Z")])),
                       .unreadable, "a marker's name outside an event_msg line is not a marker")
        // The last line still being written is cut too: the marker before it stands.
        let writing = tail([line("event_msg", "task_started", at: "2026-09-25T18:00:00.000Z", turn: "t1")]) + Data("{\"timestamp\":\"2026-09-25T18:0".utf8)
        XCTAssertEqual(CodexRolloutTail.verdict(tail: writing), .running(turnId: "t1"))
    }
    func testACutFirstLineIsSkipped() {
        let whole = line("event_msg", "task_complete", at: "2026-09-25T18:00:30.000Z", turn: "t1")
        let cut = String(whole.dropFirst(12))
        let rollout = tail([cut, line("event_msg", "task_started", at: "2026-09-25T18:05:00.000Z", turn: "t2")])
        XCTAssertEqual(CodexRolloutTail.verdict(tail: rollout), .running(turnId: "t2"))
        XCTAssertEqual(CodexRolloutTail.verdict(tail: tail([cut, line("event_msg", "token_count", at: "2026-09-25T18:05:00.000Z")])), .unreadable,
                       "the cut line's marker is not read")
        XCTAssertEqual(CodexRolloutTail.tailBytes, 65_536)
    }
    func testARolloutOfAnotherSessionDecidesNothing() {
        let sid = "01a0d9e4-0000-7000-8000-000000000001"
        XCTAssertTrue(CodexRolloutTail.isRollout(path: "/Users/x/.codex/sessions/2026/09/25/rollout-2026-09-25T20-51-00-\(sid).jsonl", ofSession: sid))
        XCTAssertFalse(CodexRolloutTail.isRollout(path: "/Users/x/.codex/sessions/2026/09/25/rollout-2026-09-25T20-51-00-01a0d9e4-0000-7000-8000-000000000002.jsonl", ofSession: sid))
        XCTAssertFalse(CodexRolloutTail.isRollout(path: "/Users/x/.claude/projects/p/\(sid).jsonl", ofSession: sid), "not a rollout file")
        XCTAssertFalse(CodexRolloutTail.isRollout(path: "/Users/x/rollout-\(sid).jsonl.bak", ofSession: sid))
        XCTAssertFalse(CodexRolloutTail.isRollout(path: "/Users/x/rollout-\(sid).jsonl", ofSession: ""))
    }
    func testARecordedPathOutsideCodexsSessionsIsNotRead() {
        let sessions = "/Users/x/.codex/sessions"
        XCTAssertTrue(CodexRolloutTail.isInSessions("/Users/x/.codex/sessions/2026/09/25/rollout-a.jsonl", sessionsDirectory: sessions))
        XCTAssertTrue(CodexRolloutTail.isInSessions("/Users/x/.codex/sessions/2026/09/25/rollout-a.jsonl", sessionsDirectory: sessions + "/"))
        XCTAssertFalse(CodexRolloutTail.isInSessions("/tmp/fifo/rollout-a.jsonl", sessionsDirectory: sessions))
        XCTAssertFalse(CodexRolloutTail.isInSessions("/Users/x/.codex/sessions-old/2026/09/25/rollout-a.jsonl", sessionsDirectory: sessions))
        XCTAssertFalse(CodexRolloutTail.isInSessions("/Users/x/.codex/sessions/2026/../../../../etc/rollout-a.jsonl", sessionsDirectory: sessions), "no way out")
        XCTAssertFalse(CodexRolloutTail.isInSessions("/Users/x/.codex/sessions/./2026/09/rollout-a.jsonl", sessionsDirectory: sessions))
        XCTAssertFalse(CodexRolloutTail.isInSessions("/Users/x/.codex/sessions/rollout-a.jsonl", sessionsDirectory: sessions), "a rollout sits three folders down")
        XCTAssertFalse(CodexRolloutTail.isInSessions("/Users/x/.codex/sessions/2026/09/25/26/rollout-a.jsonl", sessionsDirectory: sessions))
        XCTAssertFalse(CodexRolloutTail.isInSessions("Users/x/.codex/sessions/2026/09/25/rollout-a.jsonl", sessionsDirectory: sessions), "absolute only")
        XCTAssertFalse(CodexRolloutTail.isInSessions("/Users/x/.codex/sessions/2026/09/25/rollout-a.jsonl", sessionsDirectory: ""))
    }

    // MARK: The decision

    let lastEvent = Date(timeIntervalSince1970: 1_790_000_000)
    var checkedAt: Date { lastEvent.addingTimeInterval(30) }
    func decide(_ verdict: CodexRolloutTail.Verdict, lastTurn: String? = "t1", writtenAt: Date? = nil) -> CodexRolloutTail.Decision {
        CodexRolloutTail.decision(verdict: verdict, lastMainEventAt: lastEvent, lastMainTurnId: lastTurn,
                                  writtenAt: writtenAt ?? lastEvent.addingTimeInterval(25), now: checkedAt)
    }
    func testAnEndMarkerAfterOurLastEventEndsTheTurn() {
        XCTAssertEqual(decide(.complete(at: lastEvent.addingTimeInterval(1), turnId: "t9")), .turnOver(reason: "finished", at: lastEvent.addingTimeInterval(1)), "the decision carries the marker's stamp")
        XCTAssertEqual(decide(.aborted(at: lastEvent.addingTimeInterval(0.001), turnId: nil), lastTurn: nil), .turnOver(reason: "aborted", at: lastEvent.addingTimeInterval(0.001)))
    }
    func testAnEndMarkerNamingOurTurnEndsItEvenWhenStampedEarlier() {
        // The Interrupt hook lost: the aborted tool's late PostToolUse, of the same turn, is our last main
        // event, 13 s after the rollout's turn_aborted.
        let marker = lastEvent.addingTimeInterval(-13)
        XCTAssertEqual(decide(.aborted(at: marker, turnId: "t1")), .turnOver(reason: "aborted", at: marker))
        XCTAssertEqual(decide(.complete(at: marker, turnId: "t1")), .turnOver(reason: "finished", at: marker))
        XCTAssertEqual(decide(.aborted(at: lastEvent, turnId: "t1")), .turnOver(reason: "aborted", at: lastEvent), "the same instant, the same turn")
    }
    func testAnEndMarkerOfAnEarlierTurnStampedEarlierDecidesNothing() {
        let earlier = lastEvent.addingTimeInterval(-30)
        XCTAssertEqual(decide(.complete(at: earlier, turnId: "t0")), .nothing, "the previous turn's end, before our prompt")
        XCTAssertEqual(decide(.aborted(at: earlier, turnId: nil)), .nothing, "a marker without an id proves its stamp only")
        XCTAssertEqual(decide(.complete(at: earlier, turnId: "t1"), lastTurn: nil), .nothing, "no turn of ours to name")
        XCTAssertEqual(decide(.complete(at: lastEvent, turnId: "t0")), .nothing, "not after our last event")
    }
    func testARunningMarkerIsBusy() {
        let written = lastEvent.addingTimeInterval(25)
        XCTAssertEqual(decide(.running(turnId: "t1")), .busy(writtenAt: written))
        XCTAssertEqual(decide(.running(turnId: nil), lastTurn: nil), .busy(writtenAt: written))
    }
    func testAFreshlyWrittenRunningRolloutKeepsIt() {
        let justWritten = checkedAt.addingTimeInterval(-1)
        XCTAssertEqual(decide(.running(turnId: "t1"), writtenAt: justWritten), .busy(writtenAt: justWritten))
        let almostStale = checkedAt.addingTimeInterval(1 - ActivityConstants.staleSeconds)
        XCTAssertEqual(decide(.running(turnId: "t1"), writtenAt: almostStale), .busy(writtenAt: almostStale), "written within 2 h")
        XCTAssertEqual(CodexRolloutTail.decision(verdict: .running(turnId: "t1"), lastMainEventAt: lastEvent, lastMainTurnId: "t1", writtenAt: nil, now: checkedAt),
                       .busy(writtenAt: nil), "a file whose date could not be read is taken at its word")
    }
    func testARolloutSilentForTwoHoursNoLongerKeepsTheSessionAlive() {
        let stale = checkedAt.addingTimeInterval(-ActivityConstants.staleSeconds)
        XCTAssertEqual(decide(.running(turnId: "t1"), writtenAt: stale), .nothing, "Codex stopped writing 2 h ago: staleness decides")
        XCTAssertEqual(decide(.running(turnId: "t1"), writtenAt: stale.addingTimeInterval(-3600)), .nothing)
        let marker = lastEvent.addingTimeInterval(1)
        XCTAssertEqual(decide(.complete(at: marker, turnId: "t1"), writtenAt: stale), .turnOver(reason: "finished", at: marker), "the date never keeps an end from ending the turn")
    }
    func testAnUnreadableTailDecidesNothing() {
        XCTAssertEqual(decide(.unreadable), .nothing)
        XCTAssertEqual(decide(CodexRolloutTail.verdict(tail: Data("garbage".utf8))), .nothing)
    }
}
