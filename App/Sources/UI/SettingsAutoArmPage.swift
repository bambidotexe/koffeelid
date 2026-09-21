import SwiftUI
import KoffeeLidCore

/// Arming that happens on its own while work runs: the switch, then each of the two things that tell
/// KoffeeLid work is running, with its own waits.
struct SettingsAutoArmPage: View {
    @ObservedObject var model: SettingsModel

    private var auto: Bool { model.prefs.armOnActivity }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("While you work"),
                          hint: L("KoffeeLid arms itself while work is running and turns itself off once it is over. It never changes the mode you picked yourself."),
                          warnings: SettingsStatus.autoArmIsDeaf(held: model.held, autoArmEnabled: auto)
                            ? [L("Set up Claude Code or the terminal below. Until then, KoffeeLid cannot tell when work is running.")]
                            : [],
                          notes: [L("“Disarm once finished” in the menu also ends your own arm, one minute after the work is over.")]) {
                ToggleRow(L("Arm while Claude Code or a terminal command is running"),
                          isOn: model.binding(\.armOnActivity))
                StatusRow(L("Work running now"), mark: workMark)
            }
            SettingsGroup(title: L("Claude Code"),
                          hint: L("KoffeeLid adds its hooks to ~/.claude/settings.json and backs the file up first. The wait leaves you time to pick a session up from another device: touching this Mac's keyboard or trackpad ends it at once."),
                          notes: [L("A session waiting for your answer does not count as running.")]) {
                StatusRow(L("Claude Code hooks"), mark: model.mark(.claudeHooks, yes: L("Enabled"), no: L("Disabled")))
                ButtonRow {
                    if model.holds(.claudeHooks) {
                        Button(L("Remove from Claude Code")) { model.revoke(.claudeHooks) }
                    } else {
                        Button(L("Set Up Claude Code")) { model.grant(.claudeHooks) }
                    }
                }
                SliderRow(L("Stay armed after Claude Code finishes"), value: claudeMinutes,
                          in: 1...120, step: 1, enabled: auto, format: SettingsFormat.minutes)
            }
            SettingsGroup(title: L("Terminal"),
                          hint: L("KoffeeLid adds one line to ~/.zshrc. Open a new terminal window afterwards.")) {
                StatusRow(L("Terminal hook (zsh)"), mark: model.mark(.zshHook, yes: L("Enabled"), no: L("Disabled")))
                ButtonRow {
                    if model.holds(.zshHook) {
                        Button(L("Remove from the Terminal")) { model.revoke(.zshHook) }
                    } else {
                        Button(L("Set Up the Terminal")) { model.grant(.zshHook) }
                    }
                }
                SliderRow(L("Stay armed after a command finishes"), value: model.holdOff(.terminal),
                          in: 10...600, step: 5, enabled: auto, format: SettingsFormat.seconds)
                SliderRow(L("Ignore commands shorter than"), value: model.binding(\.activityJobArmAfterSeconds),
                          in: 0...30, step: 1, enabled: auto, format: SettingsFormat.seconds)
            }
        }
    }

    /// What the app counts as running at this moment: the proof that a hook works.
    private var workMark: StatusMark {
        let snapshot = model.activity
        if snapshot.workingSessions == 0 && snapshot.runningJobs == 0 { return .info(L("None")) }
        return .info(String(format: L("Claude Code: %d, commands: %d"), snapshot.workingSessions, snapshot.runningJobs))
    }

    /// Stored in seconds, set in minutes: Claude Code's wait is a long one.
    private var claudeMinutes: Binding<Double> {
        let seconds = model.holdOff(.claude)
        return Binding(get: { seconds.wrappedValue / 60 }, set: { seconds.wrappedValue = $0.rounded() * 60 })
    }
}
