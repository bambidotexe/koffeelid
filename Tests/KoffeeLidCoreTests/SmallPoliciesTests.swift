import XCTest
import KoffeeLidCore

final class SmallPoliciesTests: XCTestCase {
    func testLowBatteryPolicy() {
        let p = LowBatteryPolicy(enabled: true, thresholdPercent: 10)
        XCTAssertTrue(p.shouldDisarm(BatteryState(percent: 10, onBattery: true)))
        XCTAssertFalse(p.shouldDisarm(BatteryState(percent: 11, onBattery: true)))
        XCTAssertFalse(p.shouldDisarm(BatteryState(percent: 5, onBattery: false)))
        XCTAssertTrue(p.shouldDisarm(nil))      // battery info vanished: disarm (parity with original)
        XCTAssertFalse(LowBatteryPolicy(enabled: false, thresholdPercent: 10).shouldDisarm(nil))
    }
    func testLockRetryPolicy() {
        let p = LidReopenLockRetryPolicy(delays: [0.5, 1, 2])
        XCTAssertEqual(p.delay(forAttempt: 0), 0.5)
        XCTAssertEqual(p.delay(forAttempt: 2), 2)
        XCTAssertNil(p.delay(forAttempt: 3))
    }
    func testDiagnosticLineFormat() {
        let d = Date(timeIntervalSince1970: 1_789_073_249.271)
        XCTAssertEqual(DiagnosticLine.render(d, "armed"), "[2026-09-10T20:47:29.271Z] armed")
    }
    func testDeepLinkParsing() {
        XCTAssertEqual(DeepLink(url: URL(string: "koffeelid://arm")!), .arm)
        XCTAssertEqual(DeepLink(url: URL(string: "koffeelid://disarm")!), .off)
        XCTAssertEqual(DeepLink(url: URL(string: "koffeelid://off")!), .off)
        XCTAssertEqual(DeepLink(url: URL(string: "koffeelid://toggle")!), .toggleArmed)
        XCTAssertEqual(DeepLink(url: URL(string: "koffeelid:///toggle-armed")!), .toggleArmed)
        XCTAssertEqual(DeepLink(url: URL(string: "koffeelid://caffeinate")!), .caffeinate)
        XCTAssertEqual(DeepLink(url: URL(string: "koffeelid://Toggle-Caffeinate")!), .toggleCaffeinate)
        XCTAssertEqual(DeepLink(command: "status"), .status)
        XCTAssertEqual(DeepLink(command: "settings"), .settings)
        XCTAssertNil(DeepLink(command: "toggle-off"))
        XCTAssertNil(DeepLink(url: URL(string: "koffeelid://nope")!))
        XCTAssertNil(DeepLink(url: URL(string: "https://example.com/arm")!))
    }
}

