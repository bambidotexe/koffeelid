import SwiftUI

/// The one sound KoffeeLid makes, and how loud it plays.
struct SettingsSoundPage: View {
    @ObservedObject var model: SettingsModel

    private var soundOn: Bool { model.prefs.lidCloseSoundEnabled }

    /// The clips' names as the user reads them, in the order of `LidCloseSoundPlayer.soundNames`.
    private static let titles = [L("Blip pop"), L("Bloop"), L("Chime blip"), L("Enter"), L("Notification"), L("Tick")]

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Lid-close sound"),
                          hint: L("Plays when the lid closes while KoffeeLid is armed, so you hear that your Mac stays awake.")) {
                ToggleRow(L("Play a sound when the lid closes"), isOn: model.binding(\.lidCloseSoundEnabled))
                PopUpRow(L("Sound"), options: LidCloseSoundPlayer.soundNames, selection: soundName,
                         enabled: soundOn, label: Self.title)
            }
            SettingsGroup(title: L("Volume"),
                          hint: L("On, KoffeeLid unmutes your Mac and sets this volume just for the sound, then puts your volume back. Off, the sound plays at your current volume, and not at all if your Mac is muted.")) {
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
