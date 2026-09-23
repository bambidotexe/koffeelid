import XCTest
import KoffeeLidCore

final class VolumeOverridePolicyTests: XCTestCase {
    let speakers = VolumeSnapshot(deviceID: 42, volume: 0.3, muted: true)

    func testDisabledDoesNothing() {
        var p = VolumeOverridePolicy(enabled: false, targetVolume: 0.8)
        XCTAssertEqual(p.begin(speakers: speakers, listening: nil), [])
        XCTAssertEqual(p.playbackFinished(), [])
    }
    func testSpeakersAppliesThenRestores() {
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.8)
        XCTAssertEqual(p.begin(speakers: speakers, listening: nil), [.apply(deviceID: 42, volume: 0.8, unmute: true)])
        XCTAssertTrue(p.isOverriding)
        XCTAssertEqual(p.playbackFinished(), [.restore(speakers)])
        XCTAssertFalse(p.isOverriding)
        XCTAssertEqual(p.playbackFinished(), [])
    }
    func testNoSnapshotSkips() {
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.8)
        XCTAssertEqual(p.begin(speakers: nil, listening: nil), [])
        XCTAssertFalse(p.isOverriding)
    }
    func testDeviceChangeRestoresEarly() {
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.5)
        _ = p.begin(speakers: speakers, listening: nil)
        XCTAssertEqual(p.defaultDeviceChanged(), [.restore(speakers)])
        XCTAssertEqual(p.playbackFinished(), [])
    }
    func testBeginWhileOverridingKeepsOriginalSnapshot() {
        let other = VolumeSnapshot(deviceID: 7, volume: 0.9, muted: false)
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.8)
        XCTAssertEqual(p.begin(speakers: speakers, listening: nil), [.apply(deviceID: 42, volume: 0.8, unmute: true)])
        XCTAssertEqual(p.beginIfNeeded(speakers: other, listening: nil), [])
        XCTAssertEqual(p.playbackFinished(), [.restore(speakers)])
        XCTAssertFalse(p.isOverriding)
    }
    func testTargetIsClamped() {
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 1.7)
        XCTAssertEqual(p.begin(speakers: speakers, listening: nil), [.apply(deviceID: 42, volume: 1.0, unmute: true)])
    }

    // The volumes go back on a deadline as well, in case the audio system never reports the end of the clip.

    func testRestoreDeadlineIsTheClipTheSpeakersWaitAndAMargin() {
        XCTAssertEqual(VolumeOverridePolicy.restoreDeadline(clipSeconds: 1.88, speakersDelay: 0.143),
                       1.88 + 0.143 + VolumeOverridePolicy.restoreMargin, accuracy: 0.0001)
        XCTAssertEqual(VolumeOverridePolicy.restoreDeadline(clipSeconds: 0, speakersDelay: 0), VolumeOverridePolicy.restoreMargin)
    }
    func testRestoreDeadlineIgnoresNegativeInputs() {
        XCTAssertEqual(VolumeOverridePolicy.restoreDeadline(clipSeconds: -1, speakersDelay: -1), VolumeOverridePolicy.restoreMargin)
    }

    // The output the user listens on: half the set volume, raised only.

    func testQuietHeadphonesRiseToHalfTheSetVolume() {
        let airpods = VolumeSnapshot(deviceID: 84, volume: 0.15, muted: false)
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.6)
        let actions = p.begin(speakers: speakers, listening: airpods)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0], .apply(deviceID: 42, volume: 0.6, unmute: true))
        guard case .apply(84, let volume, true) = actions[1] else { return XCTFail("\(actions[1])") }
        XCTAssertEqual(volume, 0.3, accuracy: 0.0001)
        XCTAssertEqual(p.playbackFinished(), [.restore(speakers), .restore(airpods)])
    }
    func testLouderHeadphonesAreLeftAlone() {
        let airpods = VolumeSnapshot(deviceID: 84, volume: 0.45, muted: false)
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.6)
        XCTAssertEqual(p.begin(speakers: speakers, listening: airpods), [.apply(deviceID: 42, volume: 0.6, unmute: true)])
        XCTAssertEqual(p.playbackFinished(), [.restore(speakers)])
    }
    func testMutedHeadphonesAreUnmutedAtHalfNotAtTheirOwnVolume() {
        let airpods = VolumeSnapshot(deviceID: 84, volume: 0.9, muted: true)
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.6)
        let actions = p.begin(speakers: nil, listening: airpods)
        guard actions.count == 1, case .apply(84, let volume, true) = actions[0] else { return XCTFail("\(actions)") }
        XCTAssertEqual(volume, 0.3, accuracy: 0.0001)
        XCTAssertEqual(p.playbackFinished(), [.restore(airpods)])
    }
    func testHeadphonesAloneAreStillAnOverride() {
        let jack = VolumeSnapshot(deviceID: 9, volume: 0.1, muted: false)
        var p = VolumeOverridePolicy(enabled: true, targetVolume: 0.6)
        XCTAssertEqual(p.begin(speakers: nil, listening: jack).count, 1)
        XCTAssertTrue(p.isOverriding)
    }
}

final class LidSoundRouteTests: XCTestCase {
    func testSpeakersAsDefaultPlayOnce() {
        XCTAssertEqual(LidSoundRoute.plan(defaultOutput: SoundOutput(deviceID: 70, kind: .speakers), speakers: 70),
                       LidSoundRoute(speakers: 70, listening: nil))
    }
    func testExternalOutputPlaysBesideTheSpeakers() {
        XCTAssertEqual(LidSoundRoute.plan(defaultOutput: SoundOutput(deviceID: 84, kind: .external), speakers: 70),
                       LidSoundRoute(speakers: 70, listening: 84))
    }
    func testJackHeadphonesPlayAlone() {
        XCTAssertEqual(LidSoundRoute.plan(defaultOutput: SoundOutput(deviceID: 9, kind: .builtInOther), speakers: 70),
                       LidSoundRoute(speakers: nil, listening: 9))
    }
    func testNoSpeakersLeavesTheDefault() {
        XCTAssertEqual(LidSoundRoute.plan(defaultOutput: SoundOutput(deviceID: 84, kind: .external), speakers: nil),
                       LidSoundRoute(speakers: nil, listening: 84))
    }
    func testNoDefaultStillPlaysOnTheSpeakers() {
        XCTAssertEqual(LidSoundRoute.plan(defaultOutput: nil, speakers: 70), LidSoundRoute(speakers: 70, listening: nil))
    }
    func testSpeakersWaitForTheSlowerOutput() {
        XCTAssertEqual(LidSoundRoute.speakersDelay(listeningLatency: 0.160, speakersLatency: 0.002), 0.158, accuracy: 0.0001)
        XCTAssertEqual(LidSoundRoute.speakersDelay(listeningLatency: 0.001, speakersLatency: 0.002), 0)
        XCTAssertEqual(LidSoundRoute.speakersDelay(listeningLatency: 3, speakersLatency: 0), LidSoundRoute.maximumAlignment)
    }
}
