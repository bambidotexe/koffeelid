import XCTest
import KoffeeLidCore

final class VolumeOverridePolicyTests: XCTestCase {
    let snap = VolumeSnapshot(deviceID: 42, volume: 0.3, muted: true)

    func testDisabledDoesNothing() {
        var p = VolumeOverridePolicy(enabled: false, targetVolume: 0.8)
        XCTAssertEqual(p.begin(snapshot: snap), .none)
        XCTAssertEqual(p.playbackFinished(), .none)
    }
    func testAppliesThenRestores() {
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.8)
        XCTAssertEqual(p.begin(snapshot: snap), .apply(deviceID: 42, volume: 0.8, unmute: true))
        XCTAssertTrue(p.isOverriding)
        XCTAssertEqual(p.playbackFinished(), .restore(snap))
        XCTAssertFalse(p.isOverriding)
        XCTAssertEqual(p.playbackFinished(), .none)
    }
    func testNilSnapshotSkips() {
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.8)
        XCTAssertEqual(p.begin(snapshot: nil), .none)
        XCTAssertFalse(p.isOverriding)
    }
    func testDeviceChangeRestoresEarly() {
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.5)
        _ = p.begin(snapshot: snap)
        XCTAssertEqual(p.defaultDeviceChanged(), .restore(snap))
        XCTAssertEqual(p.playbackFinished(), .none)
    }
    func testBeginWhileOverridingKeepsOriginalSnapshot() {
        let other = VolumeSnapshot(deviceID: 7, volume: 0.9, muted: false)
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.8)
        XCTAssertEqual(p.begin(snapshot: snap), .apply(deviceID: 42, volume: 0.8, unmute: true))
        XCTAssertEqual(p.beginIfNeeded(snapshot: other), .none)
        XCTAssertEqual(p.playbackFinished(), .restore(snap))
        XCTAssertFalse(p.isOverriding)
    }
    func testTargetIsClamped() {
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 1.7)
        XCTAssertEqual(p.begin(snapshot: snap), .apply(deviceID: 42, volume: 1.0, unmute: true))
    }
}
