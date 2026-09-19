import AppKit
import ServiceManagement
import KoffeeLidCore
import LidPlaneKit

/// Everything tunable that a first-time user should not have to see.
final class AdvancedViewController: PaneViewController {
    private let prefs = Preferences.shared
    private var p: EffectParameters { get { prefs.effect } set { prefs.effect = newValue } }
    private var angleValue: NSTextField!
    private var activityValue: NSTextField!
    private var timer: Timer?

    override func build(_ f: SettingsForm) {
        f.header(L("Lid gesture"))
        let mods = GestureModifier.allCases
        f.group { g in
            g.row(L("Hold while closing"), SettingsForm.popup([L("Fn (Globe)"), L("Option")], selected: mods.firstIndex(of: prefs.gestureModifier) ?? 0) { [prefs] i in prefs.gestureModifier = mods[i] })
            g.labelledSlider(L("Activation after"), min: 2, max: 20, value: prefs.gestureActivationDegrees, fmt: { "\(Int($0.rounded()))°" }) { [prefs] in prefs.gestureActivationDegrees = $0.rounded() }
            g.labelledSlider(L("Cancel if reopened by"), min: 2, max: 15, value: prefs.gestureReverseCancelDegrees, fmt: { "\(Int($0.rounded()))°" }) { [prefs] in prefs.gestureReverseCancelDegrees = $0.rounded() }
            angleValue = SettingsForm.value("—")
            g.row(L("Lid angle"), angleValue)
        }
        f.note(String(format: L("Hold %@ while you start closing the lid. KoffeeLid arms after the activation travel; the plane appears once the lid passes the gesture's start angle (Lid effect below) and follows it from there. If the Globe key triggers its system action when released, set System Settings › Keyboard › \"Press 🌐 key to\" to Do Nothing."), prefs.gestureModifier.keyName))

        f.header(L("Lid effect"))
        f.group { g in
            // The gesture start is the inner screen's upright angle; the other start is the extra gate for every
            // other arm and can never sit above it (`EffectParameters.clamped()` raises the gesture one), so each
            // slider pushes or stops at its neighbour.
            let degrees: (Double) -> String = { "\(Int($0.rounded()))°" }
            var gestureStart: SettingsForm.SliderHandle?
            gestureStart = g.labelledSlider(L("Start below (with the lid gesture)"), min: 30, max: EffectParameters.gestureStartCeiling, value: p.gestureStartBelowDegrees, fmt: degrees) { [weak self] in
                guard let self else { return }
                self.p.gestureStartBelowDegrees = $0.rounded()
                gestureStart?.set(self.p.gestureStartBelowDegrees)          // stops at the "except" value
            }
            g.labelledSlider(L("Start below (except the lid gesture)"), min: 30, max: 90, value: p.startBelowDegrees, fmt: degrees) { [weak self] in
                guard let self else { return }
                self.p.startBelowDegrees = $0.rounded()
                gestureStart?.set(self.p.gestureStartBelowDegrees)          // pushed up when the "except" value passes it
            }
            g.labelledSlider(L("Return to flat when still for"), min: 0.25, max: 10, value: p.settleDelay, fmt: { String(format: "%.2g s", $0) }) { [weak self] in self?.p.settleDelay = ($0 * 4).rounded() / 4 }
            g.labelledSlider(L("Inner screen zoom"), min: 0, max: 2, value: p.zoomStrength, fmt: { "\(Int(($0 * 100).rounded())) %" }) { [weak self] in self?.p.zoomStrength = ($0 * 20).rounded() / 20 }
            g.labelledSlider(L("Perspective"), min: 0, max: 2, value: p.perspectiveStrength, fmt: { "\(Int(($0 * 100).rounded())) %" }) { [weak self] in self?.p.perspectiveStrength = ($0 * 20).rounded() / 20 }
            g.labelledSlider(L("Blur strength"), min: 0, max: 2.0, value: p.blurStrength, fmt: { $0 == 0 ? L("Off") : String(format: "%.2f×", $0) }) { [weak self] in self?.p.blurStrength = ($0 * 20).rounded() / 20 }
            g.labelledSlider(L("Edge softness"), min: 0, max: 2, value: p.edgeSoftness, fmt: { $0 == 0 ? L("Off") : "\(Int(($0 * 100).rounded())) %" }) { [weak self] in self?.p.edgeSoftness = ($0 * 20).rounded() / 20 }
            g.labelledSlider(L("Shading"), min: 0, max: 2, value: p.shading, fmt: { $0 == 0 ? L("Off") : "\(Int(($0 * 100).rounded())) %" }) { [weak self] in self?.p.shading = ($0 * 20).rounded() / 20 }
            g.labelledSlider(L("Responsiveness"), min: 0, max: 1, value: p.responsiveness, fmt: { "\(Int(($0 * 100).rounded())) %" }) { [weak self] in self?.p.responsiveness = ($0 * 20).rounded() / 20 }
            g.row(L("Show lid angle"), SettingsForm.switch(p.showAngleInMenuBar) { [weak self] in self?.p.showAngleInMenuBar = $0 })
            g.row(L("Preview"), SettingsForm.button(L("Simulate a fold"), { KoffeeLidController.shared.effect.simulateFold() }))
            g.row(L("Defaults"), SettingsForm.button(L("Reset"), { [weak self] in
                guard let self else { return }
                self.prefs.effect = .default
                (self.view.window?.windowController as? AdvancedWindowController)?.reload()
            }))
        }
        f.note(L("While armed, closing the lid shows the desktop as an inner screen that stays upright behind the folding display: anchored at the hinge, it grows as the lid tilts (100 % zoom is the true geometry, 1 ÷ cos of the fold), narrows toward the top as it recedes behind the glass (perspective), blurs there, where the display is furthest from it, melts into the dark at its edges (edge softness: crisp at the hinge, widest at the top corners) and darkens toward the top (shading). The fold follows the lid 1:1 below the gesture's start angle, where the inner screen stands. The sensor reports the angle every 100 ms; Responsiveness sets how far the plane predicts between reports: 0 % waits for each report (smoothest, about 150 ms behind the lid), 100 % runs ahead (about 80 ms behind, a little jitter on slow closes). Nothing is captured until the lid moves. Armed from the menu bar or the shortcut, the effect waits until the lid is below the angle above, then moves faster than the lid until it has caught up."))

        f.header(L("Auto-arm on activity"))
        f.group { g in
            g.labelledSlider(L("Auto-disarm after Claude Code finishes"), min: 1, max: 120, value: prefs.activityHoldOffSeconds(.claude) / 60, fmt: { String(format: L("%d min"), Int($0.rounded())) }) { [prefs] in prefs.setActivityHoldOffSeconds(.claude, $0.rounded() * 60) }
            g.labelledSlider(L("Auto-disarm after a command finishes"), min: 10, max: 600, value: prefs.activityHoldOffSeconds(.terminal), fmt: { String(format: L("%d s"), Int($0.rounded())) }) { [prefs] in prefs.setActivityHoldOffSeconds(.terminal, ($0 / 5).rounded() * 5) }
            g.labelledSlider(L("Ignore commands shorter than"), min: 0, max: 30, value: prefs.activityJobArmAfterSeconds, fmt: { "\(Int($0.rounded())) s" }) { [prefs] in prefs.activityJobArmAfterSeconds = $0.rounded() }
            activityValue = SettingsForm.value("—")
            g.row(L("Activity"), activityValue)
        }
        f.note(L("Claude Code sessions blocked on a question or a permission do not count as running. A turn whose helpers are still out stays running until they fall silent."))

        f.header(L("App"))
        let status = SMAppService.agent(plistName: "dev.rubens.koffeelid.agent.plist").status
        f.group { g in
            let text: String
            switch status {
            case .enabled: text = L("Watchdog enabled")
            case .requiresApproval: text = L("Approve KoffeeLid in System Settings › General › Login Items.")
            case .notRegistered: text = L("Watchdog not registered")
            default: text = L("Watchdog unavailable")
            }
            if status == .requiresApproval {
                g.row(L("Crash recovery"), SettingsForm.button(L("Open Login Items"), { SMAppService.openSystemSettingsLoginItems() }))
            } else {
                g.row(L("Crash recovery"), SettingsForm.value(text))
            }
            g.row(L("Diagnostics log"), SettingsForm.switch(prefs.diagnosticsEnabled) { [prefs] on in
                // The last line before silence, and the first line after it, both land in the file.
                if !on { DiagnosticLog.shared.log("diagnostics log disabled from Advanced settings") }
                prefs.diagnosticsEnabled = on
                if on { DiagnosticLog.shared.log("diagnostics log enabled from Advanced settings") }
            })
        }
        if status == .requiresApproval { f.note(L("Approve KoffeeLid in System Settings › General › Login Items.")) }
        f.note(L("With the log off KoffeeLid writes nothing to diagnostics.log. Turn it back on before reporting a problem."))
        f.link(L("Open diagnostics log"), { NSWorkspace.shared.open(DiagnosticLog.shared.url) })
        f.link(L("Show onboarding again"), { (NSApp.delegate as? AppDelegate)?.showOnboarding() })
        f.link(L("Reset permissions and undo every change…"), { [weak self] in self?.confirmReset() })
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        KoffeeLidController.shared.lidAngleObserver?.addConsumer("settings")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.angleValue.stringValue = KoffeeLidController.shared.lastAngle.map { "\(Int($0))°" } ?? "—"
                self?.activityValue.stringValue = KoffeeLidController.shared.activity.snapshot.summary
            }
        }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear(); timer?.invalidate(); timer = nil
        KoffeeLidController.shared.lidAngleObserver?.removeConsumer("settings")
    }

    private func confirmReset() {
        let a = NSAlert()
        a.messageText = L("Reset KoffeeLid?")
        a.informativeText = L("This disarms, removes the sleep lock and its sudoers rule (administrator password), unregisters the login items, resets the Screen Recording and notification permissions, and clears every setting. The onboarding then starts again.")
        a.alertStyle = .warning
        a.addButton(withTitle: L("Reset")); a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let done = KoffeeLidController.shared.resetEverything()
        DiagnosticLog.shared.log("reset from Advanced: " + done.joined(separator: ", "))
        (NSApp.delegate as? AppDelegate)?.showOnboarding()
    }
}
