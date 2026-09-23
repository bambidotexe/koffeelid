import SwiftUI

/// The one sound KoffeeLid makes, when it plays, and how loud.
struct SettingsSoundPage: View {
    @ObservedObject var model: SettingsModel

    /// The clip and the volume matter while any of the three switches plays the sound.
    private var soundOn: Bool {
        model.prefs.lidCloseSoundEnabled || model.prefs.chargerUnplugSoundEnabled || model.prefs.displayChangeSoundEnabled
    }

    /// The clips' names as the user reads them, in the order of `LidCloseSoundPlayer.soundNames`.
    private static let titles = [L("Blip pop"), L("Bloop"), L("Chime blip"), L("Enter"), L("Notification"), L("Tick")]

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Lid-close sound"),
                          hint: L("Plays while KoffeeLid is armed, so you hear that your Mac stays awake: when the lid closes, then, with the lid closed, when the charger is unplugged or the displays change. A display going to sleep or waking up can play it too.")) {
                ToggleRow(L("Play a sound when the lid closes"), isOn: model.binding(\.lidCloseSoundEnabled))
                ToggleRow(L("Play it when the charger is unplugged"), isOn: model.binding(\.chargerUnplugSoundEnabled))
                ToggleRow(L("Play it when the displays change"), isOn: model.binding(\.displayChangeSoundEnabled))
                PopUpRow(L("Sound"), options: LidCloseSoundPlayer.soundNames, selection: soundName,
                         enabled: soundOn, label: Self.title)
            }
            SettingsGroup(title: L("Volume"),
                          hint: L("The sound plays on your Mac's speakers, and also in your headphones or other speaker when you listen on one. On, KoffeeLid unmutes both just for the sound: the speakers at this volume, the headphones at half of it, or at your own volume if it is louder. Off, it plays at your current volume, and not at all where the sound is muted.")) {
                ToggleRow(L("Play it at a set volume"), isOn: model.binding(\.forceVolumeEnabled), enabled: soundOn)
                SliderRow(L("Volume"), value: volume, in: 0...1, step: 0.05,
                          enabled: soundOn && model.prefs.forceVolumeEnabled, format: SettingsFormat.percent)
            }
        }
    }

    /// Picking a clip plays it: its name alone says nothing about what it sounds like.
    private var soundName: Binding<String> {
        let name = model.binding(\.lidCloseSoundName)
        return Binding(get: { name.wrappedValue },
                       set: {
                           name.wrappedValue = $0
                           KoffeeLidController.shared.soundPlayer.preview(named: $0)
                       })
    }

    /// Stored as a float, dragged as a double.
    private var volume: Binding<Double> {
        let level = model.binding(\.forceVolumeLevel)
        return Binding(get: { Double(level.wrappedValue) }, set: { level.wrappedValue = Float($0) })
    }

    private static func title(_ name: String) -> String {
        guard let index = LidCloseSoundPlayer.soundNames.firstIndex(of: name), index < titles.count else { return name }
        return titles[index]
    }
}
