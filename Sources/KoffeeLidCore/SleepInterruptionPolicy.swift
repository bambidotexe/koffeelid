import Foundation

/// What a `willSleep` notification means while KoffeeLid is armed.
public enum SleepInterruption: Equatable {
    /// The kernel evaluated the closed lid with our lid-sleep bit gone. On Apple silicon powerd owns
    /// the same root-domain bit (`kClamshellSleepDisablePowerd`) and rewrites it whenever it re-evaluates
    /// its own clamshell policy (charger attach via the PowerChime assertion, display hot-plug, desktop
    /// mode), so the "sleep" is a side effect of that rewrite, not a request by anyone. The session is held.
    case lidSleepOverride
    /// Something asked for sleep: `pmset sleepnow`, the Apple menu, another app. The session ends.
    case external
}

public enum SleepInterruptionPolicy {
    /// `IOPMrootDomain`'s "Last Sleep Reason" for a clamshell-evaluation sleep (xnu `kIOPMClamshellSleepKey`).
    public static let clamshellReason = "Clamshell Sleep"

    public static func classify(reason: String?, lidClosed: Bool) -> SleepInterruption {
        reason == clamshellReason && lidClosed ? .lidSleepOverride : .external
    }
}

/// Bounds how often the hold may repeat. Every override costs the user a dark-wake blip, and a system
/// component toggling powerd's policy in a loop could otherwise cycle the Mac forever; past
/// `maxOverrides` inside `window` the coordinator stops holding and disarms like an external sleep.
public struct SleepOverrideGuard {
    public var window: TimeInterval
    public var maxOverrides: Int
    private var stamps: [TimeInterval] = []

    public init(window: TimeInterval = 120, maxOverrides: Int = 3) {
        self.window = window; self.maxOverrides = maxOverrides
    }

    /// Records an override at `now` (uptime) and returns whether holding the session is still allowed.
    public mutating func record(now: TimeInterval) -> Bool {
        stamps = stamps.filter { now - $0 < window }
        stamps.append(now)
        return stamps.count <= maxOverrides
    }
}

/// The root-backed sleep lock: `pmset disablesleep 1` sets `SleepDisabled` on the root domain, which the
/// kernel checks before *every* sleep request (`checkSystemSleepAllowed`, "user-space sleep kill switch"),
/// clamshell evaluations included. `pmset` needs root, so the app runs it through `sudo -n` and relies on
/// this sudoers rule, which the user installs once.
public enum SleepLockSetup {
    public static let pmsetPath = "/usr/bin/pmset"
    public static let sudoersFile = "/etc/sudoers.d/koffeelid"

    public static func pmsetArguments(engaged: Bool) -> [String] {
        [pmsetPath, "disablesleep", engaged ? "1" : "0"]
    }

    public static func sudoersRule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: \(pmsetArguments(engaged: true).joined(separator: " ")), \(pmsetArguments(engaged: false).joined(separator: " "))"
    }

    /// The one-liner `script/install.sh` and the docs print.
    public static func installCommand(user: String) -> String {
        "echo \"\(sudoersRule(user: user))\" | sudo tee \(sudoersFile) >/dev/null && sudo chmod 0440 \(sudoersFile) && sudo visudo -cf \(sudoersFile)"
    }
}

extension SleepLockSetup {
    /// Shell run as root (macOS administrator-password dialog, `do shell script … with administrator
    /// privileges`): validate the rule in a temp file with `visudo -c` before it lands in sudoers.d.
    public static func privilegedInstallScript(user: String) -> String {
        "t=$(mktemp) && printf '%s\\n' '\(sudoersRule(user: user))' > \"$t\" && chmod 0440 \"$t\" && visudo -cf \"$t\" && mv \"$t\" \(sudoersFile)"
    }

    public static var privilegedRemoveScript: String { "rm -f \(sudoersFile)" }

    /// Escapes a shell line for use inside an AppleScript string literal.
    public static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
