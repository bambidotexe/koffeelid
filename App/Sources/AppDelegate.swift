import AppKit
import KoffeeLidCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsWindow?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).first(where: { $0.processIdentifier != getpid() }) {
            DiagnosticLog.shared.log("duplicate-instance exit (shared state untouched); other pid \(running.processIdentifier)")
            DiagnosticLog.shared.flush()
            exit(0)
        }
        do { try KoffeeLidController.shared.start() }
        catch {
            DiagnosticLog.shared.log("launch ABORTED: could not open IOPMrootDomain connection")
            let a = NSAlert(); a.messageText = L("KoffeeLid cannot start"); a.informativeText = L("KoffeeLid could not open the power-management connection it needs. Restart the Mac and try again.")
            a.runModal()
            DiagnosticLog.shared.flush()
            exit(1)
        }
        KoffeeLidController.shared.onOpenSettings = { [weak self] in self?.showSettings() }
        if !Preferences.shared.onboardingCompleted { showOnboarding() }
        if CommandLine.arguments.contains("--open-settings") { showSettings() }
        startUpdates()
    }

    /// After the coordinator: a launch that follows an Install and Relaunch says in the update window how it
    /// ended, and the install is refused while quitting would put the Mac to sleep.
    @MainActor private func startUpdates() {
        let updates = UpdateController.shared
        updates.onShowSettings = { [weak self] in self?.showSettings() }
        updates.othersNeedUsActive = { [weak self] in
            self?.settings?.isUp == true || self?.onboarding?.window?.isVisible == true
        }
        updates.installRefusal = {
            KoffeeLidController.shared.quitWouldSleepTheMac
                ? L("Open the lid first. With the lid closed, the Mac goes to sleep when KoffeeLid quits.") : nil
        }
        updates.willQuitForInstall = { KoffeeLidController.shared.updateInstallRequestedAt = Date() }
        updates.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { if let link = DeepLink(url: u) { KoffeeLidController.shared.perform(link, source: .url) } }
    }

    /// Opening KoffeeLid again (Finder, Spotlight, `open -b`) has nothing else to show: Settings is the window.
    /// A cold launch gets no reopen (and none from the login item either, `docs/macOS.md`), so it stays quiet.
    /// The one open request that is nobody's is the update helper's, and an open request outlives the process
    /// it was sent to: while an install's outcome is still unread, this launch is that install's.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, !UpdateController.installOutcomeIsWaiting { showSettings() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        KoffeeLidController.shared.shutdown(); return .terminateNow
    }

    /// Built once and re-shown: the window keeps its page and its place. `show()` brings the app forward.
    @MainActor func showSettings() {
        if settings == nil {
            settings = SettingsWindow(othersNeedUsActive: { [weak self] in
                self?.onboarding?.window?.isVisible == true || UpdateController.shared.windowIsUp
            })
        }
        settings?.show()
    }
    /// A fresh controller every time: the pages re-read every grant and start from page one.
    func showOnboarding() {
        onboarding?.close()
        onboarding = OnboardingWindowController()
        onboarding?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
