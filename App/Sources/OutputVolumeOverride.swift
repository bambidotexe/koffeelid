import Foundation
import CoreAudio
import AudioToolbox
import KoffeeLidCore

final class OutputVolumeOverride {
    var onLog: ((String) -> Void)?
    var onDefaultDeviceChanged: (() -> Void)?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private var defaultDeviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private let muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                         mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    func snapshotDefaultOutput() -> VolumeSnapshot? {
        guard let dev = defaultOutputDevice() else { onLog?("volume override: no default output device"); return nil }
        var vAddr = volumeAddress; var mAddr = muteAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &vAddr), AudioObjectIsPropertySettable(dev, &vAddr, &settable) == noErr, settable.boolValue else {
            onLog?("volume override: output device has no software volume; playing at current level"); return nil
        }
        var volume: Float32 = 0; var vSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &vAddr, 0, nil, &vSize, &volume) == noErr else { return nil }
        var muted: UInt32 = 0; var mSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(dev, &mAddr) { _ = AudioObjectGetPropertyData(dev, &mAddr, 0, nil, &mSize, &muted) }
        return VolumeSnapshot(deviceID: dev, volume: volume, muted: muted != 0)
    }

    func perform(_ action: VolumeAction) {
        switch action {
        case .none: return
        case .apply(let dev, let volume, let unmute):
            setVolume(dev, volume); if unmute { setMute(dev, false) }
            onLog?("volume override: forced \(Int(volume * 100))% (unmuted)")
        case .restore(let s):
            setVolume(s.deviceID, s.volume); setMute(s.deviceID, s.muted)
            onLog?("volume override: restored \(Int(s.volume * 100))%\(s.muted ? " muted" : "")")
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
