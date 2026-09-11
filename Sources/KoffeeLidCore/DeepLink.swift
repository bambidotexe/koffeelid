import Foundation

/// `koffeelid://<verb>` URLs and the verbs of the `koffeelid` command line share this vocabulary.
public enum DeepLink: String, Equatable, CaseIterable {
    case arm, off, caffeinate, toggleArmed = "toggle-armed", toggleCaffeinate = "toggle-caffeinate", status, settings
    public static let scheme = "koffeelid"

    /// Accepts the older spellings too: `disarm` = `off`, `toggle` = `toggle-armed`.
    public init?(command: String) {
        switch command.lowercased() {
        case "disarm": self = .off
        case "toggle": self = .toggleArmed
        default: guard let v = DeepLink(rawValue: command.lowercased()) else { return nil }; self = v
        }
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme else { return nil }
        self.init(command: url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
