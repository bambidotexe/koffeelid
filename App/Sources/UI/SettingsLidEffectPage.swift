import SwiftUI
import KoffeeLidCore
import LidPlaneKit

/// The desktop that stays upright behind the closing screen: whether it plays, the lid angle it is set
/// against, when it starts, what it looks like, and a preview.
struct SettingsLidEffectPage: View {
    @ObservedObject var model: SettingsModel

    private var effectOn: Bool { model.prefs.effect.enabled }
    private var sensor: Bool { model.sensorPresent }
    /// Nothing about the start or the look matters while the effect cannot play at all.
    private var playable: Bool { effectOn && sensor }
    private var recordingMissing: Bool { effectOn && !model.holds(.screenRecording) }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Effect"),
                          hint: L("While KoffeeLid is armed, your desktop stays upright behind the screen as it folds down. The effect only plays while the lid closes, and nothing is captured while the lid rests."),
                          warnings: recordingMissing
                            ? [L("Allow Screen Recording for KoffeeLid, then quit and reopen it. Without it, the effect cannot show your desktop.")]
                            : [],
                          notes: sensor ? [] : [L("This Mac has no lid angle sensor, so the lid effect is not available.")]) {
                ToggleRow(L("Show the desktop folding away as the lid closes"), isOn: model.effect(\.enabled),
                          enabled: sensor)
                // The one grant the effect needs, reported where the effect is switched on. The row stays
                // once it is green, so the link between the two can always be seen.
                if effectOn {
                    StatusRow(L("Screen Recording permission"),
                              mark: model.mark(.screenRecording, yes: L("Granted"), no: L("Denied")))
                }
                if recordingMissing {
                    ButtonRow {
                        Button(L("Allow Screen Recording")) { model.grant(.screenRecording) }
                    }
                }
            }
            SettingsGroup(title: L("Lid angle")) {
                // Nothing to report until the sensor has been read once.
                StatusRow(L("Lid angle now"), mark: model.lidAngle.map { .info("\(Int($0))°") })
                ToggleRow(L("Show the lid angle in the menu bar"), isOn: model.effect(\.showAngleInMenuBar),
                          enabled: model.prefs.showInMenuBar)
            }
            SettingsGroup(title: L("When it starts"),
                          hint: L("The first angle is also where your desktop stands upright. Armed from the menu bar or a shortcut, the effect waits for the second angle, so adjusting your screen while you work starts nothing.")) {
                // The second angle never stands above the first: the store raises the first with it, and
                // both rows show what the store holds.
                SliderRow(L("With the lid gesture, start below"), value: model.effect(\.gestureStartBelowDegrees),
                          in: 30...EffectParameters.gestureStartCeiling, step: 1, enabled: playable,
                          format: SettingsFormat.degrees)
                SliderRow(L("Otherwise, start below"), value: model.effect(\.startBelowDegrees),
                          in: 30...90, step: 1, enabled: playable, format: SettingsFormat.degrees)
                SliderRow(L("Flatten again when still for"), value: model.effect(\.settleDelay),
                          in: 0.25...10, step: 0.25, enabled: playable) { String(format: "%.2g s", $0) }
            }
            SettingsGroup(title: L("Look"),
                          hint: L("At 100%, the zoom is the true geometry. Responsiveness is how far the effect runs ahead of the lid sensor: low is smoothest and a little late, high sticks to the lid with a little jitter on slow closes.")) {
                SliderRow(L("Zoom"), value: model.effect(\.zoomStrength), in: 0...2, step: 0.05,
                          enabled: playable, format: SettingsFormat.percent)
                SliderRow(L("Perspective"), value: model.effect(\.perspectiveStrength), in: 0...2, step: 0.05,
                          enabled: playable, format: SettingsFormat.percent)
                SliderRow(L("Blur"), value: model.effect(\.blurStrength), in: 0...2, step: 0.05,
                          enabled: playable) { $0 == 0 ? L("Off") : String(format: "%.2f×", $0) }
                SliderRow(L("Soft edges"), value: model.effect(\.edgeSoftness), in: 0...2, step: 0.05,
                          enabled: playable, format: SettingsFormat.offOrPercent)
                SliderRow(L("Shading"), value: model.effect(\.shading), in: 0...2, step: 0.05,
                          enabled: playable, format: SettingsFormat.offOrPercent)
                SliderRow(L("Responsiveness"), value: model.effect(\.responsiveness), in: 0...1, step: 0.05,
                          enabled: playable, format: SettingsFormat.percent)
                    // The measured lags are what a report of a jittery effect needs, and nobody else does.
                    .help(L("At 0%, the effect waits for each sensor report and runs about 150 ms behind the lid. At 100%, it runs ahead, about 80 ms behind."))
            }
            SettingsGroup(title: L("Preview"),
                          hint: String(format: L("Plays a %d° fold over %d seconds, whether KoffeeLid is armed or not."),
                                       Int(EffectController.previewFoldDegrees), Int(EffectController.previewFoldSeconds))) {
                // Two buttons on one row: both are valid at every moment.
                ButtonRow {
                    Button(L("Reset to Defaults")) {
                        model.prefs.effect = .default
                        model.refresh()
                    }
                    Button(L("Simulate a Fold")) { KoffeeLidController.shared.effect.simulateFold() }
                }
            }
        }
    }
}
