import AppKit
import KoffeeLidCore

/// The `koffeelid` command line talks to the running app over distributed notifications:
/// the client posts `command` with a one-off `replyTo` name and waits for the text reply.
final class CommandServer {
    static let commandName = Notification.Name("dev.rubens.koffeelid.command")
    private var observer: NSObjectProtocol?
    var handler: ((DeepLink) -> String)?

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.commandName, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?["command"] as? String else { return }
            let reply = DeepLink(command: raw).map { self?.handler?($0) ?? "" } ?? "unknown command: \(raw)"
            if let replyTo = n.userInfo?["replyTo"] as? String {
                DistributedNotificationCenter.default().postNotificationName(Notification.Name(replyTo), object: nil, userInfo: ["text": reply], deliverImmediately: true)
            }
        }
    }

    func stop() { if let o = observer { DistributedNotificationCenter.default().removeObserver(o) }; observer = nil }
    deinit { stop() }
}

/// Client side, run from `main.swift` before AppKit starts when the first argument is a verb.
enum CommandLineClient {
    static let usage = "usage: koffeelid arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings | install-hooks [claude|codex|copilot|opencode] | uninstall-hooks [claude|codex|copilot|opencode] | shell-init zsh"

    /// Returns an exit code when the arguments were a CLI invocation, nil to start the app normally.
    static func run(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, !arguments[1].hasPrefix("-") else { return nil }
        switch arguments[1] {
        case "install-hooks", "uninstall-hooks":
            // The agent is an optional word: none is Claude Code, as it was before Codex was supported.
            let install = arguments[1] == "install-hooks"
            let r: (ok: Bool, message: String)
            switch arguments.count >= 3 ? arguments[2] : "claude" {
            case "claude": r = install ? HookInstaller.install() : HookInstaller.uninstall()
            case "codex": r = install ? HookInstaller.installCodex() : HookInstaller.uninstallCodex()
            case "copilot": r = install ? HookInstaller.installCopilot() : HookInstaller.uninstallCopilot()
            case "opencode": r = install ? HookInstaller.installOpencode() : HookInstaller.uninstallOpencode()
            default: fputs("usage: koffeelid \(arguments[1]) [claude|codex|copilot|opencode]\n", stderr); return 2
            }
            print(r.message); return r.ok ? 0 : 1
        case "shell-init":
            guard arguments.count >= 3, arguments[2] == "zsh" else { fputs("usage: koffeelid shell-init zsh\n", stderr); return 2 }
            print(HookInstaller.snippet); return 0
        default: break
        }
        guard let verb = DeepLink(command: arguments[1]) else { fputs("\(usage)\n", stderr); return 2 }
        if !isAppRunning {
            if verb == .status { print("mode: off (KoffeeLid is not running)"); return 0 }
            launchApp()
        }
        // The app registers its listener at the end of start(); retry until it answers.
        for _ in 0..<12 {
            if let reply = send(verb.rawValue, timeout: 1.0) { print(reply); return reply.hasPrefix("did not") ? 1 : 0 }
        }
        fputs("koffeelid: no answer from KoffeeLid\n", stderr)
        return 1
    }

    private static var isAppRunning: Bool {
        let me = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains { $0.processIdentifier != me }
    }

    private static func launchApp() {
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
        var done = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in done = true }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
    }

    private static func send(_ command: String, timeout: TimeInterval) -> String? {
        let center = DistributedNotificationCenter.default()
        let replyName = Notification.Name("dev.rubens.koffeelid.reply.\(UUID().uuidString)")
        var reply: String?
        let obs = center.addObserver(forName: replyName, object: nil, queue: nil) { n in reply = n.userInfo?["text"] as? String ?? "" }
        defer { center.removeObserver(obs) }
        center.postNotificationName(CommandServer.commandName, object: nil, userInfo: ["command": command, "replyTo": replyName.rawValue], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while reply == nil, Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
        return reply
    }
}
