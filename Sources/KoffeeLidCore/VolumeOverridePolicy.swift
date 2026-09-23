import Foundation

public struct VolumeSnapshot: Equatable {
    public var deviceID: UInt32
    public var volume: Float
    public var muted: Bool
    public init(deviceID: UInt32, volume: Float, muted: Bool) { self.deviceID = deviceID; self.volume = volume; self.muted = muted }
}

public enum VolumeAction: Equatable {
    case apply(deviceID: UInt32, volume: Float, unmute: Bool)
    case restore(VolumeSnapshot)
}

/// Decides what the CoreAudio layer should do around one lid-close sound playback. The speakers play at the set
/// volume; the output the user listens on plays at `listeningShare` of it, or at the user's own volume when that
/// is louder, so music in headphones rises a little for the sound and never to the speakers' level. Both are
/// unmuted: a Mac shut in a bag has to be heard staying awake.
public struct VolumeOverridePolicy {
    public static let listeningShare: Float = 0.5

    /// The volumes go back no later than this after a playback starts, whatever the audio system reports of
    /// the clip: its length, the speakers' wait behind a slower output, and a margin for the device to drain.
    public static let restoreMargin: TimeInterval = 1
    public static func restoreDeadline(clipSeconds: TimeInterval, speakersDelay: TimeInterval) -> TimeInterval {
        max(0, clipSeconds) + max(0, speakersDelay) + restoreMargin
    }

    public var enabled: Bool
    public var targetVolume: Float
    private var saved: [VolumeSnapshot] = []

    public var isOverriding: Bool { !saved.isEmpty }

    public init(enabled: Bool, targetVolume: Float) {
        self.enabled = enabled; self.targetVolume = targetVolume
    }

    public mutating func begin(speakers: VolumeSnapshot?, listening: VolumeSnapshot?) -> [VolumeAction] {
        guard enabled else { return [] }
        let target = min(1, max(0, targetVolume))
        var actions: [VolumeAction] = []
        if let s = speakers {
            saved.append(s)
            actions.append(.apply(deviceID: s.deviceID, volume: target, unmute: true))
        }
        if let l = listening {
            let share = target * Self.listeningShare
            if l.muted || l.volume < share {
                saved.append(l)
                actions.append(.apply(deviceID: l.deviceID, volume: l.muted ? share : max(l.volume, share), unmute: true))
            }
        }
        return actions
    }

    /// Begins an override only when none is in flight. Overlapping playbacks keep the first
    /// snapshots so the single restore still returns the volumes the user actually had.
    public mutating func beginIfNeeded(speakers: VolumeSnapshot?, listening: VolumeSnapshot?) -> [VolumeAction] {
        guard !isOverriding else { return [] }
        return begin(speakers: speakers, listening: listening)
    }

    public mutating func playbackFinished() -> [VolumeAction] { takeRestore() }
    public mutating func defaultDeviceChanged() -> [VolumeAction] { takeRestore() }

    private mutating func takeRestore() -> [VolumeAction] {
        let restores = saved.map(VolumeAction.restore)
        saved = []
        return restores
    }
}
