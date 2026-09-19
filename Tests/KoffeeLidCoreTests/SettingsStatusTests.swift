import XCTest
import KoffeeLidCore

final class SettingsStatusTests: XCTestCase {
    private func context(effect: Bool = false, gesture: Bool = false, fn: Bool = true, autoArm: Bool = false) -> SettingsContext {
        SettingsContext(effectEnabled: effect, gestureEnabled: gesture, gestureUsesFn: fn, autoArmEnabled: autoArm)
    }
    private func grants(_ held: SettingsGrant...) -> Set<SettingsGrant> { Set(held) }

    // MARK: What must always be there

    func testSleepLockAndLoginItemsAreGreenOnceThere() {
        let held = grants(.sleepLock, .loginItems)
        XCTAssertEqual(SettingsStatus.severity(of: .sleepLock, held: held, context: context()), .good)
        XCTAssertEqual(SettingsStatus.severity(of: .loginItems, held: held, context: context()), .good)
    }
    func testSleepLockAndLoginItemsAreToFixWhateverTheSettings() {
        XCTAssertEqual(SettingsStatus.severity(of: .sleepLock, held: [], context: context()), .warning)
        XCTAssertEqual(SettingsStatus.severity(of: .loginItems, held: [], context: context(effect: true, gesture: true, autoArm: true)), .warning)
    }

    // MARK: Permissions

    func testGrantedPermissionIsGreen() {
        for grant in [SettingsGrant.screenRecording, .inputMonitoring, .notifications] {
            XCTAssertEqual(SettingsStatus.severity(of: grant, held: grants(grant), context: context()), .good)
        }
    }
    func testScreenRecordingIsRefusedOnlyWhileTheEffectIsOn() {
        XCTAssertEqual(SettingsStatus.severity(of: .screenRecording, held: [], context: context(effect: true)), .failure)
        XCTAssertEqual(SettingsStatus.severity(of: .screenRecording, held: [], context: context(effect: false)), .info)
    }
    func testInputMonitoringIsRefusedOnlyWhileTheGestureWatchesFn() {
        XCTAssertEqual(SettingsStatus.severity(of: .inputMonitoring, held: [], context: context(gesture: true, fn: true)), .failure)
        XCTAssertEqual(SettingsStatus.severity(of: .inputMonitoring, held: [], context: context(gesture: true, fn: false)), .info)
        XCTAssertEqual(SettingsStatus.severity(of: .inputMonitoring, held: [], context: context(gesture: false, fn: true)), .info)
    }
    func testNotificationsAreAlwaysWanted() {
        XCTAssertEqual(SettingsStatus.severity(of: .notifications, held: [], context: context()), .failure)
    }

    // MARK: Hooks

    func testEnabledHookIsGreen() {
        XCTAssertEqual(SettingsStatus.severity(of: .claudeHooks, held: grants(.claudeHooks), context: context(autoArm: false)), .good)
        XCTAssertEqual(SettingsStatus.severity(of: .zshHook, held: grants(.zshHook), context: context(autoArm: true)), .good)
    }
    func testMissingHookIsOnlyAFactWhileAutoArmIsOff() {
        XCTAssertEqual(SettingsStatus.severity(of: .claudeHooks, held: [], context: context(autoArm: false)), .info)
        XCTAssertEqual(SettingsStatus.severity(of: .zshHook, held: [], context: context(autoArm: false)), .info)
    }
    func testMissingHookIsOnlyAFactWhileTheOtherOneListens() {
        XCTAssertEqual(SettingsStatus.severity(of: .zshHook, held: grants(.claudeHooks), context: context(autoArm: true)), .info)
        XCTAssertEqual(SettingsStatus.severity(of: .claudeHooks, held: grants(.zshHook), context: context(autoArm: true)), .info)
    }
    func testBothHooksAreToFixWhileAutoArmHasNothingToListenTo() {
        XCTAssertEqual(SettingsStatus.severity(of: .claudeHooks, held: [], context: context(autoArm: true)), .warning)
        XCTAssertEqual(SettingsStatus.severity(of: .zshHook, held: [], context: context(autoArm: true)), .warning)
    }

    // MARK: Auto-arm with nothing to listen to

    func testAutoArmIsDeafOnlyWhenOnWithNoHookAtAll() {
        XCTAssertTrue(SettingsStatus.autoArmIsDeaf(held: [], context: context(autoArm: true)))
        XCTAssertTrue(SettingsStatus.autoArmIsDeaf(held: grants(.sleepLock, .notifications), context: context(autoArm: true)))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: [], context: context(autoArm: false)))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: grants(.claudeHooks), context: context(autoArm: true)))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: grants(.zshHook), context: context(autoArm: true)))
    }
}
