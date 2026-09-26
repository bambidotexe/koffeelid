import Foundation

/// The app that stands for one kind of running work: its icon is the badge on the auto-armed cup and in
/// the menu's auto-arm line. The app layer turns it into an icon; a reference no app answers gives no badge.
public enum ActivityApp: Hashable, Sendable {
    /// An app LaunchServices finds by identifier: the Claude, Codex, GitHub Copilot and OpenCode desktop apps,
    /// Terminal.
    case bundleIdentifier(String)
    /// An app found on a process chain: the terminal hosting a shell.
    case bundlePath(String)

    var sortKey: String {
        switch self { case .bundleIdentifier(let id): return id; case .bundlePath(let path): return path }
    }
}

/// One badge: a kind of work and the app that stands for it. Sorted front to back: Claude Code, Codex,
/// Copilot, OpenCode, then the terminals by path.
public struct ActivityBadge: Hashable, Comparable, Sendable {
    public let kind: ActivityKind
    public let app: ActivityApp
    public init(kind: ActivityKind, app: ActivityApp) { self.kind = kind; self.app = app }

    public static func < (a: ActivityBadge, b: ActivityBadge) -> Bool {
        a.kind != b.kind ? a.kind < b.kind : a.app.sortKey < b.app.sortKey
    }

    /// Claude Code's work wears the Claude desktop app's icon.
    public static let claude = ActivityBadge(kind: .claude, app: .bundleIdentifier("com.anthropic.claudefordesktop"))
    /// Codex's work wears the icon of the app that owns Codex's identifier (`docs/macOS.md` § Codex).
    public static let codex = ActivityBadge(kind: .codex, app: .bundleIdentifier("com.openai.codex"))
    /// Copilot's work wears GitHub Copilot.app's icon, the desktop app that runs Copilot CLI sessions itself.
    public static let copilot = ActivityBadge(kind: .copilot, app: .bundleIdentifier("com.github.githubapp"))
    /// OpenCode's work wears OpenCode.app's icon.
    public static let opencode = ActivityBadge(kind: .opencode, app: .bundleIdentifier("ai.opencode.desktop"))
    /// A command whose shell no app hosts (over ssh, from launchd): Terminal stands for it.
    public static let terminal = ActivityBadge(kind: .terminal, app: .bundleIdentifier("com.apple.Terminal"))
    /// A command's badge from its shell's process chain: the app hosting the shell, Terminal when none.
    public static func terminal(hosting chain: [ProcWalk.ProcInfo]) -> ActivityBadge {
        ProcWalk.hostApplicationPath(in: chain).map { ActivityBadge(kind: .terminal, app: .bundlePath($0)) } ?? .terminal
    }
}

extension ProcWalk {
    /// The application hosting a process chain: the outermost `.app` bundle on the path of the nearest
    /// ancestor that runs from one (`/Applications/Visual Studio Code.app` for a shell under a Code
    /// helper). Nil when no process on the chain runs from an app (a shell over ssh, a launchd job).
    public static func hostApplicationPath(in chain: [ProcInfo]) -> String? {
        for info in chain {
            guard let path = info.path else { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if let end = parts.firstIndex(where: { $0.hasSuffix(".app") }), end < parts.count - 1 {
                return parts[...end].joined(separator: "/")
            }
        }
        return nil
    }
}

/// The badges the auto-armed cup wears: one per app at work right now; once nothing runs, the apps that
/// last ran stay through the hold-off (the cup still says why the Mac is armed); the level dropping
/// clears them. The coordinator feeds it the running badges on every activity change.
public struct AutoArmBadges: Equatable {
    /// Front to back.
    public private(set) var badges: [ActivityBadge] = []
    /// The cup draws this many at most.
    public static let maxShown = 3
    public init() {}

    public mutating func update(running: Set<ActivityBadge>, levelOn: Bool) {
        guard levelOn else { badges = []; return }
        if !running.isEmpty { badges = running.sorted() }
    }

    /// The badges the cup draws.
    public var shown: [ActivityBadge] { Array(badges.prefix(Self.maxShown)) }
}