final class SleepInterruptionTests: XCTestCase {
    func testClamshellReasonWithLidClosedIsAnOverride() {
        XCTAssertEqual(SleepInterruptionPolicy.classify(reason: "Clamshell Sleep", lidClosed: true), .lidSleepOverride)
    }
    func testAnythingElseIsExternal() {
        XCTAssertEqual(SleepInterruptionPolicy.classify(reason: "Clamshell Sleep", lidClosed: false), .external)
        XCTAssertEqual(SleepInterruptionPolicy.classify(reason: "Software Sleep", lidClosed: true), .external)
        XCTAssertEqual(SleepInterruptionPolicy.classify(reason: nil, lidClosed: true), .external)
    }
    func testOverrideGuardStopsHoldingAfterTooManyInWindow() {
        var g = SleepOverrideGuard(window: 120, maxOverrides: 3)
        XCTAssertTrue(g.record(now: 0))
        XCTAssertTrue(g.record(now: 10))
        XCTAssertTrue(g.record(now: 20))
        XCTAssertFalse(g.record(now: 30))     // fourth inside the window: give up the hold
        XCTAssertTrue(g.record(now: 200))     // everything before 80 aged out
    }
    func testSudoersRule() {
        XCTAssertEqual(SleepLockSetup.sudoersRule(user: "rubens"),
                       "rubens ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0")
        XCTAssertEqual(SleepLockSetup.pmsetArguments(engaged: true), ["/usr/bin/pmset", "disablesleep", "1"])
        XCTAssertEqual(SleepLockSetup.pmsetArguments(engaged: false), ["/usr/bin/pmset", "disablesleep", "0"])
    }
    func testPrivilegedInstallScriptValidatesBeforeInstalling() {
        let s = SleepLockSetup.privilegedInstallScript(user: "rubens")
        XCTAssertEqual(s, "t=$(/usr/bin/mktemp /etc/sudoers.d/.koffeelid.XXXXXX) && /usr/bin/printf '%s\\n' 'rubens ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0' > \"$t\" && /bin/chmod 0440 \"$t\" && /usr/sbin/visudo -cf \"$t\" && /bin/mv \"$t\" /etc/sudoers.d/koffeelid || { /bin/rm -f \"$t\"; false; }")
        XCTAssertEqual(SleepLockSetup.privilegedRemoveScript, "/bin/rm -f /etc/sudoers.d/koffeelid")
    }
    /// The script runs as root through the administrator dialog, so it trusts nothing around it: every tool by
    /// absolute path (PATH and TMPDIR can be set for later-launched apps by any same-user process), the temp
    /// file inside the root-only sudoers.d itself under a dotted name sudo ignores (no swap window between
    /// `visudo -cf` and the rename), and a failed validation removes the file and fails the script.
    func testPrivilegedInstallScriptTrustsNothingAroundIt() {
        let s = SleepLockSetup.privilegedInstallScript(user: "rubens")
        var stripped = s
        for absolute in ["/usr/bin/mktemp", "/usr/bin/printf", "/bin/chmod", "/usr/sbin/visudo", "/bin/mv", "/bin/rm"] {
            stripped = stripped.replacingOccurrences(of: absolute, with: "")
        }
        for tool in ["mktemp", "printf", "chmod", "visudo", "mv", "rm"] {
            XCTAssertFalse(stripped.contains(tool), "\(tool) must be called by absolute path")
        }
        XCTAssertTrue(s.contains("/usr/bin/mktemp /etc/sudoers.d/.koffeelid."), "the temp file must live in sudoers.d under a dotted name")
        XCTAssertTrue(s.hasSuffix("|| { /bin/rm -f \"$t\"; false; }"), "a failed validation must remove the temp file and fail")
    }
    func testAppleScriptLiteralEscaping() {
        XCTAssertEqual(SleepLockSetup.appleScriptLiteral("printf '%s\\n' \"a\""), "\"printf '%s\\\\n' \\\"a\\\"\"")
    }

    /// The account name is spliced into a single-quoted shell string run as root: only what a macOS short name
    /// can hold is accepted (belt and braces; the name is the running user's own).
    func testUserNameMustBeSafeToSpliceIntoTheShellScript() {
        for ok in ["rubens", "rubens.nunzi", "a-b_c", "User2"] { XCTAssertTrue(SleepLockSetup.isValidUserName(ok), ok) }
        for bad in ["", "rub'ens", "rub ens", "a/b", "a$(b)", "é", "a\nb"] { XCTAssertFalse(SleepLockSetup.isValidUserName(bad), bad) }
    }

    /// The terminal one-liner (install.sh, docs) must validate before the rule can be parsed: written under a
    /// dotted name sudo ignores, `visudo -cf`, then renamed. A malformed file in sudoers.d makes sudo refuse
    /// every command until someone repairs it.
    func testInstallCommandValidatesBeforeTheRuleIsLive() {
        XCTAssertEqual(SleepLockSetup.installCommand(user: "rubens"),
                       "echo \"rubens ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\" | sudo tee /etc/sudoers.d/koffeelid.tmp >/dev/null && sudo chmod 0440 /etc/sudoers.d/koffeelid.tmp && sudo visudo -cf /etc/sudoers.d/koffeelid.tmp && sudo mv /etc/sudoers.d/koffeelid.tmp /etc/sudoers.d/koffeelid")
    }
}
