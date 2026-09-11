import AppKit
import KoffeeLidCore

/// The two hooks that feed auto-arm on activity: shown by the onboarding "Hooks" page and the Settings
/// "Hooks" group, exactly like `PermissionCatalog` feeds the Permissions page and group.
@MainActor
enum HookCatalog {
    static var items: [PermissionItem] {[
        PermissionItem(title: L("Claude Code"),
                       why: L("Tells KoffeeLid when a Claude Code session is working, so it arms while you close the lid and disarms once the turn is over. Adds hooks to ~/.claude/settings.json (backed up first)."),
                       required: false,
                       granted: { (HookInstaller.installedCount() ?? 0) == HookConfig.events.count },
                       buttonTitle: L("Set up…"),
                       action: { window, done in
                           let r = HookInstaller.install()
                           DiagnosticLog.shared.log("install-hooks from UI: \(r.message)")
                           if r.ok { if !Preferences.shared.armOnActivity { Preferences.shared.armOnActivity = true } } else { report(L("Claude Code"), r.message, in: window) }
                           done()
                       },
                       doneTitle: L("Set up"),
                       pendingTitle: L("Not set up"),
                       removeTitle: L("Remove"),
                       remove: { window, done in
                           let r = HookInstaller.uninstall()
                           DiagnosticLog.shared.log("uninstall-hooks from UI: \(r.message)")
                           if !r.ok { report(L("Claude Code"), r.message, in: window) }
                           done()
                       }),
        PermissionItem(title: L("Terminal (zsh)"),
                       why: L("Adds one line to ~/.zshrc so commands running longer than a few seconds arm KoffeeLid too. Open a new terminal afterwards."),
                       required: false,
                       granted: { HookInstaller.zshrcHasSnippet() },
                       buttonTitle: L("Set up…"),
                       action: { window, done in
                           let r = HookInstaller.addToZshrc()
                           DiagnosticLog.shared.log("add-to-zshrc from UI: \(r.message)")
                           if r.ok { if !Preferences.shared.armOnActivity { Preferences.shared.armOnActivity = true } } else { report(L("Terminal (zsh)"), r.message, in: window) }
                           done()
                       },
                       doneTitle: L("Set up"),
                       pendingTitle: L("Not set up"),
                       removeTitle: L("Remove"),
                       remove: { window, done in
                           let r = HookInstaller.removeFromZshrc()
                           DiagnosticLog.shared.log("remove-from-zshrc from UI: \(r.message)")
                           if !r.ok { report(L("Terminal (zsh)"), r.message, in: window) }
                           done()
                       }),
    ]}

    /// A failed install is only worth a log line to us and nothing at all to the user unless we say so:
    /// the row would simply stay "Not set up" with no reason given.
    private static func report(_ title: String, _ message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
    }
}

