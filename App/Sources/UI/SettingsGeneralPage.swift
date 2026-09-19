import AppKit
import ServiceManagement
import SwiftUI
import KoffeeLidCore

/// The app's own icon, then starting up, updates, and the way out.
struct SettingsGeneralPage: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var updates = UpdatesModel()
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
            SettingsGroup(title: L("Updates"), notes: updates.notes) {
                // The app's name and version are not localized.
                StatusRow("KoffeeLid \(KoffeeLidCore.version)", mark: updates.mark)
                ButtonRow {
                    if updates.panel.isProminent {
                        Button(updates.buttonTitle) { updates.press() }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                    } else {
                        Button(updates.buttonTitle) { updates.press() }
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
        }
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

/// The Updates group's state and its two requests. The rules (which mark, which button, what a press
/// starts) are `UpdatePanel`'s; this object only runs the requests and words the answers.
@MainActor
private final class UpdatesModel: ObservableObject {
    @Published private(set) var panel = UpdatePanel()
    private let checker = UpdateChecker()

    var mark: StatusMark? {
        guard let severity = panel.severity else { return nil }
        return StatusMark(severity, text)
    }

    private var text: String {
        switch panel.state {
        case .idle: ""
        case .checking: L("Checking")
        case .upToDate: L("Up to date")
        case .available(let version): String(format: L("Version %@ is available"), version.displayString)
        case .checkFailed(let reason): String(format: L("Could not check: %@"), reason)
        case .downloading: L("Downloading")
        case .downloaded: L("Downloaded")
        case .downloadFailed(let reason): String(format: L("Update failed: %@"), reason)
        }
    }

    /// The app never installs over itself: once the disk image is open, this line says what is left to do.
    var notes: [String] {
        panel.state == .downloaded ? [L("Drag KoffeeLid to Applications, then quit and reopen it.")] : []
    }

    var buttonTitle: String { panel.offersUpdate ? L("Update") : L("Check for Updates") }

    func press() {
        switch panel.press() {
        case .check:
            checker.check { [weak self] result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let decision): self?.panel.checked(decision)
                    case .failure(let error): self?.panel.checkFailed(error.localizedDescription)
                    }
                }
            }
        case .download(let release):
            checker.download(release) { [weak self] result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success: self?.panel.downloaded()
                    case .failure(let error): self?.panel.downloadFailed(error.localizedDescription)
                    }
                }
            }
        case nil:
            break
        }
    }
}
