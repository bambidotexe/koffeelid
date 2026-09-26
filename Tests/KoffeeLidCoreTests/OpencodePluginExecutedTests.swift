import XCTest
import KoffeeLidCore

/// Runs the generated `OpencodePlugin` source under a real `node`, driving two `setup()` instances against a
/// synthetic event stream the way two open directories of one opencode server would. Opt-in: skipped when no
/// `node` binary can be found. Everything lives under one temp directory; the driven script has a fixed
/// deadline, so a regression that reintroduces an unbounded loop fails the test instead of hanging it.
final class OpencodePluginExecutedTests: XCTestCase {
    /// `PATH`, then the usual places a Node install puts its binary that a minimal test environment's `PATH`
    /// might not include.
    private func findNode() -> String? {
        let fm = FileManager.default
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = pathDirs.map { "\($0)/node" } + [
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
            "\(home)/.local/share/mise/shims/node", "\(home)/.volta/bin/node", "\(home)/.nvm/current/bin/node",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs `executable` with `arguments`, failing (not hanging) after `timeout`. Returns (exit code, stdout+stderr).
    @discardableResult
    private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testSyntaxAndRuntimeBehaviourUnderARealNode() throws {
        guard let node = findNode() else { throw XCTSkip("no node binary found on PATH or in the usual places") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("koffeelid-opencode-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outputURL = dir.appendingPathComponent("out.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        // The stand-in hook: appends whatever it is fed on stdin to the shared output file, ignoring its
        // arguments, and exits — nothing here is KoffeeLid's own hook binary. The plugin serialises every
        // launch through one shared promise chain, so concurrent writes are not a concern.
        let standInURL = dir.appendingPathComponent("stand-in-hook.sh")
        let standInScript = "#!/bin/sh\ncat >> \(shellQuoted(outputURL.path))\n"
        try standInScript.write(to: standInURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standInURL.path)

        let pluginURL = dir.appendingPathComponent("koffeelid.mjs")
        try OpencodePlugin.source(hookPath: standInURL.path).write(to: pluginURL, atomically: true, encoding: .utf8)

        // `node --check`: the generated file must parse as a module on its own, before anything runs it.
        let checked = try run(node, ["--check", pluginURL.path])
        XCTAssertEqual(checked.status, 0, "node --check failed: \(checked.output)")

        let driverURL = dir.appendingPathComponent("driver.mjs")
        try Self.driverSource(pluginPath: pluginURL.path).write(to: driverURL, atomically: true, encoding: .utf8)

        let driven = try run(node, [driverURL.path], timeout: 15)
        XCTAssertEqual(driven.status, 0, "driver.mjs failed: \(driven.output)")

        let raw = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        let payloads: [[String: Any]] = try lines.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], "not a JSON object: \($0)")
        }
        // Correlates a line back to the event that produced it: every forwarded event in this run has a
        // distinct (type, session id) pair.
        func key(_ type: String, _ sessionId: String) -> String { "\(type)|\(sessionId)" }
        let byKey: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: payloads.compactMap { p -> (String, [String: Any])? in
            guard let type = p["hook_event_name"] as? String, let sid = p["session_id"] as? String else { return nil }
            return (key(type, sid), p)
        })

        // Every event that should be forwarded arrives exactly once, whichever of the two instances got to
        // it first: the shared globalThis de-duplicates across them. (10 forwarded; the tool-name tracker,
        // a non-user enqueue and location.shutdown are dropped, so `payloads.count` would be 13 without dedup
        // and without the drops working.)
        XCTAssertEqual(payloads.count, 10, "expected exactly one line per forwarded event, across both instances: \(raw)")
        let expected: [(String, String)] = [
            ("session.created", "root"), ("session.created", "child"), ("session.created", "grand"),
            ("session.tool.called", "grand"), ("session.inbox.enqueued", "root"),
            ("session.created", "cyc_a"), ("session.created", "cyc_b"),
            ("session.execution.succeeded", "cyc_a"), ("session.deleted", "child"),
            ("session.execution.interrupted", "grand"),
        ]
        for (type, sid) in expected { XCTAssertNotNil(byKey[key(type, sid)], "\(type)/\(sid) should have been forwarded") }
        XCTAssertEqual(byKey[key("session.inbox.enqueued", "root")]?["delivery"] as? String, "steer",
                       "the forwarded inbox line must be the user prompt (e7), not the dropped synthetic one (e6)")
        XCTAssertFalse(payloads.contains { ($0["hook_event_name"] as? String) == "location.shutdown" })

        // A grandchild's parent_id is the root, not its immediate parent.
        XCTAssertEqual(byKey[key("session.created", "grand")]?["parent_id"] as? String, "root")
        // The regression this fix targets: "child" (the middle session) is deleted (session.deleted/child)
        // before "grand"'s own terminal event arrives; parent_id must still walk through to "root", not stop
        // at the now-deleted "child" (which dropping the link on session.deleted used to produce).
        XCTAssertEqual(byKey[key("session.execution.interrupted", "grand")]?["parent_id"] as? String, "root")

        // No directory field, and nothing planted in a field the plugin does not read reaches a payload.
        XCTAssertFalse(raw.contains("directory"), "no path may leave OpenCode")
        XCTAssertFalse(raw.contains("SECRET"), "a planted secret must never reach a payload: \(raw)")
    }

