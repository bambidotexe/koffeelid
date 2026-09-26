import XCTest
import KoffeeLidCore

final class ProcWalkTests: XCTestCase {
    func testChainStartsWithSelfAndWalksToTheParent() {
        let chain = ProcWalk.chain(from: getpid())
        XCTAssertEqual(chain.first?.pid, getpid())
        XCTAssertEqual(chain.dropFirst().first?.pid, getppid())
        XCTAssertTrue(chain.count >= 2)
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
    // Pids no process holds: the argv[0] fallback reads nothing, so only the name and the path decide.
    typealias P = ProcWalk.ProcInfo
    static let noPid: Int32 = 2_000_000

    func testCopilotProcessShapes() {
        XCTAssertTrue(ProcWalk.isCopilotPath("/Users/x/.local/bin/copilot"))
        XCTAssertTrue(ProcWalk.isCopilotPath("/Users/x/Library/Caches/github-copilot-sdk/cli/1.0.87-0/copilot"), "GitHub Copilot.app's pooled CLI")
        XCTAssertFalse(ProcWalk.isCopilotPath("/Applications/GitHub Copilot.app/Contents/MacOS/github"), "the desktop app itself runs no hook")
        XCTAssertFalse(ProcWalk.isCopilotPath("/Users/x/Library/Caches/copilot/pkg/darwin-arm64/1.0.88/prebuilds/darwin-arm64/runtime.node"))
        XCTAssertFalse(ProcWalk.isCopilotPath("/usr/local/bin/copilot-language-server"))
        XCTAssertTrue(ProcWalk.isCopilotProcess(P(pid: Self.noPid, ppid: 0, name: "copilot", path: nil)))
        XCTAssertTrue(ProcWalk.isCopilotProcess(P(pid: Self.noPid, ppid: 0, name: "node", path: "/Users/x/.local/bin/copilot")))
        XCTAssertFalse(ProcWalk.isCopilotProcess(P(pid: Self.noPid, ppid: 0, name: "github", path: "/Applications/GitHub Copilot.app/Contents/MacOS/github")))
        if let pid = ProcWalk.pid(of: .copilot, inChainFrom: getpid()) { XCTAssertTrue(ProcWalk.looksLike(.copilot, pid: pid)) }
    }
    func testOpencodeProcessShapes() {
        for path in ["/Users/x/.opencode/bin/opencode", "/Applications/OpenCode.app/Contents/Resources/opencode-cli",
                     "/Users/x/Library/Application Support/ai.opencode.desktop/cli/2.0.6/opencode-cli",
                     "/opt/homebrew/Cellar/opencode-v2/2.0.17/bin/opencode", "/Users/x/.npm/lib/node_modules/@opencode/cli/bin/.opencode"] {
            XCTAssertTrue(ProcWalk.isOpencodePath(path), path)
        }
        XCTAssertFalse(ProcWalk.isOpencodePath("/Applications/OpenCode.app/Contents/MacOS/OpenCode"), "the desktop window is a client, not the server")
        XCTAssertFalse(ProcWalk.isOpencodePath("/Users/x/.opencode/bin/opencode2"), "a launcher script that execs opencode")
        XCTAssertFalse(ProcWalk.isOpencodePath("/usr/local/bin/node"))
        for name in ["opencode", "opencode-cli", ".opencode"] {
            XCTAssertTrue(ProcWalk.isOpencodeProcess(P(pid: Self.noPid, ppid: 0, name: name, path: nil)), name)
        }
        XCTAssertTrue(ProcWalk.isOpencodeProcess(P(pid: Self.noPid, ppid: 0, name: "bun", path: "/Users/x/.opencode/bin/opencode")))
        XCTAssertFalse(ProcWalk.isOpencodeProcess(P(pid: Self.noPid, ppid: 0, name: "OpenCode", path: "/Applications/OpenCode.app/Contents/MacOS/OpenCode")))
        if let pid = ProcWalk.pid(of: .opencode, inChainFrom: getpid()) { XCTAssertTrue(ProcWalk.looksLike(.opencode, pid: pid)) }
    }
    func testEachAgentsProcessIsItsOwnAlone() {
        let samples: [ActivityAgent: P] = [
            .claude: P(pid: Self.noPid, ppid: 0, name: "claude", path: "/Users/x/.local/bin/claude"),
            .codex: P(pid: Self.noPid, ppid: 0, name: "codex", path: "/Users/x/.local/bin/codex"),
            .copilot: P(pid: Self.noPid, ppid: 0, name: "copilot", path: "/Users/x/.local/bin/copilot"),
            .opencode: P(pid: Self.noPid, ppid: 0, name: "opencode", path: "/Users/x/.opencode/bin/opencode"),
        ]
        for agent in ActivityAgent.allCases {
            for (other, info) in samples {
                XCTAssertEqual(ProcWalk.isProcess(of: agent, info), agent == other, "\(agent) asked about \(other)'s process")
            }
        }
    }
    func testTheHookTakesTheClaimedPidOnlyWhenItIsAnAncestorRunningTheAgent() {
        // OpenCode's plugin names its server; the hook's chain decides whether to believe it. Pids above
        // PID_MAX, so the argv[0] fallback reads nothing.
        let hook = Self.noPid + 10, server = Self.noPid + 20, client = Self.noPid + 30, shell = Self.noPid + 40
        let chain = [P(pid: hook, ppid: server, name: "KoffeeLidHook", path: "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook"),
                     P(pid: server, ppid: client, name: "opencode-cli", path: "/Applications/OpenCode.app/Contents/Resources/opencode-cli"),
                     P(pid: client, ppid: shell, name: "opencode-cli", path: "/Applications/OpenCode.app/Contents/Resources/opencode-cli"),
                     P(pid: shell, ppid: 1, name: "-zsh", path: "/bin/zsh")]
        XCTAssertEqual(ProcWalk.pid(of: .opencode, claimed: server, in: chain), server)
        XCTAssertEqual(ProcWalk.pid(of: .opencode, claimed: client, in: chain), client, "a claimed OpenCode ancestor wins over the nearest")
        XCTAssertEqual(ProcWalk.pid(of: .opencode, claimed: Self.noPid + 99, in: chain), server, "not an ancestor: the nearest OpenCode")
        XCTAssertEqual(ProcWalk.pid(of: .opencode, claimed: shell, in: chain), server, "an ancestor that is not OpenCode: the nearest OpenCode")
        XCTAssertEqual(ProcWalk.pid(of: .opencode, claimed: nil, in: chain), server)
        XCTAssertNil(ProcWalk.pid(of: .copilot, claimed: server, in: chain), "a claim never names another agent's process")
        XCTAssertNil(ProcWalk.pid(of: .opencode, claimed: nil, in: []))
        let copilot = [P(pid: hook, ppid: server, name: "KoffeeLidHook", path: nil),
                       P(pid: server, ppid: client, name: "copilot", path: "/Users/x/Library/Caches/github-copilot-sdk/cli/1.0.87-0/copilot"),
                       P(pid: client, ppid: 1, name: "github", path: "/Applications/GitHub Copilot.app/Contents/MacOS/github")]
        XCTAssertEqual(ProcWalk.pid(of: .copilot, claimed: nil, in: copilot), server, "the hook's parent is the copilot process")
    }
    func testOnlyTheManagedDaemonIsAsked() {
        let daemonPath = "/Users/x/.codex/packages/app-server-daemon/releases/0.157.0-aarch64-apple-darwin/bin/codex"
        let daemonArguments = [daemonPath, "app-server", "--listen", "unix://", "--managed-daemon"]
        XCTAssertTrue(ProcWalk.isManagedCodexDaemon(path: daemonPath, arguments: daemonArguments))
        XCTAssertTrue(ProcWalk.isSharedCodexHost(path: daemonPath, arguments: daemonArguments), "the managed daemon is a shared host too")
        XCTAssertTrue(ProcWalk.isManagedCodexDaemon(path: "/opt/codex/bin/codex", arguments: ["codex", "app-server", "--managed-daemon"]), "by its arguments alone")
        XCTAssertTrue(ProcWalk.isManagedCodexDaemon(path: daemonPath, arguments: []), "by its path alone")
        XCTAssertTrue(ProcWalk.isSharedCodexHost(path: daemonPath, arguments: []), "by its path alone")
        let desktop = "/Applications/ChatGPT.app/Contents/Resources/codex"
        XCTAssertFalse(ProcWalk.isManagedCodexDaemon(path: desktop, arguments: [desktop, "app-server"]), "the desktop app's codex is not the managed daemon")
        XCTAssertTrue(ProcWalk.isSharedCodexHost(path: desktop, arguments: [desktop, "app-server"]), "but it is a shared host")
        for (path, arguments) in [("/Users/x/.codex/packages/standalone/0.157.0/bin/codex", ["codex"]),
                                  ("/Users/x/.local/bin/codex", ["codex", "exec", "--json"])] {
            XCTAssertFalse(ProcWalk.isManagedCodexDaemon(path: path, arguments: arguments), "the TUI and codex exec")
            XCTAssertFalse(ProcWalk.isSharedCodexHost(path: path, arguments: arguments), "the TUI and codex exec")
        }
        XCTAssertFalse(ProcWalk.isSharedCodexHost(path: nil, arguments: ["app-server"]), "argv[0] is the program, not an argument")
        XCTAssertFalse(ProcWalk.isManagedCodexDaemon(path: nil, arguments: ["--managed-daemon"]), "argv[0] is the program, not an argument")
        // The KERN_PROCARGS2 reader, checked on this process, whose argv the runner set.
        XCTAssertEqual(ProcWalk.arguments(forPid: getpid()), CommandLine.arguments)
        XCTAssertNil(ProcWalk.arguments(forPid: 2_000_000))
        let own = ProcWalk.info(for: getpid())!, ownArguments = ProcWalk.arguments(forPid: getpid()) ?? []
        XCTAssertFalse(ProcWalk.isManagedCodexDaemon(path: own.path, arguments: ownArguments))
        XCTAssertFalse(ProcWalk.isSharedCodexHost(path: own.path, arguments: ownArguments))
    }
    func testEnvironmentValueReadsOwnEnvironment() {
        // A same-user process's environment, past its own argv in the same KERN_PROCARGS2 buffer.
        let expected = ProcessInfo.processInfo.environment["HOME"]
        XCTAssertNotNil(expected)
        XCTAssertEqual(ProcWalk.environmentValue("HOME", forPid: getpid()), expected)
        XCTAssertNil(ProcWalk.environmentValue("KOFFEELID_NO_SUCH_VAR_EVER", forPid: getpid()))
        XCTAssertNil(ProcWalk.environmentValue("HOME", forPid: 2_000_000), "a dead pid reads nothing")
    }
    func testShellNamesAreRecognisedWithALoginDash() {
        for name in ["zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "dash", "ksh", "tcsh", "-tcsh"] {
            XCTAssertTrue(ProcWalk.ProcInfo(pid: 1, ppid: 0, name: name, path: nil).isShell, name)
        }
        for name in ["make", "sleep", "claude", "zshx", "-", "", "--zsh", "ssh"] {
            XCTAssertFalse(ProcWalk.ProcInfo(pid: 1, ppid: 0, name: name, path: nil).isShell, name)
        }
    }
    func testTheProcessGroupStartAndChildrenAreRead() throws {
        let own = try XCTUnwrap(ProcWalk.info(for: getpid()))
        XCTAssertEqual(own.pgid, getpgrp())
        let started = try XCTUnwrap(own.startedAt)
        XCTAssertLessThan(started, Date()); XCTAssertGreaterThan(started, Date().addingTimeInterval(-24 * 3600))
        let before = Date().addingTimeInterval(-1)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let childStart = try XCTUnwrap(ProcWalk.info(for: child.processIdentifier)?.startedAt)
        XCTAssertGreaterThan(childStart, before)
        XCTAssertTrue(ProcWalk.childStartTimes(pid: getpid()).contains(childStart), "the child is listed with its start")
        XCTAssertEqual(ProcWalk.childStartTimes(pid: child.processIdentifier), [])
        XCTAssertEqual(ProcWalk.childStartTimes(pid: 2_000_000), [])
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

    // MARK: a shell under an agent

    /// Pids no process holds, so the predicates decide on the name and path alone.
    func shell(under parents: [(name: String, path: String?)]) -> [ProcWalk.ProcInfo] {
        var chain = [ProcWalk.ProcInfo(pid: 999_900, ppid: 999_901, name: "zsh", path: "/bin/zsh")]
        for (i, parent) in parents.enumerated() {
            chain.append(ProcWalk.ProcInfo(pid: 999_901 + Int32(i), ppid: 999_902 + Int32(i), name: parent.name, path: parent.path))
        }
        return chain
    }
    /// An agent's tool shell, or a shell a script it started opened, runs the agent's own work: the shells seen
    /// under OpenCode's server and Codex's app-server daemon, and under Claude Code and Copilot.
    func testAShellUnderAnAgentIsThatAgents() {
        let launchd = (name: "launchd", path: Optional("/sbin/launchd"))
        XCTAssertEqual(ProcWalk.hostingAgent(in: shell(under: [("opencode", "/Users/u/.opencode/bin/opencode"), launchd])), .opencode)
        XCTAssertEqual(ProcWalk.hostingAgent(in: shell(under: [
            ("codex", "/Users/u/.codex/packages/app-server-daemon/releases/0.157.1-aarch64-apple-darwin/bin/codex"),
            ("codex", "/Users/u/.codex/packages/app-server-daemon/releases/0.157.1-aarch64-apple-darwin/bin/codex"), launchd])), .codex)
        XCTAssertEqual(ProcWalk.hostingAgent(in: shell(under: [("2.1.90", "/Users/u/.local/share/claude/versions/2.1.90"),
                                                               ("zsh", "/bin/zsh"), ("login", "/usr/bin/login")])), .claude)
        XCTAssertEqual(ProcWalk.hostingAgent(in: shell(under: [("copilot", "/Users/u/.local/bin/copilot"), ("zsh", "/bin/zsh")])), .copilot)
    }
    /// A shell in a terminal, an editor or a desktop app's own window is the user's.
    func testAShellInATerminalOrAnAppIsNoAgents() {
        XCTAssertNil(ProcWalk.hostingAgent(in: shell(under: [("login", "/usr/bin/login"),
                                                             ("Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")])))
        XCTAssertNil(ProcWalk.hostingAgent(in: shell(under: [("Code Helper", "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")])))
        XCTAssertNil(ProcWalk.hostingAgent(in: shell(under: [("Claude", "/Applications/Claude.app/Contents/MacOS/Claude"),
                                                             ("Codex", "/Applications/Codex.app/Contents/MacOS/Codex")])))
        XCTAssertNil(ProcWalk.hostingAgent(in: shell(under: [("tmux", "/opt/homebrew/bin/tmux"), ("launchd", "/sbin/launchd")])))
        XCTAssertNil(ProcWalk.hostingAgent(in: []))
    }
}
