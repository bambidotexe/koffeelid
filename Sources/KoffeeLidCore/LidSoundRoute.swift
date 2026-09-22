import Foundation

/// What an output device is to the lid-close sound.
public enum SoundOutputKind: Equatable {
    /// The Mac's own speakers.
    case speakers
    /// A built-in output that is not the speakers: headphones in the jack.
    case builtInOther
    /// Everything else: Bluetooth (AirPods), USB, AirPlay, a display.
    case external
}

public struct SoundOutput: Equatable {
    public var deviceID: UInt32
    public var kind: SoundOutputKind
    public init(deviceID: UInt32, kind: SoundOutputKind) { self.deviceID = deviceID; self.kind = kind }
}

/// Where the lid-close sound plays: always on the Mac's speakers when they can be heard, and also on whatever
/// the user listens on when that is something else.
public struct LidSoundRoute: Equatable {
    /// The Mac's speakers, played at the set volume.
    public var speakers: UInt32?
    /// The default output when it is not the speakers, played at a share of the set volume.
    public var listening: UInt32?

    public init(speakers: UInt32?, listening: UInt32?) { self.speakers = speakers; self.listening = listening }

    /// Headphones in the jack silence the speakers, so the sound plays only in them.
    public static func plan(defaultOutput: SoundOutput?, speakers: UInt32?) -> LidSoundRoute {
        guard let output = defaultOutput else { return LidSoundRoute(speakers: speakers, listening: nil) }
        switch output.kind {
        case .speakers: return LidSoundRoute(speakers: output.deviceID, listening: nil)
        case .builtInOther: return LidSoundRoute(speakers: nil, listening: output.deviceID)
        case .external: return LidSoundRoute(speakers: speakers, listening: output.deviceID)
        }
    }

    /// The longest the speakers wait for a slower output; a device reporting more is misreporting.
    public static let maximumAlignment: TimeInterval = 0.5

    /// How long the speakers wait so both outputs are heard together: the listening output's latency beyond
    /// the speakers' own (AirPods report about 160 ms, the speakers about 2 ms).
    public static func speakersDelay(listeningLatency: TimeInterval, speakersLatency: TimeInterval) -> TimeInterval {
        min(maximumAlignment, max(0, listeningLatency - speakersLatency))
    }
}
