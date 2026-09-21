import AppKit
import SwiftUI
import KoffeeLidCore

/// What KoffeeLid needs from macOS and from this Mac, its log, and the two ways to start over.
///
/// Every state here follows the system while the window is open, so granting a permission in System
/// Settings shows up without closing it. A state the user can fix is its row, and while it is wrong a
/// button to the place it is fixed and a warning; once it is right both go and the row stays.
struct SettingsSystemPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L("Staying awake safely"),
                          hint: L("The sleep lock stops macOS from sleeping your closed Mac when you plug in the charger or a display changes. Background App Activity lets KoffeeLid come back after a crash and give your Mac its normal sleep back."),
                          warnings: safetyWarnings) {
                StatusRow(L("Sleep lock"), mark: model.mark(.sleepLock, yes: L("Available"), no: L("Missing")))
                    // What the lock is made of: for a bug report, and for nobody else.
                    .help(L("A sudoers rule for /usr/bin/pmset disablesleep"))
                if !model.holds(.sleepLock) {
                    ButtonRow {
                        Button(L("Set Up Sleep Lock…")) { model.grant(.sleepLock) }
                    }
                }
                StatusRow(L("KoffeeLid in “Background App Activity”"), mark: model.mark(.loginItems, yes: L("Enabled"), no: L("Disabled")))
                    .help(RelaunchAgentController.plistName)
                if !model.holds(.loginItems) {
                    ButtonRow {
                        Button(L("Open Login Items Settings")) { model.grant(.loginItems) }
                    }
                }
            }
            SettingsGroup(title: L("Permissions"),
                          hint: L("Screen & System Audio Recording lets the lid effect show your desktop. Input Monitoring lets the lid gesture tell this Mac's 🌐 Fn key from an external keyboard's. Notifications tell you when KoffeeLid turns itself off."),
                          notes: [L("After allowing Screen & System Audio Recording, quit and reopen KoffeeLid.")]) {
                permission(.screenRecording, L("Screen & System Audio Recording permission"), allow: L("Allow Screen & System Audio Recording"))
                permission(.inputMonitoring, L("Input Monitoring permission"), allow: L("Allow Input Monitoring"))
                permission(.notifications, L("Notifications permission"), allow: L("Allow Notifications"))
            }
            SettingsGroup(title: L("Compatibility"),
                          hint: L("The lid gesture and the lid effect need it. Everything else works without it.")) {
                StatusRow(L("Lid angle sensor"),
                          mark: model.sensorPresent ? .good(L("Available")) : .warning(L("Missing")))
            }
            SettingsGroup(title: L("Diagnostics"),
                          hint: L("Off, KoffeeLid writes nothing to its log. Turn it back on before you report a problem.")) {
                ToggleRow(L("Keep a diagnostics log"), isOn: diagnostics)
                ButtonRow {
                    Button(L("Open Diagnostics Log")) { NSWorkspace.shared.open(DiagnosticLog.shared.url) }
                }
            }
            SettingsGroup(title: L("Start over"),
                          hint: L("Reset turns KoffeeLid off, removes the sleep lock, the login items, the hooks and every permission, and clears every setting. It asks first.")) {
                ButtonRow {
                    Button(L("Show Onboarding Again")) { (NSApp.delegate as? AppDelegate)?.showOnboarding() }
                }
                ButtonRow {
                    Button(L("Reset KoffeeLid…")) { confirmReset() }
                }
            }
        }
    }

    /// A permission's row, and its button only while it is not granted.
    @ViewBuilder
    private func permission(_ grant: SettingsGrant, _ title: String, allow: String) -> some View {
        StatusRow(title, mark: model.mark(grant, yes: L("Granted"), no: L("Denied")))
        if !model.holds(grant) {
            ButtonRow {
                Button(allow) { model.grant(grant) }
            }
        }
    }

    /// One instruction for each row that is orange, and none for a row that is green.
    private var safetyWarnings: [String] {
        var warnings: [String] = []
        if !model.holds(.sleepLock) { warnings.append(L("Set up the sleep lock. It asks for your administrator password once.")) }
        if !model.holds(.loginItems) { warnings.append(L("In System Settings › General › Login Items, turn KoffeeLid on under “Background App Activity”.")) }
        return warnings
    }

    /// The last line before silence, and the first line after it, both land in the file.
    private var diagnostics: Binding<Bool> {
        let enabled = model.binding(\.diagnosticsEnabled)
        return Binding(get: { enabled.wrappedValue },
                       set: { on in
                           if !on { DiagnosticLog.shared.log("diagnostics log disabled from Settings") }
                           enabled.wrappedValue = on
                           if on { DiagnosticLog.shared.log("diagnostics log enabled from Settings") }
                       })
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("Reset KoffeeLid?")
        alert.informativeText = L("This disarms, removes the sleep lock and its sudoers rule (administrator password), unregisters the login items, resets the Screen & System Audio Recording and notification permissions, and clears every setting. The onboarding then starts again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Reset"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let done = KoffeeLidController.shared.resetEverything()
        DiagnosticLog.shared.log("reset from Settings: " + done.joined(separator: ", "))
        (NSApp.delegate as? AppDelegate)?.showOnboarding()
        model.refresh()
    }
}
