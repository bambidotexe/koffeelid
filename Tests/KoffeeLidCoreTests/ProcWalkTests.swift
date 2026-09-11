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
    func testClaudePathShapes() {
        XCTAssertTrue(ProcWalk.isClaudePath("/Users/x/.local/bin/claude"))
        XCTAssertTrue(ProcWalk.isClaudePath("/Users/x/.local/share/claude/versions/2.1.246"))
        XCTAssertFalse(ProcWalk.isClaudePath("/usr/bin/zsh"))
        XCTAssertFalse(ProcWalk.isClaudePath("/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook"))
        XCTAssertTrue(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "claude", path: nil)))
        XCTAssertTrue(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "2.1.246", path: "/x/claude/versions/2.1.246")))
        XCTAssertFalse(ProcWalk.isClaudeProcess(.init(pid: 1, ppid: 0, name: "node", path: "/usr/local/bin/node")))
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
