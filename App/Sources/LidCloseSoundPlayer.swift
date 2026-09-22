import AVFoundation
import CoreAudio
import AudioToolbox
import KoffeeLidCore

/// Plays the lid-close sound on the Mac's speakers, and also on the output the user listens on when that is
/// something else (`LidSoundRoute`), at the volumes `VolumeOverridePolicy` decides.
final class LidCloseSoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let soundNames = ["blip-pop", "bloop", "chime-blip", "enter", "notification", "tick"]
    private let prefs: Preferences
    private let volume: OutputVolumeOverride
    /// The default output, when it is not the speakers.
    private var listeningPlayer: AVAudioPlayer?
    /// The speakers, pinned to their device whatever the default output is.
    private var speakersEngine: AVAudioEngine?
    private var policy: VolumeOverridePolicy?
    /// Identifies the current playback; callbacks from a stopped one carry an older number and are ignored.
    private var generation = 0
    private var sounding = 0
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
        let route = LidSoundRoute.plan(defaultOutput: volume.defaultOutput(), speakers: volume.speakers())
        // Overlapping playback (a preview on top of a lid close): the current snapshots were taken before the
        // volumes were forced, so they are the only ones worth restoring, once, when the new playback ends.
        stopOutputs()
        if policy?.isOverriding != true {
            var pol = VolumeOverridePolicy(enabled: prefs.forceVolumeEnabled, targetVolume: prefs.forceVolumeLevel)
            if prefs.forceVolumeEnabled {
                volume.perform(pol.beginIfNeeded(speakers: route.speakers.flatMap(volume.snapshot),
                                                 listening: route.listening.flatMap(volume.snapshot)))
            }
            if pol.isOverriding { volume.startListening() }
            policy = pol
        }
        generation += 1; sounding = 0
        var delay: TimeInterval = 0
        if let s = route.speakers, let l = route.listening {
            delay = LidSoundRoute.speakersDelay(listeningLatency: volume.latency(of: l), speakersLatency: volume.latency(of: s))
        }
        let onSpeakers = route.speakers.map { startSpeakers(url, device: $0, delay: delay) } ?? false
        if route.listening != nil || !onSpeakers { startDefaultOutput(url) }
        onLog?("lid-close sound: \(onSpeakers ? "speakers" : "no speakers")"
               + (route.listening.map { ", device \($0)" } ?? "")
               + (onSpeakers && delay > 0 ? ", speakers delayed \(Int((delay * 1000).rounded())) ms" : ""))
        if sounding == 0 { finish() }
    }

    func preview(named name: String) { play(named: name) }

    private func startSpeakers(_ url: URL, device: AudioDeviceID, delay: TimeInterval) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            guard let unit = engine.outputNode.audioUnit else { onLog?("lid-close sound: speakers unavailable (no output unit)"); return false }
            var dev = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { onLog?("lid-close sound: speakers unavailable (\(status))"); return false }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            let gen = generation
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.outputFinished(generation: gen) }
            }
            try engine.start()
            let start = delay > 0 ? AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay)) : nil
            node.play(at: start)
            speakersEngine = engine; sounding += 1
            return true
        } catch {
            onLog?("lid-close sound: speakers unavailable (\(error.localizedDescription))"); return false
        }
    }

    private func startDefaultOutput(_ url: URL) {
        do {
            let p = try AVAudioPlayer(contentsOf: url); p.delegate = self
            p.prepareToPlay(); p.play()
            listeningPlayer = p; sounding += 1
        } catch { onLog?("lid-close sound unavailable (\(error.localizedDescription))") }
    }

    /// Neither stop reports a finish: a stopped player calls no delegate, and a stopped node's completion
    /// carries an older generation.
    private func stopOutputs() {
        listeningPlayer?.stop(); listeningPlayer = nil
        speakersEngine?.stop(); speakersEngine = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === listeningPlayer { outputFinished(generation: generation) }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if player === listeningPlayer { outputFinished(generation: generation) }
    }

    private func outputFinished(generation gen: Int) {
        guard gen == generation else { return }
        sounding -= 1
        if sounding <= 0 { finish() }
    }

    private func finish() {
        let gen = generation
        // small tail so the device does not clip the last samples when volume snaps back
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, gen == self.generation else { return }
            if var p = self.policy { self.volume.perform(p.playbackFinished()) }
            self.policy = nil
            self.volume.stopListening(); self.stopOutputs()
        }
    }
}
