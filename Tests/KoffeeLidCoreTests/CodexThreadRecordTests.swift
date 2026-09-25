import XCTest
import KoffeeLidCore

/// Fixtures mirror the shapes of Codex 0.157's daemon answers (`result.thread.status.type`, `path`,
/// `updatedAt`; `result.data`, `nextCursor`); ids, paths and stamps are made up.
final class CodexThreadRecordTests: XCTestCase {
    let thread = "019a0000-0000-7000-8000-000000000001"
    func answer(status: String, extra: String = "") -> Data {
        Data(#"{"id":2,"result":{"thread":{"id":"019a0000-0000-7000-8000-000000000001","status":{"type":"\#(status)"\#(extra)},"path":"/Users/someone/.codex/sessions/2026/09/25/rollout-2026-09-25T21-20-43-019a0000-0000-7000-8000-000000000001.jsonl","updatedAt":"2026-09-25T19:20:43.962Z","cwd":"/tmp"}}}"#.utf8)
    }

    func testNotLoadedMeansNothingRuns() {
        let record = CodexThreadRecord.parse(answer(status: "notLoaded"), expecting: thread)
        XCTAssertEqual(record?.status, "notLoaded")
        XCTAssertEqual(record?.verdict, .over)
        XCTAssertEqual(CodexThreadRecord.parse(answer(status: "idle"), expecting: thread)?.verdict, .over,
                       "a loaded thread with no turn has nothing running either")
    }

    func testAnActiveThreadIsBusy() {
        let record = CodexThreadRecord.parse(answer(status: "active", extra: #","activeFlags":["waitingOnApproval"]"#), expecting: thread)
        XCTAssertEqual(record?.status, "active")
        XCTAssertEqual(record?.verdict, .busy)
    }

    func testAnUnknownStatusDecidesNothing() {
        XCTAssertEqual(CodexThreadRecord.parse(answer(status: "systemError"), expecting: thread)?.verdict, .undecided)
        XCTAssertEqual(CodexThreadRecord.parse(answer(status: "Active"), expecting: thread)?.verdict, .undecided, "the vocabulary is exact")
        XCTAssertNil(CodexThreadRecord.parse(Data(#"{"id":2,"error":{"code":-32600,"message":"no such thread"}}"#.utf8), expecting: thread), "a refusal is no record")
        XCTAssertNil(CodexThreadRecord.parse(Data(#"{"id":2,"result":{"thread":{"id":"t","status":"idle"}}}"#.utf8), expecting: "t"), "a status of another shape is no record")
        XCTAssertNil(CodexThreadRecord.parse(Data("{\"id\":2,\"result\":{\"thr".utf8), expecting: thread), "a cut answer is no record")
    }

    func testTheRecordCarriesTheRolloutPath() {
        let record = CodexThreadRecord.parse(answer(status: "notLoaded"), expecting: thread)
        XCTAssertEqual(record?.rolloutPath, "/Users/someone/.codex/sessions/2026/09/25/rollout-2026-09-25T21-20-43-019a0000-0000-7000-8000-000000000001.jsonl")
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(record?.updatedAt, f.date(from: "2026-09-25T19:20:43.962Z"))
        let seconds = CodexThreadRecord.parse(Data(#"{"id":2,"result":{"thread":{"id":"t","status":{"type":"idle"},"updatedAt":1790000000}}}"#.utf8), expecting: "t")
        XCTAssertEqual(seconds?.updatedAt, Date(timeIntervalSince1970: 1_790_000_000), "a stamp in Unix seconds reads too")
        XCTAssertNil(seconds?.rolloutPath)
    }

    func testAnAnswerAboutAnotherThreadIsRefused() {
        XCTAssertNil(CodexThreadRecord.parse(answer(status: "notLoaded"), expecting: "019a0000-0000-7000-8000-000000000002"),
                     "a record of another thread says nothing about the one asked about")
        XCTAssertNil(CodexThreadRecord.parse(Data(#"{"id":2,"result":{"thread":{"status":{"type":"notLoaded"}}}}"#.utf8), expecting: thread),
                     "a record that names no thread is refused too")
        XCTAssertNil(CodexThreadRecord.parse(Data(#"{"id":2,"result":{"thread":{"id":7,"status":{"type":"idle"}}}}"#.utf8), expecting: "7"))
        XCTAssertEqual(CodexThreadRecord.parse(answer(status: "notLoaded"), expecting: thread)?.verdict, .over)
    }
    func testTheLoadedListNamesTheThreads() {
        XCTAssertEqual(CodexThreadRecord.loadedThreadIds(Data(#"{"id":2,"result":{"data":[],"nextCursor":null}}"#.utf8)), [])
        XCTAssertEqual(CodexThreadRecord.loadedThreadIds(Data(#"{"id":2,"result":{"data":["a","b"],"nextCursor":null}}"#.utf8)), ["a", "b"])
        XCTAssertEqual(CodexThreadRecord.loadedThreadIds(Data(#"{"id":2,"result":{"data":[{"id":"a"},{"id":"b","status":{"type":"idle"}}]}}"#.utf8)), ["a", "b"])
        XCTAssertNil(CodexThreadRecord.loadedThreadIds(Data(#"{"id":2,"result":{"data":["a"],"nextCursor":"a"}}"#.utf8)),
                     "a page of the list is not the list: a thread it leaves out would be ended")
        XCTAssertNil(CodexThreadRecord.loadedThreadIds(Data(#"{"id":2,"result":{"data":["a",{"name":"b"}]}}"#.utf8)), "an entry without an id")
        XCTAssertNil(CodexThreadRecord.loadedThreadIds(Data(#"{"id":2,"error":{"code":-32601,"message":"unknown method"}}"#.utf8)))
    }

    func testOnlyTheThreeReadOnlyMethodsAreSent() throws {
        func object(_ text: String) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        }
        XCTAssertEqual(try object(CodexDaemonRPC.initialize(version: "1.1.3")),
                       ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": ["clientInfo": ["name": "KoffeeLid", "title": "KoffeeLid", "version": "1.1.3"]]])
        XCTAssertEqual(try object(CodexDaemonRPC.initialized), ["jsonrpc": "2.0", "method": "initialized"])
        XCTAssertEqual(try object(CodexDaemonRPC.threadRead(threadId: #"a"b"#)),
                       ["jsonrpc": "2.0", "id": 2, "method": "thread/read", "params": ["threadId": #"a"b"#, "includeTurns": false]])
        XCTAssertEqual(try object(CodexDaemonRPC.loadedList), ["jsonrpc": "2.0", "id": 2, "method": "thread/loaded/list", "params": [:] as NSDictionary])
    }

    func testAnAnswerIsMatchedByItsId() {
        let notification = Data(#"{"method":"example/changed","params":{"status":"x"},"emittedAtMs":1}"#.utf8)
        XCTAssertEqual(CodexDaemonRPC.answer(notification, to: 1), .unrelated, "a notification is read past")
        XCTAssertEqual(CodexDaemonRPC.answer(Data(#"{"id":2,"result":{}}"#.utf8), to: 1), .unrelated, "an answer to another call")
        XCTAssertEqual(CodexDaemonRPC.answer(Data(#"{"id":1,"result":{"userAgent":"codex/0.157"}}"#.utf8), to: 1), .result)
        XCTAssertEqual(CodexDaemonRPC.answer(Data(#"{"id":1,"error":{"code":-32600}}"#.utf8), to: 1), .failed)
        XCTAssertEqual(CodexDaemonRPC.answer(Data("not json".utf8), to: 1), .failed)
        XCTAssertTrue(CodexDaemonRPC.isInitialized(Data(#"{"id":1,"result":{"userAgent":"codex/0.157","codexHome":"/x"}}"#.utf8)))
        XCTAssertFalse(CodexDaemonRPC.isInitialized(Data(#"{"id":1,"result":{}}"#.utf8)), "an initialize answer names the daemon")
    }

    func testTheUpgradeIsAskedForAndAccepted() {
        let request = CodexDaemonRPC.upgradeRequest(key: "AAAAAAAAAAAAAAAAAAAAAA==")
        XCTAssertTrue(request.hasPrefix("GET / HTTP/1.1\r\n"))
        for header in ["Host: localhost", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==", "Sec-WebSocket-Version: 13"] {
            XCTAssertTrue(request.contains("\r\n\(header)\r\n"), header)
        }
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(CodexDaemonRPC.upgradeAccepted("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket"))
        XCTAssertFalse(CodexDaemonRPC.upgradeAccepted("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertFalse(CodexDaemonRPC.upgradeAccepted("HTTP/1.1 1010\r\n"))
    }
}
