import Foundation
import Carbon.HIToolbox
import KoffeeLidCore

final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard
    var onChange: ((String) -> Void)?

    private init() {
        d.register(defaults: [
            "armWithRightClick": true, "armWithShortcut": true, "armWithCaffeinateShortcut": true, "armWithOption": true, "gestureModifier": "fn",
            "lidCloseSoundEnabled": true, "lidCloseSoundName": "blip-pop",
            "forceVolumeEnabled": true, "forceVolumeLevel": 0.6,
            "lowBatteryDisarm": true, "lowBatteryDisarmPercent": 10,
            "onboardingCompleted": false, "launchAtLogin": true, "diagnosticsEnabled": true,
            "gestureActivationDegrees": 4.0, "gestureReverseCancelDegrees": 4.0, "gestureAngleOpen": 120.0,
            "hotKeyCode": UInt32(kVK_ANSI_L), "hotKeyModifiers": UInt32(controlKey | optionKey | cmdKey),
            "caffeinateHotKeyCode": UInt32(kVK_ANSI_K), "caffeinateHotKeyModifiers": UInt32(controlKey | optionKey | cmdKey),
            "armOnActivity": false, "activityJobArmAfterSeconds": 5.0,
            "activityHoldOff.claude": 30.0 * 60, "activityHoldOff.terminal": 60.0,
        ])
    }

    private func set<T>(_ key: String, _ value: T) { d.set(value, forKey: key); onChange?(key) }

    var armWithRightClick: Bool { get { d.bool(forKey: "armWithRightClick") } set { set("armWithRightClick", newValue) } }
    var armWithShortcut: Bool { get { d.bool(forKey: "armWithShortcut") } set { set("armWithShortcut", newValue) } }
    /// ⌃⌥⌘K (Armed + screen on) can be switched off independently of ⌃⌥⌘L.
    var armWithCaffeinateShortcut: Bool { get { d.bool(forKey: "armWithCaffeinateShortcut") } set { set("armWithCaffeinateShortcut", newValue) } }
    var armWithOption: Bool { get { d.bool(forKey: "armWithOption") } set { set("armWithOption", newValue) } }
    /// Arm while a Claude Code session or a terminal command (zsh hooks) is running; disarm after the hold-off.
    var armOnActivity: Bool { get { d.bool(forKey: "armOnActivity") } set { set("armOnActivity", newValue) } }
    var activityJobArmAfterSeconds: Double { get { d.double(forKey: "activityJobArmAfterSeconds") } set { set("activityJobArmAfterSeconds", min(30, max(0, newValue))) } }
    /// Seconds between "nothing runs any more" and the auto-disarm, per kind that ran (the longest wins):
    /// Claude Code 1–120 min (default 30), a command 10 s–10 min (default 1 min). Keys `activityHoldOff.claude|terminal`.
    func activityHoldOffSeconds(_ kind: ActivityKind) -> Double { d.double(forKey: Self.holdOffKey(kind)) }
    func setActivityHoldOffSeconds(_ kind: ActivityKind, _ s: Double) {
        set(Self.holdOffKey(kind), kind == .claude ? min(120 * 60, max(60, s)) : min(600, max(10, s)))
    }
    var activityHoldOffs: [ActivityKind: TimeInterval] { Dictionary(uniqueKeysWithValues: ActivityKind.allCases.map { ($0, activityHoldOffSeconds($0)) }) }
    static func holdOffKey(_ kind: ActivityKind) -> String { "activityHoldOff." + kind.rawValue }
    /// Which key is held while closing the lid: "fn" (Globe) or "option".
    var gestureModifier: GestureModifier { get { GestureModifier(rawValue: d.string(forKey: "gestureModifier") ?? "fn") ?? .fn } set { set("gestureModifier", newValue.rawValue) } }
    var lidCloseSoundEnabled: Bool { get { d.bool(forKey: "lidCloseSoundEnabled") } set { set("lidCloseSoundEnabled", newValue) } }
    /// Falls back to the first bundled sound when the stored name is not one of the bundled sounds.
    var lidCloseSoundName: String {
        get { let n = d.string(forKey: "lidCloseSoundName") ?? ""; return LidCloseSoundPlayer.soundNames.contains(n) ? n : LidCloseSoundPlayer.soundNames[0] }
        set { set("lidCloseSoundName", newValue) }
    }
    var forceVolumeEnabled: Bool { get { d.bool(forKey: "forceVolumeEnabled") } set { set("forceVolumeEnabled", newValue) } }
    var forceVolumeLevel: Float { get { d.float(forKey: "forceVolumeLevel") } set { set("forceVolumeLevel", min(1, max(0, newValue))) } }
    var lowBatteryDisarm: Bool { get { d.bool(forKey: "lowBatteryDisarm") } set { set("lowBatteryDisarm", newValue) } }
    var lowBatteryDisarmPercent: Int { get { d.integer(forKey: "lowBatteryDisarmPercent") } set { set("lowBatteryDisarmPercent", newValue) } }
    var launchAtLogin: Bool { get { d.bool(forKey: "launchAtLogin") } set { set("launchAtLogin", newValue) } }
    var onboardingCompleted: Bool { get { d.bool(forKey: "onboardingCompleted") } set { set("onboardingCompleted", newValue) } }
    /// Off = `DiagnosticLog.log` writes nothing (the watchdog's own few lines are unaffected).
    var diagnosticsEnabled: Bool { get { d.bool(forKey: "diagnosticsEnabled") } set { set("diagnosticsEnabled", newValue) } }
    var gestureActivationDegrees: Double { get { d.double(forKey: "gestureActivationDegrees") } set { set("gestureActivationDegrees", newValue) } }
    var gestureReverseCancelDegrees: Double { get { d.double(forKey: "gestureReverseCancelDegrees") } set { set("gestureReverseCancelDegrees", newValue) } }
    var gestureAngleOpen: Double { get { d.double(forKey: "gestureAngleOpen") } set { set("gestureAngleOpen", newValue) } }
    var hotKeyCode: UInt32 { get { UInt32(d.integer(forKey: "hotKeyCode")) } set { set("hotKeyCode", Int(newValue)) } }
    var hotKeyModifiers: UInt32 { get { UInt32(d.integer(forKey: "hotKeyModifiers")) } set { set("hotKeyModifiers", Int(newValue)) } }
    /// ⌃⌥⌘K by default: toggles Armed + screen on (see `ModeCycle.nextOnShortcut`).
    var caffeinateHotKeyCode: UInt32 { get { UInt32(d.integer(forKey: "caffeinateHotKeyCode")) } set { set("caffeinateHotKeyCode", Int(newValue)) } }
    var caffeinateHotKeyModifiers: UInt32 { get { UInt32(d.integer(forKey: "caffeinateHotKeyModifiers")) } set { set("caffeinateHotKeyModifiers", Int(newValue)) } }

    var effect: EffectParameters {
        get {
            guard let data = d.data(forKey: EffectParameters.userDefaultsKey),
                  let p = try? JSONDecoder().decode(EffectParameters.self, from: data) else { return .default }
            return p.clamped()
        }
        set { set(EffectParameters.userDefaultsKey, try? JSONEncoder().encode(newValue.clamped())) }
    }
}

enum GestureModifier: String, CaseIterable {
    case fn, option
    /// Short user-facing name of the gesture, e.g. "Fn + close lid".
    var gestureName: String { self == .fn ? L("Fn + close lid") : L("Option + close lid") }
    /// The key alone, for sentences ("Hold Fn …").
    var keyName: String { self == .fn ? L("Fn") : L("Option") }
}
