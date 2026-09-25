// App/Sources/CodexDaemonClient.swift
import Foundation
import KoffeeLidCore

/// Asks Codex's managed daemon, which hosts the TUI's sessions, about its threads: `thread/read` (one
/// thread's status) and `thread/loaded/list` (the threads it holds in memory). The control socket is a
/// WebSocket over a unix socket; each call opens it, upgrades it, sends `initialize`, `initialized` and the
/// one read, and closes it. Nothing else is ever sent. The protocol is undocumented and versioned, so every
/// call fails closed: a refusal, a timeout or an answer of any other shape completes with nil, and the
/// rollout decides. The I/O runs on a utility queue, never blocks past `deadlineSeconds` from the call, and
/// every completion runs on the main actor.
enum CodexDaemonClient {
    /// `~/.codex/app-server-control/app-server-control.sock`, a link to the daemon's socket.
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/app-server-control/app-server-control.sock").path
    }
    /// The whole of a call, connection and upgrade included.
    static let deadlineSeconds: Double = 1

    /// Whether the link resolves to a socket: when it does not, the daemon is not running and is not asked.
    static var socketExists: Bool { resolvedSocket != nil }

    static func readThread(id: String, completion: @escaping @MainActor (CodexThreadRecord?) -> Void) {
        call(CodexDaemonRPC.threadRead(threadId: id), read: CodexThreadRecord.parse, completion: completion)
    }

    static func loadedThreadIds(completion: @escaping @MainActor (Set<String>?) -> Void) {
        call(CodexDaemonRPC.loadedList, read: CodexThreadRecord.loadedThreadIds, completion: completion)
    }

    // MARK: the exchange

    private static func call<T>(_ request: String, read: @escaping (Data) -> T?, completion: @escaping @MainActor (T?) -> Void) {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(deadlineSeconds * 1_000_000_000)
        DispatchQueue.global(qos: .utility).async {
            let answer = exchange(request, deadline: deadline).flatMap(read)
            Task { @MainActor in completion(answer) }
        }
    }

    /// The daemon's socket, the link resolved; nil when it is missing or not a socket.
    private static var resolvedSocket: String? {
        guard let real = realpath(socketPath, nil) else { return nil }
        defer { free(real) }
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return String(cString: real)
    }

    /// The payload of the answer to `request`, or nil.
    private static func exchange(_ request: String, deadline: UInt64) -> Data? {
        guard let path = resolvedSocket else { return nil }
        let fd = socket(PF_LOCAL, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { return nil }
        var link = Link(fd: fd, deadline: deadline)
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        guard link.connect(to: path),
              link.send(Data(CodexDaemonRPC.upgradeRequest(key: key).utf8)),
              let head = link.head(), CodexDaemonRPC.upgradeAccepted(head),
              link.send(WebSocketFrame.encodeText(CodexDaemonRPC.initialize(version: KoffeeLidCore.version))),
              let initialized = link.answer(to: CodexDaemonRPC.initializeId), CodexDaemonRPC.isInitialized(initialized),
              link.send(WebSocketFrame.encodeText(CodexDaemonRPC.initialized)),
              link.send(WebSocketFrame.encodeText(request)) else { return nil }
        return link.answer(to: CodexDaemonRPC.callId)
    }

    /// One non-blocking connection and what it has read and not yet consumed. Every wait is a `poll` bounded
    /// by the call's deadline.
    private struct Link {
        let fd: Int32
        let deadline: UInt64
        var buffer = Data()
        /// A response head longer than this is not the daemon's.
        static let headMaxBytes = 16 * 1024

        func connect(to path: String) -> Bool {
            var address = sockaddr_un()
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result == 0 { return true }
            guard errno == EINPROGRESS, wait(for: Int16(POLLOUT)) else { return false }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 && failure == 0
        }

        func send(_ data: Data) -> Bool {
            var sent = 0
            while sent < data.count {
                let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, data.count - sent) }
                if n > 0 { sent += n; continue }
                guard n < 0, errno == EAGAIN || errno == EINTR, wait(for: Int16(POLLOUT)) else { return false }
            }
            return true
        }

        /// The response head up to its blank line; what follows it stays in the buffer.
        mutating func head() -> String? {
            let blank = Data("\r\n\r\n".utf8)
            while true {
                if let end = buffer.range(of: blank) {
                    let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                    buffer = Data(buffer[end.upperBound...])
                    return head
                }
                guard buffer.count < Self.headMaxBytes, fill() else { return nil }
            }
        }

        /// The payload of the frame answering `id`, reading past notifications; nil for an error, a frame
        /// that is not an answer, the end of the stream or the deadline.
        mutating func answer(to id: Int) -> Data? {
            while true {
                if let frame = WebSocketFrame.decode(buffer) {
                    buffer = Data(buffer.dropFirst(frame.consumed))
                    switch CodexDaemonRPC.answer(frame.payload, to: id) {
                    case .unrelated: continue
                    case .result: return frame.payload
                    case .failed: return nil
                    }
                }
                guard buffer.count <= WebSocketFrame.maxPayloadBytes + 14, fill() else { return nil }
            }
        }

        /// Reads what has arrived, waiting for it until the deadline; false at the end of the stream.
        mutating func fill() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]); return true }
                guard n < 0, errno == EAGAIN || errno == EINTR, wait(for: Int16(POLLIN)) else { return false }
            }
        }

        /// Whether `events` came before the deadline.
        func wait(for events: Int16) -> Bool {
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&descriptor, 1, Int32(max(1, (deadline - now) / 1_000_000)))
                if result > 0 { return true }
                if result < 0, errno == EINTR { continue }
                if result < 0 { return false }
            }
        }
    }
}
