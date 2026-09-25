import XCTest
import KoffeeLidCore

/// The badges on the auto-armed cup: which app stands for each kind of running work, and which badges the
/// cup wears through a stretch of the auto level.
final class ActivityBadgesTests: XCTestCase {
    typealias P = ProcWalk.ProcInfo
    let terminalPath = "/System/Applications/Utilities/Terminal.app"
    let codePath = "/Applications/Visual Studio Code.app"

    func testAShellUnderTerminalIsHostedByTerminal() {
        let chain = [P(pid: 4, ppid: 3, name: "zsh", path: "/bin/zsh"),
                     P(pid: 3, ppid: 2, name: "login", path: "/usr/bin/login"),
                     P(pid: 2, ppid: 1, name: "Terminal", path: terminalPath + "/Contents/MacOS/Terminal"),
                     P(pid: 1, ppid: 0, name: "launchd", path: "/sbin/launchd")]
        XCTAssertEqual(ProcWalk.hostApplicationPath(in: chain), terminalPath)
    }
    func testAHelperInsideAnAppNamesTheOuterApp() {
        let helper = codePath + "/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let chain = [P(pid: 4, ppid: 3, name: "zsh", path: "/bin/zsh"),
                     P(pid: 3, ppid: 2, name: "Code Helper", path: helper),
                     P(pid: 2, ppid: 1, name: "Electron", path: codePath + "/Contents/MacOS/Electron")]
        XCTAssertEqual(ProcWalk.hostApplicationPath(in: chain), codePath)
    }
    func testTheNearestAppWins() {
        let chain = [P(pid: 5, ppid: 4, name: "zsh", path: "/bin/zsh"),
                     P(pid: 4, ppid: 3, name: "Electron", path: codePath + "/Contents/MacOS/Electron"),
                     P(pid: 3, ppid: 2, name: "zsh", path: "/bin/zsh"),
                     P(pid: 2, ppid: 1, name: "Terminal", path: terminalPath + "/Contents/MacOS/Terminal")]
        XCTAssertEqual(ProcWalk.hostApplicationPath(in: chain), codePath)
    }
    func testAChainWithNoAppHasNoHost() {
        let chain = [P(pid: 4, ppid: 3, name: "zsh", path: "/bin/zsh"),
                     P(pid: 3, ppid: 2, name: "sshd", path: "/usr/sbin/sshd-session"),
                     P(pid: 2, ppid: 1, name: "sshd", path: nil),
                     P(pid: 1, ppid: 0, name: "launchd", path: "/sbin/launchd")]
        XCTAssertNil(ProcWalk.hostApplicationPath(in: chain))
        XCTAssertNil(ProcWalk.hostApplicationPath(in: []))
    }
    func testACommandsBadgeIsItsHostOrTerminal() {
        let hosted = [P(pid: 4, ppid: 3, name: "zsh", path: "/bin/zsh"),
                      P(pid: 3, ppid: 2, name: "Electron", path: codePath + "/Contents/MacOS/Electron")]
        XCTAssertEqual(ActivityBadge.terminal(hosting: hosted), ActivityBadge(kind: .terminal, app: .bundlePath(codePath)))
        XCTAssertEqual(ActivityBadge.terminal(hosting: []), .terminal)
        XCTAssertEqual(ActivityBadge.terminal.app, .bundleIdentifier("com.apple.Terminal"))
    }
    func testTheDesktopAppsStandForTheAgents() {
        XCTAssertEqual(ActivityBadge.claude, ActivityBadge(kind: .claude, app: .bundleIdentifier("com.anthropic.claudefordesktop")))
        XCTAssertEqual(ActivityBadge.codex, ActivityBadge(kind: .codex, app: .bundleIdentifier("com.openai.codex")))
    }
    func testBadgesSortClaudeCodeFirstThenCodexThenTheTerminalsByPath() {
        let code = ActivityBadge(kind: .terminal, app: .bundlePath(codePath))
        let terminal = ActivityBadge(kind: .terminal, app: .bundlePath(terminalPath))
        XCTAssertEqual([terminal, code, ActivityBadge.codex, ActivityBadge.claude].sorted(), [.claude, .codex, code, terminal])
    }

    func testTheCupWearsNothingWhileTheLevelIsOff() {
        var b = AutoArmBadges()
        b.update(running: [.claude], levelOn: false)
        XCTAssertEqual(b.badges, [])
    }
    func testTheBadgesAreTheAppsAtWorkKeptThroughTheHoldOff() {
        var b = AutoArmBadges()
        b.update(running: [.claude], levelOn: true)
        XCTAssertEqual(b.badges, [.claude])
        b.update(running: [], levelOn: true)
        XCTAssertEqual(b.badges, [.claude], "the hold-off keeps what last ran")
        b.update(running: [.terminal], levelOn: true)
        XCTAssertEqual(b.badges, [.terminal], "a command during the hold-off: only its app")
        b.update(running: [], levelOn: false)
        XCTAssertEqual(b.badges, [], "the level dropped")
    }
    func testAnAppThatStopsWhileAnotherRunsLosesItsBadge() {
        var b = AutoArmBadges()
        b.update(running: [.claude, .terminal], levelOn: true)
        XCTAssertEqual(b.badges, [.claude, .terminal])
        b.update(running: [.terminal], levelOn: true)
        XCTAssertEqual(b.badges, [.terminal], "the turn was interrupted, the command goes on")
    }
    func testANewStretchStartsFromScratch() {
        var b = AutoArmBadges()
        b.update(running: [.claude], levelOn: true)
        b.update(running: [], levelOn: false)
        b.update(running: [.codex], levelOn: true)
        XCTAssertEqual(b.badges, [.codex])
    }
    func testAtMostThreeBadgesAreShownFrontToBack() {
        var b = AutoArmBadges()
        let code = ActivityBadge(kind: .terminal, app: .bundlePath(codePath))
        let terminal = ActivityBadge(kind: .terminal, app: .bundlePath(terminalPath))
        b.update(running: [terminal, code, .codex, .claude], levelOn: true)
        XCTAssertEqual(b.badges, [.claude, .codex, code, terminal])
        XCTAssertEqual(b.shown, [.claude, .codex, code])
        XCTAssertEqual(AutoArmBadges.maxShown, 3)
    }
}
