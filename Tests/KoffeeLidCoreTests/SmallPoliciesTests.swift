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
        XCTAssertEqual(s, "t=$(mktemp) && printf '%s\\n' 'rubens ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0' > \"$t\" && chmod 0440 \"$t\" && visudo -cf \"$t\" && mv \"$t\" /etc/sudoers.d/koffeelid")
        XCTAssertEqual(SleepLockSetup.privilegedRemoveScript, "rm -f /etc/sudoers.d/koffeelid")
    }
    func testAppleScriptLiteralEscaping() {
        XCTAssertEqual(SleepLockSetup.appleScriptLiteral("printf '%s\\n' \"a\""), "\"printf '%s\\\\n' \\\"a\\\"\"")
    }
}
