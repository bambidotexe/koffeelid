import XCTest
import KoffeeLidCore

final class SettingsStatusTests: XCTestCase {
    private func grants(_ held: SettingsGrant...) -> Set<SettingsGrant> { Set(held) }

    // MARK: One rule for every grant

    func testEveryGrantIsGreenOnceThere() {
        for grant in SettingsGrant.allCases {
            XCTAssertEqual(SettingsStatus.severity(of: grant, held: grants(grant)), .good, grant.rawValue)
        }
    }
    func testOnlyTheSleepLockAndBackgroundAppActivityAreRequired() {
        XCTAssertEqual(SettingsGrant.allCases.filter(\.isRequired), [.sleepLock, .loginItems])
    }
    func testAMissingRequiredGrantIsRed() {
        XCTAssertEqual(SettingsStatus.severity(of: .sleepLock, held: []), .failure)
        XCTAssertEqual(SettingsStatus.severity(of: .loginItems, held: grants(.sleepLock)), .failure)
    }
    func testAMissingOptionalGrantIsOrangeAndNeverBlue() {
        for grant in [SettingsGrant.screenRecording, .inputMonitoring, .notifications, .claudeHooks, .codexHooks,
                     .copilotHooks, .opencodeHooks, .zshHook] {
            XCTAssertEqual(SettingsStatus.severity(of: grant, held: []), .warning, grant.rawValue)
        }
    }
    func testTheSettingsPagesAndTheHealthPageAgree() {
        for grant in SettingsGrant.allCases {
            for held in [grants(), grants(grant)] {
                XCTAssertEqual(SettingsStatus.severity(of: grant, held: held),
                               StatusSeverity(HealthRules.grant(held: held.contains(grant), required: grant.isRequired)))
            }
        }
    }

    // MARK: Auto-arm with nothing to listen to

    func testAutoArmIsDeafOnlyWhenOnWithNoHookAtAll() {
        XCTAssertTrue(SettingsStatus.autoArmIsDeaf(held: [], autoArmEnabled: true))
        XCTAssertTrue(SettingsStatus.autoArmIsDeaf(held: grants(.sleepLock, .notifications), autoArmEnabled: true))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: [], autoArmEnabled: false))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: grants(.claudeHooks), autoArmEnabled: true))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: grants(.codexHooks), autoArmEnabled: true))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: grants(.copilotHooks), autoArmEnabled: true))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: grants(.opencodeHooks), autoArmEnabled: true))
        XCTAssertFalse(SettingsStatus.autoArmIsDeaf(held: grants(.zshHook), autoArmEnabled: true))
    }
}
