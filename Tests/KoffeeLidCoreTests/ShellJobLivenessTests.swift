import XCTest
import KoffeeLidCore

final class ShellJobLivenessTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }
    typealias Probe = ShellJobLiveness.Probe
    let gone = Probe(alive: false, isShell: true, atPrompt: false, hasChildren: false)
    let replaced = Probe(alive: true, isShell: false, atPrompt: true, hasChildren: false)
    let atPrompt = Probe(alive: true, isShell: true, atPrompt: true, hasChildren: false)
    let atPromptWithChildren = Probe(alive: true, isShell: true, atPrompt: true, hasChildren: true)
    let running = Probe(alive: true, isShell: true, atPrompt: false, hasChildren: true)

    func testAShellGoneDropsTheJob() {
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(gone, promptSeenAt: &seen, now: t0), .drop(reason: "shell gone"))
    }
    func testAShellReplacedByItsProgramIsKept() {
        var seen: Date? = t0
        XCTAssertEqual(ShellJobLiveness.judge(replaced, promptSeenAt: &seen, now: at(60)), .keep, "exec'd into the program: the kqueue ends it")
        XCTAssertNil(seen)
    }
    func testAShellAtItsPromptWithNoChildIsDroppedOnceSettled() {
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: t0), .keep, "first sighting")
        XCTAssertEqual(seen, t0)
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(4)), .keep, "not settled yet")
        XCTAssertEqual(seen, t0, "the first sighting stands")
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(ActivityConstants.jobPromptSettleSeconds)),
                       .drop(reason: "shell at its prompt"))
    }
    func testAChildOrAForegroundCommandResetsTheSettle() {
        var seen: Date?
        _ = ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: t0)
        XCTAssertEqual(ShellJobLiveness.judge(atPromptWithChildren, promptSeenAt: &seen, now: at(3)), .keep, "a child: the shell still runs something")
        XCTAssertNil(seen)
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(6)), .keep, "the settle starts again")
        XCTAssertEqual(seen, at(6))
        XCTAssertEqual(ShellJobLiveness.judge(running, promptSeenAt: &seen, now: at(9)), .keep, "a foreground command")
        XCTAssertNil(seen)
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(12)), .keep)
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(17)), .drop(reason: "shell at its prompt"))
    }
    func testARunningCommandIsKeptIndefinitely() {
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(running, promptSeenAt: &seen, now: at(6 * 3600)), .keep)
        XCTAssertNil(seen)
    }
    func testTheProbeIsReadFromTheShellsProcess() {
        let since = at(100)
        let shell = ProcWalk.ProcInfo(pid: 7, ppid: 1, name: "-zsh", path: "/bin/zsh", pgid: 7, tpgid: 7, startedAt: at(10))
        XCTAssertEqual(ShellJobLiveness.probe(shell, children: [], jobSince: since), atPrompt)
        let busy = ProcWalk.ProcInfo(pid: 7, ppid: 1, name: "zsh", path: "/bin/zsh", pgid: 7, tpgid: 900, startedAt: at(10))
        XCTAssertEqual(ShellJobLiveness.probe(busy, children: [at(100.5)], jobSince: since), running)
        let program = ProcWalk.ProcInfo(pid: 7, ppid: 1, name: "make", path: "/usr/bin/make", pgid: 7, tpgid: 7, startedAt: at(10))
        XCTAssertEqual(ShellJobLiveness.probe(program, children: [], jobSince: since), replaced, "exec keeps the start time")
        XCTAssertFalse(ShellJobLiveness.probe(nil, children: [], jobSince: since).alive, "no such process")
        let recycled = ProcWalk.ProcInfo(pid: 7, ppid: 1, name: "mdworker", path: nil, pgid: 7, tpgid: 0, startedAt: at(101))
        XCTAssertFalse(ShellJobLiveness.probe(recycled, children: [], jobSince: since).alive, "a process started after the job began is not its shell")
        let noTerminal = ProcWalk.ProcInfo(pid: 7, ppid: 1, name: "zsh", path: nil, pgid: 7, tpgid: 0, startedAt: nil)
        XCTAssertFalse(ShellJobLiveness.probe(noTerminal, children: [], jobSince: since).atPrompt, "no terminal: never at a prompt")
    }
    func testOnlyAChildStartedSinceTheJobBeganCounts() {
        let since = at(100)
        let shell = ProcWalk.ProcInfo(pid: 7, ppid: 1, name: "-zsh", path: "/bin/zsh", pgid: 7, tpgid: 7, startedAt: at(10))
        // Powerlevel10k's gitstatusd lives beside every shell from its start; an earlier `&` job likewise.
        let older = ShellJobLiveness.probe(shell, children: [at(11), at(50)], jobSince: since)
        XCTAssertFalse(older.hasChildren)
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(older, promptSeenAt: &seen, now: at(115)), .keep)
        XCTAssertEqual(ShellJobLiveness.judge(older, promptSeenAt: &seen, now: at(120)), .drop(reason: "shell at its prompt"),
                       "a child older than the job says nothing about it")
        let younger = ShellJobLiveness.probe(shell, children: [at(11), at(100.2)], jobSince: since)
        XCTAssertTrue(younger.hasChildren)
        seen = nil
        XCTAssertEqual(ShellJobLiveness.judge(younger, promptSeenAt: &seen, now: at(115)), .keep)
        XCTAssertEqual(ShellJobLiveness.judge(younger, promptSeenAt: &seen, now: at(120)), .keep, "a child the job started keeps it")
        XCTAssertFalse(ShellJobLiveness.probe(shell, children: [since], jobSince: since).hasChildren, "started at the begin: before the command")
    }
}
