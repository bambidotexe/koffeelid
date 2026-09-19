import Foundation

/// The five ways the Settings window marks a state, each with one symbol and one colour on every page:
/// as it should be, worth knowing, to be fixed, refused, still happening.
public enum StatusSeverity: Equatable {
    case good, info, warning, failure, busy
}

/// Everything the Settings window reports as granted or not: the two things a closed Mac needs to stay
/// awake safely, the three macOS permissions, the two hooks that feed auto-arm.
public enum SettingsGrant: String, CaseIterable {
    case sleepLock, loginItems, screenRecording, inputMonitoring, notifications, claudeHooks, zshHook
}

/// The settings a state's colour depends on.
public struct SettingsContext: Equatable {
    public var effectEnabled: Bool
    public var gestureEnabled: Bool
    /// The gesture watches Fn rather than Option: the one key an external keyboard has too.
    public var gestureUsesFn: Bool
    public var autoArmEnabled: Bool

    public init(effectEnabled: Bool, gestureEnabled: Bool, gestureUsesFn: Bool, autoArmEnabled: Bool) {
        self.effectEnabled = effectEnabled
        self.gestureEnabled = gestureEnabled
        self.gestureUsesFn = gestureUsesFn
        self.autoArmEnabled = autoArmEnabled
    }
}

/// The colour of a state follows whether it is what it should be, not whether it is on.
public enum SettingsStatus {
    /// - The sleep lock and the Login Items approval are to be fixed whenever they are missing.
    /// - A permission that is missing is refused (red) only while something that is switched on needs it:
    ///   Screen Recording while the effect is on, Input Monitoring while the gesture watches Fn,
    ///   notifications always. Otherwise it is only worth knowing.
    /// - A hook that is missing is to be fixed only while auto-arm is on with no hook at all to listen to.
    public static func severity(of grant: SettingsGrant, held: Set<SettingsGrant>, context: SettingsContext) -> StatusSeverity {
        if held.contains(grant) { return .good }
        switch grant {
        case .sleepLock, .loginItems:
            return .warning
        case .screenRecording:
            return context.effectEnabled ? .failure : .info
        case .inputMonitoring:
            return context.gestureEnabled && context.gestureUsesFn ? .failure : .info
        case .notifications:
            return .failure
        case .claudeHooks, .zshHook:
            return autoArmIsDeaf(held: held, context: context) ? .warning : .info
        }
    }

    /// Auto-arm is on and neither hook is set up: nothing can tell the app that work is running.
    public static func autoArmIsDeaf(held: Set<SettingsGrant>, context: SettingsContext) -> Bool {
        context.autoArmEnabled && !held.contains(.claudeHooks) && !held.contains(.zshHook)
    }
}
