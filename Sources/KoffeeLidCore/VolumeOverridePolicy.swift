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
    case none
}

/// Decides what the CoreAudio layer should do around one lid-close sound playback.
public struct VolumeOverridePolicy {
    public var enabled: Bool
    public var targetVolume: Float
    private var saved: VolumeSnapshot?

    public var isOverriding: Bool { saved != nil }

    public init(enabled: Bool, targetVolume: Float) {
        self.enabled = enabled; self.targetVolume = targetVolume
    }

    public mutating func begin(snapshot: VolumeSnapshot?) -> VolumeAction {
        guard enabled, let s = snapshot else { return .none }
        saved = s
        return .apply(deviceID: s.deviceID, volume: min(1, max(0, targetVolume)), unmute: true)
    }

    /// Begins an override only when none is in flight. Overlapping playbacks keep the first
    /// snapshot so the single restore still returns the volume the user actually had.
    public mutating func beginIfNeeded(snapshot: VolumeSnapshot?) -> VolumeAction {
        guard !isOverriding else { return .none }
        return begin(snapshot: snapshot)
    }

    public mutating func playbackFinished() -> VolumeAction { takeRestore() }
    public mutating func defaultDeviceChanged() -> VolumeAction { takeRestore() }

    private mutating func takeRestore() -> VolumeAction {
        guard let s = saved else { return .none }
        saved = nil
        return .restore(s)
    }
}
