import AppKit
import ServiceManagement
import SwiftUI
import KoffeeLidCore
import LidPlaneKit

/// What every page of the Settings window reads and writes: the preferences, and the states a page
/// reports. One instance, owned by the window, shared by the six pages.
///
/// The preferences live in UserDefaults behind `Preferences.shared`, whose `onChange` belongs to the
/// coordinator alone, so a page writes through the bindings here and they announce the change themselves.
/// The states are polled: a grant is revoked in System Settings, the lid angle comes from a sensor, the
/// activity counts from the coordinator's monitor, and none of them is pushed to this window. The window
/// starts and stops the polling; a page never does.
@MainActor
final class SettingsModel: ObservableObject {
    let prefs = Preferences.shared

    /// `SMAppService` is the source of truth for the login item: the user can revoke it in System
    /// Settings without the app ever hearing about it.
    @Published private(set) var launchAtLogin = false
    /// The grants and hooks that are there right now.
    @Published private(set) var held: Set<SettingsGrant> = []
    @Published private(set) var sensorPresent = false
    /// The last angle the sensor reported, nil while nothing has been read.
    @Published private(set) var lidAngle: Double?
    @Published private(set) var activity = ActivitySnapshot()

    private var timer: Timer?
    private var tick = 0

    /// The lid angle and the activity counts are read on every tick; everything else every
    /// `ticksPerRefresh` ticks, which is 2 s: slow enough to be free, fast enough that coming back from
    /// System Settings finds the page already right.
    private static let tickInterval: TimeInterval = 0.25
    private static let ticksPerRefresh = 8

    // MARK: Writing

    /// A binding onto one preference. `objectWillChange` goes out before the write because the value is
    /// not a published property: nothing else would redraw the page.
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self.prefs[keyPath: keyPath] },
                set: { self.objectWillChange.send(); self.prefs[keyPath: keyPath] = $0 })
    }

    /// The same onto one field of the effect's parameters, which are stored as one value. The store
    /// clamps, so what a page shows is always the value read back, never the value written.
    func effect<T>(_ keyPath: WritableKeyPath<EffectParameters, T>) -> Binding<T> {
        Binding(get: { self.prefs.effect[keyPath: keyPath] },
                set: {
                    self.objectWillChange.send()
                    var parameters = self.prefs.effect
                    parameters[keyPath: keyPath] = $0
                    self.prefs.effect = parameters
                })
    }

    /// The auto-arm hold-off of one kind of work, in seconds.
    func holdOff(_ kind: ActivityKind) -> Binding<Double> {
        Binding(get: { self.prefs.activityHoldOffSeconds(kind) },
                set: { self.objectWillChange.send(); self.prefs.setActivityHoldOffSeconds(kind, $0) })
    }

    // MARK: States

    /// The settings a state's colour depends on.
    var context: SettingsContext {
        SettingsContext(effectEnabled: prefs.effect.enabled,
                        gestureEnabled: prefs.armWithOption,
                        gestureUsesFn: prefs.gestureModifier == .fn,
                        autoArmEnabled: prefs.armOnActivity)
    }

    func holds(_ grant: SettingsGrant) -> Bool { held.contains(grant) }

    /// The mark of one grant: `yes` while it is there, `no` while it is not, coloured by `SettingsStatus`.
    func mark(_ grant: SettingsGrant, yes: String, no: String) -> StatusMark {
        StatusMark(SettingsStatus.severity(of: grant, held: held, context: context), holds(grant) ? yes : no)
    }

    /// Runs a grant's own flow (the permission dialog, the pane in System Settings, the hook installer),
    /// then re-reads everything: the flow may also have switched auto-arm on.
    func grant(_ grant: SettingsGrant) {
        item(grant)?.action(NSApp.keyWindow) { [weak self] in self?.refresh() }
    }

    /// Undoes a grant the app can undo itself: the two hooks.
    func revoke(_ grant: SettingsGrant) {
        item(grant)?.remove?(NSApp.keyWindow) { [weak self] in self?.refresh() }
    }

    private func item(_ grant: SettingsGrant) -> PermissionItem? {
        (PermissionCatalog.items + HookCatalog.items).first { $0.id == grant }
    }

    // MARK: Reading

    /// Re-reads every state, and redraws the pages: a preference may have changed behind them (a hook's
    /// set-up switches auto-arm on, a reset clears everything).
    func refresh() {
        objectWillChange.send()

        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
        // The preference mirrors the service: the coordinator registers the login item from it at launch.
        if prefs.launchAtLogin != login { prefs.launchAtLogin = login }

        let now = Set((PermissionCatalog.items + HookCatalog.items).filter { $0.granted() }.map(\.id))
        if now != held { held = now }
        // The notification grant answers asynchronously: the catalog's last answer stands until the new
        // one lands, on the main queue.
        PermissionCatalog.refreshNotifications { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let granted = PermissionCatalog.notificationsGranted
                guard granted != self.held.contains(.notifications) else { return }
                if granted { self.held.insert(.notifications) } else { self.held.remove(.notifications) }
            }
        }

        let sensor = LidAngleSensor.isPresent
        if sensor != sensorPresent { sensorPresent = sensor }

        readLive()
    }

    /// The two readings that move while the window is open.
    private func readLive() {
        let angle = KoffeeLidController.shared.lastAngle
        if angle != lidAngle { lidAngle = angle }
        let snapshot = KoffeeLidController.shared.activity.snapshot
        if snapshot != activity { activity = snapshot }
    }

    // MARK: Polling

    /// Idempotent. The lid sensor only samples while someone asks for it, so the window is one of its
    /// consumers for as long as it is up.
    func startPolling() {
        refresh()
        guard timer == nil else { return }
        KoffeeLidController.shared.lidAngleObserver?.addConsumer("settings")
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                if self.tick % Self.ticksPerRefresh == 0 { self.refresh() } else { self.readLive() }
            }
        }
    }

    /// Idempotent.
    func stopPolling() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        tick = 0
        KoffeeLidController.shared.lidAngleObserver?.removeConsumer("settings")
    }
}

extension StatusMark {
    /// The kit's mark for one of Core's five severities.
    init(_ severity: StatusSeverity, _ text: String) {
        switch severity {
        case .good: self = .good(text)
        case .info: self = .info(text)
        case .warning: self = .warning(text)
        case .failure: self = .failure(text)
        case .busy: self = .busy(text)
        }
    }
}

/// How the window writes a number beside a slider, unit included.
enum SettingsFormat {
    static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }
    /// A value that is already a percentage.
    static func wholePercent(_ value: Double) -> String { String(format: L("%d%%"), Int(value.rounded())) }
    /// A strength where 1 is 100 %.
    static func percent(_ value: Double) -> String { wholePercent(value * 100) }
    static func offOrPercent(_ value: Double) -> String { value == 0 ? L("Off") : percent(value) }
    static func minutes(_ value: Double) -> String { String(format: L("%d min"), Int(value.rounded())) }
    static func seconds(_ value: Double) -> String { String(format: L("%d s"), Int(value.rounded())) }
}
