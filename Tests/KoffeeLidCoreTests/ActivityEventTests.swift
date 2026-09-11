import XCTest
import KoffeeLidCore

final class ActivityEventTests: XCTestCase {
    func testRoundTripsEveryFieldWithSnakeCaseKeys() throws {
        var e = ActivityEvent(loggedAt: Date(timeIntervalSince1970: 1_700_000_000.25), event: .preToolUse)
        e.sessionId = "s1"; e.agentId = "a1"; e.toolName = "Bash"; e.notificationType = "idle_prompt"
        e.source = "startup"; e.backgroundTaskIds = ["b1"]; e.claudePid = 42; e.rawPrefix = "x"
        e.jobId = "zsh-7"; e.jobPid = 7; e.jobLabel = "make"; e.jobArmAfterSeconds = 5
        let data = try ActivityCodec.encodeLine(e)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"session_id\":\"s1\""), text)
        XCTAssertTrue(text.contains("\"claude_pid\":42"), text)
        XCTAssertTrue(text.contains("\"logged_at\":\"2023-11-14T22:13:20.250Z\""), text)
        XCTAssertFalse(text.contains("\n"), "one line, no newline inside")
        XCTAssertEqual(ActivityCodec.decodeLine(data), e)
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
        XCTAssertEqual(ActivityConstants.jobArmAfterDefaultSeconds, 5)
        XCTAssertEqual(ActivityConstants.holdOffDefaults, [.claude: 1800, .terminal: 60]); XCTAssertEqual(ActivityConstants.disarmOnceHoldOffSeconds, 60)
        XCTAssertEqual(ActivityConstants.journalLineMaxBytes, 4096)
    }
}
