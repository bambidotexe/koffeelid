import Foundation

/// What the user selected. `armed` keeps the Mac awake with the lid closed; `caffeinate` adds
/// "never let the display sleep" on top of it. Every mode other than `off` holds the kernel flag.
public enum ArmMode: String, CaseIterable, Equatable {
    case off, armed, caffeinate

    public var keepsDisplayOn: Bool { self == .caffeinate }
}

/// Pure transition rules for the menu bar right-click and the two keyboard shortcuts.
public enum ModeCycle {
    /// Seconds after a mode change during which a right-click keeps cycling instead of turning off.
    public static let defaultWindow: TimeInterval = 3

    /// Off → Armed → Armed + Caffeinate → Off. An armed mode that has stood for `window` seconds or
    /// more goes straight to Off, so a stray right-click on a long-running session always disarms.
    public static func nextOnRightClick(current: ArmMode, sinceLastChange: TimeInterval, window: TimeInterval = defaultWindow) -> ArmMode {
        switch current {
        case .off: return .armed
        case .armed: return sinceLastChange < window ? .caffeinate : .off
        case .caffeinate: return .off
        }
    }

    /// A shortcut targets one mode: in that mode it turns off, in any other mode it switches to it.
    public static func nextOnShortcut(target: ArmMode, current: ArmMode) -> ArmMode {
        current == target ? .off : target
    }
}
