import Foundation
import CoreAudio
import AudioToolbox
import KoffeeLidCore

/// The output devices the lid-close sound plays on, their volume and mute, and their latency.
final class OutputVolumeOverride {
    var onLog: ((String) -> Void)?
    var onDefaultDeviceChanged: (() -> Void)?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// The data source a built-in output reports while it is the internal speakers (`kIOAudioOutputPortSubTypeInternalSpeaker`).
    private static let internalSpeakerSource: UInt32 = 0x6973_706B // 'ispk'

    private var defaultDeviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private let muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                         mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    /// Reads a UInt32-sized property (a device or stream id, a frame count, a four-char code).
    private func read(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope, _ value: inout UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
    }
    private func read(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope, _ value: inout Float64) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
    }

    private func kind(of dev: AudioDeviceID) -> SoundOutputKind {
        var transport: UInt32 = 0
        guard read(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport),
              transport == kAudioDeviceTransportTypeBuiltIn else { return .external }
        var source: UInt32 = 0
        return read(dev, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, &source)
            && source == Self.internalSpeakerSource ? .speakers : .builtInOther
    }

    private func hasOutputStreams(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr && size > 0
    }

    func defaultOutput() -> SoundOutput? {
        var id = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                   kAudioObjectPropertyScopeGlobal, &id), id != 0 else { return nil }
        return SoundOutput(deviceID: id, kind: kind(of: id))
    }

    /// The Mac's speakers, whether or not they are the default output; nil while headphones in the jack silence them.
    func speakers() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { hasOutputStreams($0) && kind(of: $0) == .speakers }
    }

    /// Seconds between a sample handed to the device and the sound leaving it: the device's latency, its safety
    /// offset and its first output stream's latency.
    func latency(of dev: AudioDeviceID) -> TimeInterval {
        var rate: Float64 = 0
        guard read(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate), rate > 0 else { return 0 }
        var device: UInt32 = 0, safety: UInt32 = 0, stream: UInt32 = 0
        _ = read(dev, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput, &device)
        _ = read(dev, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput, &safety)
        var streams: AudioStreamID = 0
        if read(dev, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput, &streams), streams != 0 {
            _ = read(streams, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &stream)
        }
        return TimeInterval(device + safety + stream) / rate
    }

    func snapshot(_ dev: AudioDeviceID) -> VolumeSnapshot? {
        var vAddr = volumeAddress; var mAddr = muteAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &vAddr), AudioObjectIsPropertySettable(dev, &vAddr, &settable) == noErr, settable.boolValue else {
            onLog?("volume override: output device \(dev) has no software volume; playing at current level"); return nil
        }
        guard let volume = readVolume(dev) else { return nil }
        var muted: UInt32 = 0; var mSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(dev, &mAddr) { _ = AudioObjectGetPropertyData(dev, &mAddr, 0, nil, &mSize, &muted) }
        return VolumeSnapshot(deviceID: dev, volume: volume, muted: muted != 0)
    }

    private func readVolume(_ dev: AudioDeviceID) -> Float? {
        var addr = volumeAddress
        var volume: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    func perform(_ actions: [VolumeAction]) {
        for action in actions {
            switch action {
            case .apply(let dev, let volume, let unmute):
                setVolume(dev, volume); if unmute { setMute(dev, false) }
                onLog?("volume override: forced \(Int((volume * 100).rounded()))% (unmuted) on device \(dev)")
            case .restore(let s):
                setVolume(s.deviceID, s.volume); setMute(s.deviceID, s.muted)
                onLog?("volume override: restored \(Int((s.volume * 100).rounded()))%\(s.muted ? " muted" : "") on device \(s.deviceID)")
                // A device that keeps its own volume steps may not hold the exact value written back: say so.
                if let held = readVolume(s.deviceID), abs(held - s.volume) > 0.005 {
                    onLog?("volume override: device \(s.deviceID) holds \(Int((held * 100).rounded()))% after the restore")
                }
            }
        }
    }

    private func setVolume(_ dev: AudioDeviceID, _ v: Float) {
        var addr = volumeAddress; var value = Float32(v)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
    private func setMute(_ dev: AudioDeviceID, _ muted: Bool) {
        var addr = muteAddress; guard AudioObjectHasProperty(dev, &addr) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func startListening() {
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onDefaultDeviceChanged?() }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main, block)
    }
    func stopListening() {
        guard let b = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main, b)
        listenerBlock = nil
    }
}
