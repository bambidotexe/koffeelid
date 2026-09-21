import AppKit
import ServiceManagement
import SwiftUI
import KoffeeLidCore

/// The app's own icon, then starting up, updates, and the two ways out.
struct SettingsGeneralPage: View {
    @ObservedObject var model: SettingsModel
    /// The app's, not the page's: what a check found while this window was closed is here when it opens.
    @ObservedObject private var updates = UpdateController.shared
    /// The reason the last register or unregister was refused, shown until the next one works.
    @State private var loginFailure: String?

    var body: some View {
        SettingsPage {
            // The icon alone: no name and no version, which the Updates group gives.
            SettingsAppIcon()
            // With the icon hidden its menu is hidden with it, so the way back to this window is named.
            SettingsGroup(title: L("Startup"),
                          notes: [L("With the icon hidden, KoffeeLid keeps working. Open it again from the Applications folder or Spotlight to get back to this window.")]) {
                ToggleRow(L("Launch at login"),
                          isOn: Binding(get: { model.launchAtLogin }, set: setLaunchAtLogin))
                ToggleRow(L("Show in menu bar"), isOn: model.binding(\.showInMenuBar))
                if let loginFailure {
                    StatusRow(loginFailure, mark: .warning(L("Failed")))
                }
            }
            SettingsGroup(title: L("Updates")) {
                // The app's name and version are not localized.
                StatusRow("KoffeeLid \(KoffeeLidCore.version)", mark: mark)
                ButtonRow {
                    if updates.panel.offersUpdate {
                        Button(L("Update")) { updates.press() }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                    } else {
                        Button(L("Check for Updates")) { updates.press() }
                            .disabled(updates.panel.isBusy)
                    }
                }
            }
            SettingsGroup(title: L("Quit")) {
                // The menu's Quit: `applicationShouldTerminate` runs the coordinator's `shutdown()`, which
                // disarms, clears the kernel flag and releases the sleep lock.
                ButtonRow {
                    Button(L("Quit KoffeeLid"), role: .destructive) { NSApp.terminate(nil) }
                }
            }
            // The warning is not a state that can be put right: it is the hazard of the other way out, and
            // the button beside it is the way that is not hazardous. It therefore always shows.
            SettingsGroup(title: L("Uninstall"),
                          hint: L("Removes everything KoffeeLid set up outside its own folder: what starts it at login, what lets it hold the Mac awake, what it added to Claude Code and to the shell, and its settings and logs. KoffeeLid then moves itself to the Trash and quits."),
                          warnings: [L("Do not drag KoffeeLid to the Trash. All of that stays behind, goes on running against an app that is gone, and can make the Mac misbehave.")]) {
                ButtonRow {
                    Button(L("Uninstall KoffeeLid"), role: .destructive) { confirmUninstall() }
                }
            }
        }
    }

    /// Asks first, because it takes the app with it, and says afterwards what it could not remove. The order
    /// of the removals and why it is that order are `KoffeeLidController.uninstallEverything`'s.
    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = L("Uninstall KoffeeLid?")
        alert.informativeText = L("KoffeeLid stops holding the Mac awake, gives back the permissions it was granted, removes what starts it at login, what it added to Claude Code and to the shell, and its settings and logs. It then moves itself to the Trash and quits. Removing the sleep lock asks for an administrator password.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: L("Uninstall"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let outcome = KoffeeLidController.shared.uninstallEverything()
        // Last, because everything above reads the bundle: the grants name it, and the hooks name a binary
        // inside it. The Trash, not a delete: the app the owner just removed is still there to put back.
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            DispatchQueue.main.async {
                var failed = outcome.failed
                if let error {
                    failed.append(String(format: L("KoffeeLid could not move itself to the Trash: %@. Drag it there from the Applications folder; that is all that is left of it."), error.localizedDescription))
                }
                let result = NSAlert()
                result.messageText = failed.isEmpty ? L("KoffeeLid has been removed") : L("KoffeeLid has been removed, except for this")
                result.informativeText = failed.isEmpty
                    ? L("KoffeeLid is in the Trash, and nothing it set up is left on the Mac.")
                    : failed.joined(separator: "\n\n")
                result.alertStyle = failed.isEmpty ? .informational : .warning
                result.addButton(withTitle: L("Quit"))
                result.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    /// The rules (which mark, which button, what a press starts) are `UpdatePanel`'s; the page words the answer.
    private var mark: StatusMark? {
        guard let severity = updates.panel.severity else { return nil }
        let text: String = switch updates.panel.state {
        case .idle: ""
        case .checking: L("Checking")
        case .upToDate: L("Up to date")
        case .available(let version): String(format: L("Version %@ is available"), version.displayString)
        case .checkFailed(let reason): String(format: L("Could not check: %@"), reason)
        case .installFailed(let reason): String(format: L("Update failed: %@"), reason)
        }
        return StatusMark(severity, text)
    }

    /// The switch shows the service's answer, read back after every attempt: `register()` can be refused,
    /// and a switch showing what the click asked for over a system that refused it would be the worse lie.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            model.prefs.launchAtLogin = on
            loginFailure = nil
        } catch {
            DiagnosticLog.shared.log("launch at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            loginFailure = error.localizedDescription
        }
        model.refresh()
    }
}
