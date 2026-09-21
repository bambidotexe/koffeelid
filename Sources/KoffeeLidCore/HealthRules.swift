import Foundation

/// The rules that turn what was found into a level. Every page that reports one of these states reads it
/// from here, so the System page's permission row and the Health page's agree.
public enum HealthRules {
    /// A macOS permission, or something set up outside KoffeeLid that a feature needs (the sleep lock, the
    /// watchdog agent, the hooks): green while it is in place; missing, **red when the onboarding marks it
    /// required** (a closed Mac cannot be kept awake safely without it) and orange otherwise (the feature
    /// that needs it cannot work, and the rest can). Never blue.
    public static func grant(held: Bool, required: Bool) -> HealthLevel {
        if held { return .good }
        return required ? .failure : .warning
    }

    /// A switch of KoffeeLid's own (the lid gesture, the lid effect, auto-arm): on is green, off is the state
    /// the user asked for, blue.
    public static func preference(on: Bool) -> HealthLevel {
        on ? .good : .info
    }

    /// Open at Login. Off is the user's choice and only worth knowing; switched off in System Settings while
    /// the app asked for it is a login that will not happen, which the user did not choose here.
    public static func loginItem(_ state: LoginItemState) -> HealthLevel {
        switch state {
        case .enabled: .good
        case .disabled: .info
        case .needsApproval: .warning
        }
    }

    /// A crash the app came back from still cost the user whatever it was doing, so any crash in the window
    /// is worth a look; none is green.
    public static func crashes(_ count: Int) -> HealthLevel {
        count == 0 ? .good : .warning
    }

    /// Running out of a disk image, or out of the read-only copy macOS makes of an app launched from where
    /// it was downloaded, is running an app that is not installed: it goes when the image is ejected, and an
    /// update cannot replace it. Any other folder is a choice.
    public static func location(_ location: AppLocation) -> HealthLevel {
        switch location {
        case .applications: .good
        case .elsewhere: .info
        case .diskImage, .temporaryCopy: .warning
        }
    }

    /// macOS's lid sleep, which the kernel flag turns off. Off while armed and on while not is as it should
    /// be. On while armed is an arm that holds nothing: red. Still off after the arm ended is a Mac that will
    /// not sleep when its lid closes, which KoffeeLid keeps retrying: orange, as the menu bar cup is.
    public static func lidSleep(armed: Bool, flagSet: Bool, restorePending: Bool) -> HealthLevel {
        if restorePending { return .warning }
        if armed { return flagSet ? .good : .failure }
        return flagSet ? .warning : .good
    }

    /// The display list. Unreadable, every arm is refused (`ArmingPolicy`); otherwise a count worth knowing.
    public static func displays(_ topology: DisplayTopology) -> HealthLevel {
        topology.verified ? .info : .failure
    }

    /// The battery, against the low-battery rail. At or under the level on battery with the rail on, nothing
    /// arms (`ArmingPolicy`): red. Otherwise it is a reading.
    /// A battery under the low-battery rail refuses every arm, which is the rail doing the job the user set
    /// it for rather than KoffeeLid failing: orange, and it clears on its own once the Mac is plugged in.
    public static func battery(_ state: BatteryState, railOn: Bool, railPercent: Int) -> HealthLevel {
        blocksArming(state, railOn: railOn, railPercent: railPercent) ? .warning : .info
    }

    static func blocksArming(_ state: BatteryState, railOn: Bool, railPercent: Int) -> Bool {
        railOn && state.onBattery && state.percent <= railPercent
    }

    /// Serious or critical thermal pressure refuses every arm and ends a running one (`ArmingPolicy`): a
    /// safety of KoffeeLid's doing its job, not KoffeeLid failing, so orange, and it clears as the Mac cools.
    public static func thermal(_ level: ThermalLevel) -> HealthLevel {
        level >= .serious ? .warning : .good
    }

    /// The lid-angle sensor: the gesture and the effect need it, and everything else works without it.
    public static func lidSensor(present: Bool) -> HealthLevel {
        present ? .good : .warning
    }
}

extension HealthRules {
    /// Whether a file in `~/Library/Logs/DiagnosticReports` is a crash report of the process named
    /// `process`: the name, a dash, the date the system stamps (`KoffeeLid-2026-09-21-101010.ips`), and the
    /// extension of a crash report old or new. A user fault of the same process (`ExcUserFault_…`), or
    /// another process whose name merely starts the same way (`KoffeeLidWatchdog-…`), is not.
    public static func isCrashReport(fileName: String, process: String) -> Bool {
        guard fileName.hasPrefix(process + "-"), fileName.hasSuffix(".ips") || fileName.hasSuffix(".crash")
        else { return false }
        let stamp = fileName.dropFirst(process.count + 1)
        // yyyy-MM-dd-HHmmss, digits where the date's digits go.
        let pattern = Array("0000-00-00-000000")
        guard stamp.count > pattern.count else { return false }
        return zip(stamp, pattern).allSatisfy { char, slot in slot == "-" ? char == "-" : char.isASCII && char.isNumber }
    }

    /// Where a bundle is, from its path. `home` is the user's home folder; `readOnlyVolume` is whether the
    /// volume the bundle is on is mounted read-only, which is what a disk image is.
    public static func location(bundlePath: String, home: String, readOnlyVolume: Bool) -> AppLocation {
        if bundlePath.contains("/AppTranslocation/") { return .temporaryCopy }
        if readOnlyVolume { return .diskImage }
        let folder = (bundlePath as NSString).deletingLastPathComponent
        if folder == "/Applications" || folder == (home as NSString).appendingPathComponent("Applications") {
            return .applications
        }
        return .elsewhere(folder: (folder as NSString).lastPathComponent)
    }
}

/// What `SMAppService` says about the app as a login item, in the app's own words.
public enum LoginItemState: Equatable {
    case enabled
    /// Not registered: the switch is off, which is the user's to decide.
    case disabled
    /// Registered, then switched off in System Settings › General › Login Items.
    case needsApproval
}

/// Where the running bundle is.
public enum AppLocation: Equatable {
    /// `/Applications` or `~/Applications`.
    case applications
    /// A folder of the user's choosing, named by its last component.
    case elsewhere(folder: String)
    /// A read-only volume: the disk image it came in.
    case diskImage
    /// The randomised read-only copy macOS runs a quarantined app from (App Translocation).
    case temporaryCopy
}

/// The crash reports macOS wrote for a process. They are the user's own files, readable without any
/// permission, and the one record of a crash the app itself cannot keep: it was not running to write it.
public enum CrashReports {
    /// Where macOS writes a user process's crash reports, and the folder it moves them to once they have
    /// been read or sent.
    public static var folders: [URL] {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// When each crash report of `process` written after `since` was written, newest first. A folder that
    /// cannot be read counts nothing: the Health page then says there was no crash, which is what the only
    /// evidence says.
    public static func recent(process: String, since: Date, in folders: [URL] = folders) -> [Date] {
        var dates: [Date] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where HealthRules.isCrashReport(fileName: file.lastPathComponent, process: process) {
                guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, date > since else { continue }
                dates.append(date)
            }
        }
        return dates.sorted(by: >)
    }
}
