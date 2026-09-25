import XCTest
import KoffeeLidCore

final class ProcWalkTests: XCTestCase {
    func testChainStartsWithSelfAndWalksToTheParent() {
        let chain = ProcWalk.chain(from: getpid())
        XCTAssertEqual(chain.first?.pid, getpid())
        XCTAssertEqual(chain.dropFirst().first?.pid, getppid())
        XCTAssertTrue(chain.count >= 2)
    }
    func testEnvironmentValueReadsTheExecTimeEnvironment() {
        // KERN_PROCARGS2 holds the environment as it was at exec, and macOS withholds it for other
        // processes (even `ps -E` shows none), so the parser is checked on our own process with a
        // variable the runner inherited at launch. Callers treat nil as "unknown" and fall back.
        let home = ProcessInfo.processInfo.environment["HOME"]
        XCTAssertNotNil(home)
        XCTAssertEqual(ProcWalk.environmentValue("HOME", forPid: getpid()), home)
        XCTAssertNil(ProcWalk.environmentValue("KOFFEELID_NOT_SET_ANYWHERE", forPid: getpid()))
        XCTAssertNil(ProcWalk.environmentValue("HOME", forPid: 2_000_000), "no such process reads as nil")
    }
    func testARunningExecutableIsFoundByTheFileItIs() throws {
        // This test's own process is the one executable certain to be running.
        let own = try XCTUnwrap(ProcWalk.info(for: getpid())?.path)
        XCTAssertTrue(ProcWalk.isRunning(executableAt: URL(fileURLWithPath: own)))
        let stranger = FileManager.default.temporaryDirectory.appendingPathComponent("not-running-\(UUID().uuidString)")
        try Data().write(to: stranger)
        defer { try? FileManager.default.removeItem(at: stranger) }
        XCTAssertFalse(ProcWalk.isRunning(executableAt: stranger))
        XCTAssertFalse(ProcWalk.isRunning(executableAt: URL(fileURLWithPath: "/nonexistent/KoffeeLidWatchdog")))
    }
    func testClaudePathShapes() {
        XCTAssertTrue(ProcWalk.isClaudePath("/Users/x/.local/bin/claude"))
        XCTAssertTrue(ProcWalk.isClaudePath("/Users/x/.local/share/claude/versions/2.1.246"))
        XCTAssertFalse(ProcWalk.isClaudePath("/usr/bin/zsh"))
        XCTAssertFalse(ProcWalk.isClaudePath("/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook"))
        XCTAssertTrue(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "claude", path: nil)))
        XCTAssertTrue(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "2.1.246", path: "/x/claude/versions/2.1.246")))
        XCTAssertFalse(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "node", path: "/usr/local/bin/node")))
    }
    func testCodexPathShapes() {
        XCTAssertTrue(ProcWalk.isCodexPath("/Users/x/.local/bin/codex"))
        XCTAssertTrue(ProcWalk.isCodexPath("/Users/x/.codex/packages/standalone/current/bin/codex"))
        XCTAssertTrue(ProcWalk.isCodexPath("/Users/x/.codex/packages/app-server-daemon/releases/0.157.0-aarch64-apple-darwin/bin/codex"))
        XCTAssertFalse(ProcWalk.isCodexPath("/Users/x/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient"))
        XCTAssertFalse(ProcWalk.isCodexPath("/Users/x/.local/bin/claude"))
        XCTAssertTrue(ProcWalk.isCodexProcess(.init(pid: 1, ppid: 0, name: "codex", path: nil)))
        XCTAssertFalse(ProcWalk.isCodexProcess(.init(pid: 1, ppid: 0, name: "claude", path: "/Users/x/.local/bin/claude")))
        XCTAssertTrue(ProcWalk.isProcess(of: .codex, .init(pid: 1, ppid: 0, name: "codex", path: nil)))
        XCTAssertFalse(ProcWalk.isProcess(of: .claude, .init(pid: 1, ppid: 0, name: "codex", path: nil)))
        if let pid = ProcWalk.pid(of: .codex, inChainFrom: getpid()) { XCTAssertTrue(ProcWalk.looksLike(.codex, pid: pid)) }
    }
    func testNoClaudeInAnOrdinaryChainAndAliveness() {
        // Run from a plain terminal the chain has no Claude; run from inside a Claude Code shell it does.
        // Either way the answer must be consistent with the per-process check.
        if let pid = ProcWalk.claudePid(inChainFrom: getpid()) { XCTAssertTrue(ProcWalk.looksLikeClaude(pid: pid)) }
        XCTAssertTrue(ProcWalk.isAlive(pid: getpid())); XCTAssertFalse(ProcWalk.isAlive(pid: 2_000_000))
    }
    func testRegistryRecordParsesAndRefusesOtherPids() {
        let json = Data("{\"pid\": 555, \"sessionId\": \"s1\", \"status\": \"busy\", \"statusUpdatedAt\": 1700000000250}".utf8)
        let r = ClaudeRegistryRecord.parse(json, expectedPid: 555)
        XCTAssertEqual(r?.sessionId, "s1"); XCTAssertEqual(r?.isBusy, true); XCTAssertEqual(r?.isIdle, false)
        XCTAssertEqual(r?.statusUpdatedAt, Date(timeIntervalSince1970: 1_700_000_000.25))
        XCTAssertNil(ClaudeRegistryRecord.parse(json, expectedPid: 556), "a recycled pid's file must read as no record")
        XCTAssertEqual(ClaudeRegistryRecord.parse(Data("{\"pid\": 1, \"status\": \"idle\"}".utf8), expectedPid: 1)?.isIdle, true)
        XCTAssertEqual(ClaudeRegistryRecord.parse(Data("{\"pid\": 1, \"status\": \"resting\"}".utf8), expectedPid: 1)?.isIdle, false, "unknown statuses are neither")
        XCTAssertNil(ClaudeRegistryRecord.parse(Data("nope".utf8), expectedPid: 1))
    }
}
