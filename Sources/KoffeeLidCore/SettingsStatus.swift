import Foundation

/// The five ways the Settings window marks a state, each with one symbol and one colour on every page:
/// as it should be, worth knowing, to be fixed, refused, still happening.
public enum StatusSeverity: Equatable {
    case good, info, warning, failure, busy

    /// The mark of one of the Health page's four levels, so a state reads the same on every page.
    public init(_ level: HealthLevel) {
        switch level {
        case .info: self = .info
        case .good: self = .good
        case .warning: self = .warning
        case .failure: self = .failure
        }
    }
}

/// Everything the Settings window reports as granted or not: the two things a closed Mac needs to stay
/// awake safely, the three macOS permissions, the two hooks that feed auto-arm.
public enum SettingsGrant: String, CaseIterable {
    case sleepLock, loginItems, screenRecording, inputMonitoring, notifications, claudeHooks, zshHook

    /// Whether KoffeeLid cannot keep a closed Mac awake safely without it: the sleep lock, which stops macOS
    /// from sleeping it behind the arm, and Background App Activity, which brings KoffeeLid back after a
    /// crash and the Mac's normal sleep with it. The onboarding marks these rows required; every other grant
    /// serves one feature.
    public var isRequired: Bool {
        switch self {
        case .sleepLock, .loginItems: true
        case .screenRecording, .inputMonitoring, .notifications, .claudeHooks, .zshHook: false
        }
    }
}

/// The colour of a state follows whether it is what it should be, not whether it is on.
public enum SettingsStatus {
    /// A grant that is there is green. A missing one is red when it is required and orange otherwise, on
    /// every page that shows it, whatever the settings: `HealthRules.grant(held:required:)`.
    public static func severity(of grant: SettingsGrant, held: Set<SettingsGrant>) -> StatusSeverity {
        StatusSeverity(HealthRules.grant(held: held.contains(grant), required: grant.isRequired))
    }

    /// Auto-arm is on and neither hook is set up: nothing can tell the app that work is running.
    public static func autoArmIsDeaf(held: Set<SettingsGrant>, autoArmEnabled: Bool) -> Bool {
        autoArmEnabled && !held.contains(.claudeHooks) && !held.contains(.zshHook)
    }
}
