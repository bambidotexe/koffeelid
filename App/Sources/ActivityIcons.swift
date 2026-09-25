import AppKit
import KoffeeLidCore

/// The icon each badge wears: the app's icon from the system, looked up once per app and kept. Nothing is
/// bundled: an app that is not installed gives no icon, and the cup wears nothing for its work.
@MainActor
enum ActivityIcons {
    private static var cache: [ActivityApp: NSImage?] = [:]

    /// The icons of `badges`, in their order, skipping every app that has none.
    static func icons(for badges: [ActivityBadge]) -> [NSImage] { badges.compactMap { icon(for: $0.app) } }

    static func icon(for app: ActivityApp) -> NSImage? {
        if let known = cache[app] { return known }
        let icon = lookUp(app)
        cache[app] = icon
        return icon
    }

    private static func lookUp(_ app: ActivityApp) -> NSImage? {
        switch app {
        case .bundlePath(let path):
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return NSWorkspace.shared.icon(forFile: path)
        case .bundleIdentifier(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            // The OpenAI desktop app answers for Codex under the ChatGPT icon and ships the Codex icon in
            // its resources: that one is Codex's badge while it is there (docs/macOS.md § Codex).
            if id == "com.openai.codex", let codex = NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/icon-codex-light.png")) {
                return codex
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}
