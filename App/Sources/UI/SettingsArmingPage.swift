import SwiftUI
import KoffeeLidCore

/// Every way to arm by hand, the lid gesture first, and the one rail the user sets: low battery.
struct SettingsArmingPage: View {
    @ObservedObject var model: SettingsModel

    private var sensor: Bool { model.sensorPresent }
    /// The gesture is on only when it is switched on and this Mac can feel its lid.
    private var gestureOn: Bool { model.prefs.armWithOption && sensor }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Lid gesture"),
                          hint: L("Hold the key while you start closing the lid. Your Mac stays awake until you open it and log back in. To cancel, reopen the lid a little before it shuts."),
                          notes: gestureNotes) {
                ToggleRow(String(format: L("Hold %@ and close the lid to arm for one close"),
                                 Self.keyName(model.prefs.gestureModifier)),
                          isOn: Binding(get: { gestureOn },
                                        set: { model.binding(\.armWithOption).wrappedValue = $0 }),
                          enabled: sensor)
                SegmentedRow(L("Key to hold"), options: GestureModifier.allCases,
                             selection: model.binding(\.gestureModifier), enabled: gestureOn,
                             label: Self.keyName)
                SliderRow(L("Arm after closing by"), value: model.binding(\.gestureActivationDegrees),
                          in: 2...20, step: 1, enabled: gestureOn, format: SettingsFormat.degrees)
                SliderRow(L("Cancel when reopened by"), value: model.binding(\.gestureReverseCancelDegrees),
                          in: 2...15, step: 1, enabled: gestureOn, format: SettingsFormat.degrees)
            }
            SettingsGroup(title: L("Menu bar and shortcuts"),
                          hint: String(format: L("Armed keeps your Mac running with the lid closed, until you turn KoffeeLid off. Armed + screen on also keeps the display awake while the lid is open. Right-click twice within %d seconds to get it."),
                                       Int(ModeCycle.defaultWindow)),
                          notes: [L("Your Mac locks every time the lid reopens.")]) {
                // With the icon hidden there is nothing left to right-click.
                ToggleRow(L("Right-click the menu bar icon to arm"), isOn: model.binding(\.armWithRightClick),
                          enabled: model.prefs.showInMenuBar)
                ToggleRow(String(format: L("Press %@ to arm, or to turn off"),
                                 HotKeyController.describe(code: model.prefs.hotKeyCode,
                                                           modifiers: model.prefs.hotKeyModifiers)),
                          isOn: model.binding(\.armWithShortcut))
                ToggleRow(String(format: L("Press %@ to arm with the screen on, or to turn off"),
                                 HotKeyController.describe(code: model.prefs.caffeinateHotKeyCode,
                                                           modifiers: model.prefs.caffeinateHotKeyModifiers)),
                          isOn: model.binding(\.armWithCaffeinateShortcut))
            }
            SettingsGroup(title: L("Low battery"),
                          hint: L("On battery, at this level or below, KoffeeLid turns itself off and will not arm, so your Mac can sleep instead of running flat. Plugged in, nothing changes.")) {
                ToggleRow(L("Turn off when the battery runs low"), isOn: model.binding(\.lowBatteryDisarm))
                SliderRow(L("Battery level"), value: batteryLevel, in: 5...50, step: 1,
                          enabled: model.prefs.lowBatteryDisarm, format: SettingsFormat.wholePercent)
            }
        }
    }

    /// The key as it is printed on the keyboard, symbol first. A key's name is not localized.
    private static func keyName(_ modifier: GestureModifier) -> String {
        modifier == .fn ? "🌐 Fn" : "⌥ Option"
    }

    /// Without the sensor there is no gesture at all. With it, Fn has one habit of its own worth a line.
    private var gestureNotes: [String] {
        if !sensor {
            [L("This Mac has no lid angle sensor, so the lid gesture is not available.")]
        } else if model.prefs.gestureModifier == .fn {
            [L("If 🌐 Fn opens something when you let go, set “Press 🌐 key to” to “Do Nothing” in Keyboard settings.")]
        } else {
            []
        }
    }

    /// Stored as a whole percent, dragged as a number.
    private var batteryLevel: Binding<Double> {
        let percent = model.binding(\.lowBatteryDisarmPercent)
        return Binding(get: { Double(percent.wrappedValue) }, set: { percent.wrappedValue = Int($0.rounded()) })
    }
}
