import Foundation

/// What Codex's daemon answers `thread/read` about one thread: its status now, when it last changed and
/// its rollout file. Only `result.thread.id`, `status.type`, `updatedAt` and `path` are read; the rest of the
/// thread is never kept, returned or logged.
public struct CodexThreadRecord: Equatable, Sendable {
    public var status: String
    public var updatedAt: Date?
    public var rolloutPath: String?

    public init(status: String, updatedAt: Date? = nil, rolloutPath: String? = nil) {
        self.status = status; self.updatedAt = updatedAt; self.rolloutPath = rolloutPath
    }

    public enum Verdict: Equatable, Sendable {
        /// Nothing runs in the thread: the session's turn is over.
        case over
        /// A turn runs in the thread.
        case busy
        /// A status this vocabulary does not know: the rollout decides.
        case undecided
    }

    /// `notLoaded` (the daemon does not hold the thread) and `idle` (it holds it, with no turn) have nothing
    /// running; `active` is a turn at work, a dialog included. Every other status decides nothing. The status
    /// is the daemon's present, not a stamp, so it is weighed against nothing of ours.
    public var verdict: Verdict {
        switch status {
        case "notLoaded", "idle": return .over
        case "active": return .busy
        default: return .undecided
        }
    }

    /// The record in a `thread/read` answer about `threadId`, or nil for a refusal, any other shape, or a record
    /// that does not name that thread.
    public static func parse(_ data: Data, expecting threadId: String) -> CodexThreadRecord? {
        guard let result = CodexDaemonRPC.result(of: data),
              let thread = result["thread"] as? [String: Any], thread["id"] as? String == threadId,
              let status = (thread["status"] as? [String: Any])?["type"] as? String else { return nil }
        return CodexThreadRecord(status: status, updatedAt: stamp(thread["updatedAt"]), rolloutPath: thread["path"] as? String)
    }

    /// The ids of the threads the daemon holds in memory, from a `thread/loaded/list` answer; nil for a
    /// refusal, an entry without an id, or a page that is not the last: a thread missing from a partial
    /// list would be taken for one the daemon does not hold.
    public static func loadedThreadIds(_ data: Data) -> Set<String>? {
        guard let result = CodexDaemonRPC.result(of: data), let entries = result["data"] as? [Any],
              result["nextCursor"] == nil || result["nextCursor"] is NSNull else { return nil }
        var ids: Set<String> = []
        for entry in entries {
            guard let id = entry as? String ?? (entry as? [String: Any])?["id"] as? String else { return nil }
            ids.insert(id)
        }
        return ids
    }

    /// An ISO 8601 string, or a number of Unix seconds (milliseconds above 10^11).
    private static func stamp(_ value: Any?) -> Date? {
        if let text = value as? String { return ActivityCodec.isoMs.date(from: text) ?? ActivityCodec.iso.date(from: text) }
        if let number = value as? NSNumber, !CodexDaemonRPC.isBoolean(number) {
            let seconds = number.doubleValue > 1e11 ? number.doubleValue / 1000 : number.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

/// The JSON-RPC 2.0 messages KoffeeLid sends Codex's daemon over its control socket, and how an answer is
/// read. Nothing but `initialize`, the `initialized` notification, `thread/read` and `thread/loaded/list` is
/// ever sent: all three calls only read.
public enum CodexDaemonRPC {
    public static let initializeId = 1
    /// The id of the one call after `initialize`.
    public static let callId = 2

    /// The HTTP/1.1 request that turns the socket into a WebSocket; `key` is 16 random bytes, in base64.
    public static func upgradeRequest(key: String) -> String {
        "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
    }

    /// Whether the daemon's response head, up to its blank line, switches protocols (`101`).
    public static func upgradeAccepted(_ head: String) -> Bool {
        let status = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let words = status.split(separator: " ")
        return words.count >= 2 && words[0] == "HTTP/1.1" && words[1] == "101"
    }

    public static func initialize(version: String) -> String {
        message(["jsonrpc": "2.0", "id": initializeId, "method": "initialize",
                 "params": ["clientInfo": ["name": "KoffeeLid", "title": "KoffeeLid", "version": version]]])
    }
    public static let initialized = message(["jsonrpc": "2.0", "method": "initialized"])
    public static func threadRead(threadId: String) -> String {
        message(["jsonrpc": "2.0", "id": callId, "method": "thread/read", "params": ["threadId": threadId, "includeTurns": false]])
    }
    public static let loadedList = message(["jsonrpc": "2.0", "id": callId, "method": "thread/loaded/list", "params": [String: Any]()])

    public enum Answer: Equatable {
        /// A notification, a request of the daemon's own, or the answer to another id: read past it.
        case unrelated
        /// The answer to this id, with a `result`.
        case result
        /// The answer to this id is an error, or the frame is not a JSON-RPC message.
        case failed
    }

    /// What the frame `payload` is to the call with `id`.
    public static func answer(_ payload: Data, to id: Int) -> Answer {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return .failed }
        guard object["method"] == nil, let answered = object["id"] as? NSNumber, !isBoolean(answered),
              answered.intValue == id else { return .unrelated }
        return object["error"] == nil && object["result"] is [String: Any] ? .result : .failed
    }

    /// Whether `payload` answers `initialize` as the daemon does: a result naming its `userAgent`.
    public static func isInitialized(_ payload: Data) -> Bool {
        answer(payload, to: initializeId) == .result && result(of: payload)?["userAgent"] is String
    }

    /// A JSON `true` or `false`: an `NSNumber` that Swift would also read as 1 or 0.
    static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    /// The `result` object of an answer with no `error`.
    static func result(of payload: Data) -> [String: Any]? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any], object["error"] == nil else { return nil }
        return object["result"] as? [String: Any]
    }

    private static func message(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