    private func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Two `setup()` instances (two open directories of one server) fed the identical event sequence: the
    /// real bug this exercises (dropping a child's link on session.deleted) needs "child" deleted before
    /// "grand"'s own terminal event arrives, and the a↔b cycle needs a real mutual parent link.
    private static func driverSource(pluginPath: String) -> String {
        """
        import plugin from \(jsonLiteral(pluginPath))

        const events = [
          { id: "e1", type: "session.created", created: 1, data: { sessionID: "root", location: { directory: "/secret/root" } }, location: { directory: "/secret/root" } },
          { id: "e2", type: "session.created", created: 2, data: { sessionID: "child", parentID: "root" } },
          { id: "e3", type: "session.created", created: 3, data: { sessionID: "grand", parentID: "child" } },
          { type: "session.tool.input.started", data: { id: "t1", name: "bash" } },
          { id: "e5", type: "session.tool.called", created: 5, data: { sessionID: "grand", id: "t1", input: "SECRET-INPUT" } },
          { id: "e6", type: "session.inbox.enqueued", created: 6, data: { sessionID: "root", item: { type: "synthetic", text: "SECRET-SYNTH" } } },
          { id: "e7", type: "session.inbox.enqueued", created: 7, data: { sessionID: "root", item: { type: "user", delivery: "steer", text: "SECRET-PROMPT" } } },
          { id: "e8", type: "location.shutdown", created: 8, data: {}, location: { directory: "/secret/shutdown" } },
          { id: "e9", type: "session.created", created: 9, data: { sessionID: "cyc_a", parentID: "cyc_b" } },
          { id: "e10", type: "session.created", created: 10, data: { sessionID: "cyc_b", parentID: "cyc_a" } },
          { id: "e11", type: "session.execution.succeeded", created: 11, data: { sessionID: "cyc_a" } },
          { id: "e12", type: "session.deleted", created: 12, data: { sessionID: "child" } },
          { id: "e13", type: "session.execution.interrupted", created: 13, data: { sessionID: "grand", reason: "user" } },
        ]

        function ctxFor() {
          return { event: { subscribe({ signal }) { return (async function* () { for (const e of events) yield e } )() } } }
        }

        const d1 = plugin.setup(ctxFor())
        const d2 = plugin.setup(ctxFor())
        await new Promise((resolve) => setTimeout(resolve, 4000))
        d1(); d2()
        await new Promise((resolve) => setTimeout(resolve, 300))
        process.exit(0)

        """
    }

    private static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\(value)\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
