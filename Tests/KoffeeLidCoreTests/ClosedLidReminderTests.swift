import XCTest
import KoffeeLidCore

final class ClosedLidReminderTests: XCTestCase {
    private let everythingOn = ClosedLidReminder.Switches(chargerUnplugged: true, displaysChanged: true)

    private func onAC(_ r: inout ClosedLidReminder) { _ = r.powerSource(BatteryState(percent: 80, onBattery: false)) }

    // MARK: the charger

    func testTheChargerGoingAwayIsAnUnplug() {
        var r = ClosedLidReminder()
        onAC(&r)
        XCTAssertTrue(r.powerSource(BatteryState(percent: 80, onBattery: true)))
    }

    /// Power-source notifications also arrive at every change of charge: only the switch to battery counts.
    func testAChargeTickOnBatteryIsNotAnUnplug() {
        var r = ClosedLidReminder()
        onAC(&r)
        XCTAssertTrue(r.powerSource(BatteryState(percent: 80, onBattery: true)))
        XCTAssertFalse(r.powerSource(BatteryState(percent: 79, onBattery: true)))
        XCTAssertFalse(r.powerSource(BatteryState(percent: 78, onBattery: true)))
    }

    func testPluggingInIsNotAnUnplug() {
        var r = ClosedLidReminder()
        _ = r.powerSource(BatteryState(percent: 50, onBattery: true))
        XCTAssertFalse(r.powerSource(BatteryState(percent: 50, onBattery: false)))
    }

    /// The first reading has nothing to compare with, and a missing reading is not a charger going away.
    func testAnUnknownPreviousStateIsNotAnUnplug() {
        var r = ClosedLidReminder()
        XCTAssertFalse(r.powerSource(BatteryState(percent: 50, onBattery: true)))
        var s = ClosedLidReminder()
        onAC(&s)
        XCTAssertFalse(s.powerSource(nil))
        XCTAssertFalse(s.powerSource(BatteryState(percent: 50, onBattery: true)))
    }

    // MARK: when it plays

    func testPlaysOnlyWhileArmedWithTheLidClosed() {
        var r = ClosedLidReminder()
        XCTAssertFalse(r.shouldPlay(.chargerUnplugged, armed: false, lidClosed: true, switches: everythingOn, now: 100))
        XCTAssertFalse(r.shouldPlay(.chargerUnplugged, armed: true, lidClosed: false, switches: everythingOn, now: 200))
        XCTAssertTrue(r.shouldPlay(.chargerUnplugged, armed: true, lidClosed: true, switches: everythingOn, now: 300))
    }

    func testEachTriggerHasItsOwnSwitch() {
        var r = ClosedLidReminder()
        let noCharger = ClosedLidReminder.Switches(chargerUnplugged: false, displaysChanged: true)
        let noDisplays = ClosedLidReminder.Switches(chargerUnplugged: true, displaysChanged: false)
        XCTAssertFalse(r.shouldPlay(.chargerUnplugged, armed: true, lidClosed: true, switches: noCharger, now: 100))
        XCTAssertFalse(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: noDisplays, now: 200))
        XCTAssertTrue(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: noCharger, now: 300))
        XCTAssertTrue(r.shouldPlay(.chargerUnplugged, armed: true, lidClosed: true, switches: noDisplays, now: 400))
    }

    /// A dock unplugged with two displays on it: two display changes then the charger, within about a second.
    func testADockUnplugPlaysOnce() {
        var r = ClosedLidReminder()
        r.lidClosed(now: 0)
        XCTAssertTrue(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: everythingOn, now: 5000.00))
        XCTAssertFalse(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: everythingOn, now: 5000.24))
        XCTAssertFalse(r.shouldPlay(.chargerUnplugged, armed: true, lidClosed: true, switches: everythingOn, now: 5001.12))
    }

    func testPlaysAgainOnceTheQuietWindowHasPassed() {
        var r = ClosedLidReminder()
        XCTAssertTrue(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: everythingOn, now: 100))
        XCTAssertFalse(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: everythingOn,
                                    now: 100 + ClosedLidReminder.quietSeconds - 0.01))
        XCTAssertTrue(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: everythingOn,
                                   now: 100 + ClosedLidReminder.quietSeconds))
    }

    /// A refused trigger does not start a quiet window of its own.
    func testARefusedTriggerDoesNotSilenceTheNextOne() {
        var r = ClosedLidReminder()
        XCTAssertFalse(r.shouldPlay(.displaysChanged, armed: false, lidClosed: true, switches: everythingOn, now: 100))
        XCTAssertTrue(r.shouldPlay(.chargerUnplugged, armed: true, lidClosed: true, switches: everythingOn, now: 100.5))
    }

    /// The lid-close sound has just played: an unplug right behind it is the same moment.
    func testTheLidCloseSoundCountsAsTheLastSound() {
        var r = ClosedLidReminder()
        r.lidClosed(now: 100)
        r.soundPlayed(now: 100)
        XCTAssertFalse(r.shouldPlay(.chargerUnplugged, armed: true, lidClosed: true, switches: everythingOn, now: 102))
    }

    /// Closing the lid on an external display rearranges the displays: that is the close, not an unplug.
    func testTheDisplaysRearrangingAfterTheLidClosesDoNotPlay() {
        var r = ClosedLidReminder()
        r.lidClosed(now: 100)
        XCTAssertFalse(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: everythingOn, now: 101))
        XCTAssertFalse(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: everythingOn,
                                    now: 100 + ClosedLidReminder.lidCloseSettleSeconds - 0.01))
        XCTAssertTrue(r.shouldPlay(.displaysChanged, armed: true, lidClosed: true, switches: everythingOn,
                                   now: 100 + ClosedLidReminder.lidCloseSettleSeconds))
    }

    /// The charger is a physical act even right after the close (the lid-close sound stands by on an external display).
    func testTheChargerRightAfterTheLidClosesPlays() {
        var r = ClosedLidReminder()
        r.lidClosed(now: 100)
        XCTAssertTrue(r.shouldPlay(.chargerUnplugged, armed: true, lidClosed: true, switches: everythingOn, now: 101))
    }
}
