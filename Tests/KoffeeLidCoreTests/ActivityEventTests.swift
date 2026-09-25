import XCTest
import KoffeeLidCore

final class ActivityEventTests: XCTestCase {
    func testRoundTripsEveryFieldWithSnakeCaseKeys() throws {
        var e = ActivityEvent(loggedAt: Date(timeIntervalSince1970: 1_700_000_000.25), event: .preToolUse)
        e.sessionId = "s1"; e.agentId = "a1"; e.toolName = "Bash"; e.notificationType = "idle_prompt"
        e.source = "startup"; e.backgroundTaskIds = ["b1"]; e.agentPid = 42; e.rawPrefix = "x"
        e.jobId = "zsh-7"; e.jobPid = 7; e.jobLabel = "make"; e.jobArmAfterSeconds = 5
        let data = try ActivityCodec.encodeLine(e)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"session_id\":\"s1\""), text)
        XCTAssertTrue(text.contains("\"agent_pid\":42"), text)
        XCTAssertFalse(text.contains("agent\":"), "no agent written when none was set")
        var codex = e; codex.agent = .codex
        let codexText = String(decoding: try ActivityCodec.encodeLine(codex), as: UTF8.self)
        XCTAssertTrue(codexText.contains("\"agent\":\"codex\""), codexText)
        XCTAssertEqual(ActivityCodec.decodeLine(Data(codexText.utf8)), codex)
        XCTAssertEqual(e.effectiveAgent, .claude); XCTAssertEqual(codex.effectiveAgent, .codex)
        XCTAssertTrue(text.contains("\"logged_at\":\"2023-11-14T22:13:20.250Z\""), text)
        XCTAssertFalse(text.contains("\n"), "one line, no newline inside")
        XCTAssertEqual(ActivityCodec.decodeLine(data), e)
    }
    func testTheTurnIdRoundTripsUnderTurnId() throws {
        var e = ActivityEvent(loggedAt: Date(timeIntervalSince1970: 1_700_000_000), event: .postToolUse)
        e.sessionId = "c1"; e.agent = .codex; e.turnId = "t1"
        let text = String(decoding: try ActivityCodec.encodeLine(e), as: UTF8.self)
        XCTAssertTrue(text.contains("\"turn_id\":\"t1\""), text)
        XCTAssertEqual(ActivityCodec.decodeLine(Data(text.utf8)), e)
        XCTAssertNil(ActivityCodec.decodeLine(Data("{\"event\":\"Stop\",\"logged_at\":\"2023-11-14T22:13:20Z\"}".utf8))?.turnId, "a line without the key has no turn")
    }
    func testALineFromBeforeCodexStillCarriesItsPid() {
        let e = ActivityCodec.decodeLine(Data("{\"event\":\"Stop\",\"logged_at\":\"2023-11-14T22:13:20Z\",\"claude_pid\":42,\"session_id\":\"s\"}".utf8))
        XCTAssertEqual(e?.agentPid, 42); XCTAssertNil(e?.agent); XCTAssertEqual(e?.effectiveAgent, .claude)
    }
    func testUnknownEventNameFailsToDecodeInsteadOfCrashing() {
        XCTAssertNil(ActivityCodec.decodeLine(Data("{\"event\":\"Whatever\",\"logged_at\":\"2023-11-14T22:13:20Z\"}".utf8)))
    }
    func testDecodesDatesWithoutFractionalSeconds() {
        let e = ActivityCodec.decodeLine(Data("{\"event\":\"Stop\",\"logged_at\":\"2023-11-14T22:13:20Z\"}".utf8))
        XCTAssertEqual(e?.event, .stop)
        XCTAssertEqual(e?.loggedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
    func testJournalWriterAppendsOneLinePerCallAndReadAllDecodesThem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("koffeelid-journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = ActivityEvent(loggedAt: Date(timeIntervalSince1970: 1), event: .stop)
        let b = ActivityEvent(loggedAt: Date(timeIntervalSince1970: 2), event: .jobBegin)
        XCTAssertTrue(ActivityJournalWriter.append(try ActivityCodec.encodeLine(a), to: url))
        XCTAssertTrue(ActivityJournalWriter.append(try ActivityCodec.encodeLine(b), to: url))
        XCTAssertEqual(ActivityJournalWriter.readAll(url: url), [a, b])
        XCTAssertEqual(ActivityJournalWriter.readAll(url: url.appendingPathExtension("missing")), [])
    }
    func testConstantsKeepTheirCalibratedValues() {
        XCTAssertEqual(ActivityConstants.agentStaleSeconds, 240)
        XCTAssertEqual(ActivityConstants.holdGraceSeconds, 90)
        XCTAssertEqual(ActivityConstants.holdTTLSeconds, 1800)
        XCTAssertEqual(ActivityConstants.staleSeconds, 7200)
        XCTAssertEqual(ActivityConstants.idleSignalMinQuietSeconds, 50)
        XCTAssertEqual(ActivityConstants.abandonQuietSeconds, 20)
        XCTAssertEqual(ActivityConstants.abandonRecheckSeconds, 15)
        XCTAssertEqual(ActivityConstants.abortQuarantineSeconds, 120)
        XCTAssertEqual(ActivityConstants.jobArmAfterDefaultSeconds, 5)
        XCTAssertEqual(ActivityConstants.holdOffDefaults, [.claude: 1800, .codex: 1800, .terminal: 60]); XCTAssertEqual(ActivityConstants.disarmOnceHoldOffSeconds, 60)
        XCTAssertEqual(ActivityConstants.journalLineMaxBytes, 4096)
    }
}
