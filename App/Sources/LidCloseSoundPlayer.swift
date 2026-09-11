import AVFoundation
import KoffeeLidCore

final class LidCloseSoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let soundNames = ["blip-pop", "bloop", "chime-blip", "enter", "notification", "tick"]
    private let prefs: Preferences
    private let volume: OutputVolumeOverride
    private var player: AVAudioPlayer?
    private var policy: VolumeOverridePolicy?
    var onLog: ((String) -> Void)?

    init(prefs: Preferences, volume: OutputVolumeOverride) {
        self.prefs = prefs; self.volume = volume
        super.init()
        volume.onDefaultDeviceChanged = { [weak self] in
            guard let self, var p = self.policy else { return }
            self.volume.perform(p.defaultDeviceChanged()); self.policy = p
        }
    }

    func play(named name: String? = nil) {
        let chosen = name ?? prefs.lidCloseSoundName
        guard let url = Bundle.main.url(forResource: "close-sound-\(chosen)", withExtension: "mp3", subdirectory: "Sounds")
                ?? Bundle.main.url(forResource: "close-sound-\(chosen)", withExtension: "mp3") else {
            onLog?("lid-close sound unavailable (\(chosen))"); return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url); p.delegate = self
            if policy?.isOverriding == true {
                // Overlapping playback (a preview on top of a lid close): the current
                // snapshot was taken before the volume was forced, so it is the only one
                // worth restoring. stop() fires no delegate callback, so the single
                // restore still happens when the new player finishes.
                player?.stop()
            } else {
                var pol = VolumeOverridePolicy(enabled: prefs.forceVolumeEnabled, targetVolume: prefs.forceVolumeLevel)
                let action = pol.beginIfNeeded(snapshot: prefs.forceVolumeEnabled ? volume.snapshotDefaultOutput() : nil)
                volume.perform(action)
                if pol.isOverriding { volume.startListening() }
                policy = pol
            }
            player = p
            p.prepareToPlay(); p.play()
        } catch { onLog?("lid-close sound unavailable (\(error.localizedDescription))") }
    }

    func preview(named name: String) { play(named: name) }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finish() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { finish() }

    private func finish() {
        // small tail so the device does not clip the last samples when volume snaps back
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, var p = self.policy else { return }
            self.volume.perform(p.playbackFinished()); self.policy = nil
            self.volume.stopListening(); self.player = nil
        }
    }
}
