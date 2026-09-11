import AppIntents
import KoffeeLidCore

@MainActor private func modeDialog() -> IntentDialog {
    IntentDialog(stringLiteral: "KoffeeLid: " + KoffeeLidController.shared.statusLine())
}

struct ArmIntent: AppIntent {
    static var title: LocalizedStringResource = "Arm KoffeeLid"
    static var description = IntentDescription("Keep this Mac awake with the lid closed and the built-in display off.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let d = KoffeeLidController.shared.setMode(.armed, source: .intent)
        return .result(dialog: d == .allowed ? modeDialog() : "KoffeeLid did not arm.")
    }
}
struct CaffeinateIntent: AppIntent {
    static var title: LocalizedStringResource = "Arm KoffeeLid + screen on"
    static var description = IntentDescription("Arm KoffeeLid and keep the display awake indefinitely.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let d = KoffeeLidController.shared.setMode(.caffeinate, source: .intent)
        return .result(dialog: d == .allowed ? modeDialog() : "KoffeeLid did not arm.")
    }
}
struct TurnOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn KoffeeLid Off"
    static var description = IntentDescription("Let this Mac sleep normally when the lid closes.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        KoffeeLidController.shared.setMode(.off, source: .intent); return .result(dialog: modeDialog())
    }
}
struct ToggleArmedIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle KoffeeLid"
    static var description = IntentDescription("Off ↔ Armed. From Armed + screen on, goes to Armed.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        KoffeeLidController.shared.perform(.toggleArmed, source: .intent); return .result(dialog: modeDialog())
    }
}
struct ToggleCaffeinateIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle KoffeeLid + screen on"
    static var description = IntentDescription("Off ↔ Armed + screen on. From Armed, goes to Armed + screen on.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        KoffeeLidController.shared.perform(.toggleCaffeinate, source: .intent); return .result(dialog: modeDialog())
    }
}
struct StatusIntent: AppIntent {
    static var title: LocalizedStringResource = "KoffeeLid Status"
    static var description = IntentDescription("Report the current KoffeeLid mode: off, armed or armed + screen on.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        .result(value: KoffeeLidController.shared.mode.rawValue, dialog: modeDialog())
    }
}
struct KoffeeLidShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ArmIntent(), phrases: ["Arm \(.applicationName)"], shortTitle: "Arm", systemImageName: "laptopcomputer.slash")
        AppShortcut(intent: CaffeinateIntent(), phrases: ["\(.applicationName) screen on"], shortTitle: "Screen on", systemImageName: "mug.fill")
        AppShortcut(intent: TurnOffIntent(), phrases: ["Turn off \(.applicationName)"], shortTitle: "Off", systemImageName: "laptopcomputer")
        AppShortcut(intent: ToggleArmedIntent(), phrases: ["Toggle \(.applicationName)"], shortTitle: "Toggle", systemImageName: "switch.2")
        AppShortcut(intent: ToggleCaffeinateIntent(), phrases: ["Toggle \(.applicationName) screen on"], shortTitle: "Toggle screen on", systemImageName: "mug")
        AppShortcut(intent: StatusIntent(), phrases: ["\(.applicationName) status"], shortTitle: "Status", systemImageName: "info.circle")
    }
}
