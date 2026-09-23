import Foundation

/// When the lid-close sound plays again with the lid already closed: the armed Mac is being taken off the
/// desk, the charger unplugged or the displays changed, and nobody sees it. The sound is the reminder that
/// it stays awake before it goes in a bag.
///
/// While the lid is closed macOS does not remove a disconnected display from the display list until the lid
/// opens, but it does post screen-parameter changes, and they are what counts here, whatever the list says.
/// A dock unplugged with its displays and its charger sends a burst of them within about a second: after a
/// sound, every trigger is ignored for `quietSeconds`, the lid-close sound included.
public struct ClosedLidReminder {
    public enum Trigger: String { case chargerUnplugged = "charger unplugged", displaysChanged = "displays changed" }

    /// The two switches of Settings › Sound.
    public struct Switches: Equatable {
        public var chargerUnplugged: Bool
        public var displaysChanged: Bool
        public init(chargerUnplugged: Bool, displaysChanged: Bool) {
            self.chargerUnplugged = chargerUnplugged; self.displaysChanged = displaysChanged
        }
        func allows(_ t: Trigger) -> Bool { t == .chargerUnplugged ? chargerUnplugged : displaysChanged }
    }

    /// After any sound, how long every trigger is ignored.
    public static let quietSeconds: TimeInterval = 5
    /// After the lid closes, how long display changes are the close itself (the displays rearrange when the
    /// lid shuts on an external display) and not an unplug.
    public static let lidCloseSettleSeconds: TimeInterval = 5

    private var lastSound: TimeInterval?
    private var lidClosedAt: TimeInterval?
    private var wasOnBattery: Bool?

    public init() {}

    /// Every power-source reading, armed or not. True on the one that turns the charger into the battery;
    /// a missing reading forgets the previous state.
    public mutating func powerSource(_ state: BatteryState?) -> Bool {
        defer { wasOnBattery = state?.onBattery }
        return wasOnBattery == false && state?.onBattery == true
    }

    public mutating func lidClosed(now: TimeInterval) { lidClosedAt = now }

    /// The lid-close sound played.
    public mutating func soundPlayed(now: TimeInterval) { lastSound = now }

    /// Whether `trigger` plays the sound now; a yes starts the quiet window.
    public mutating func shouldPlay(_ trigger: Trigger, armed: Bool, lidClosed: Bool, switches: Switches, now: TimeInterval) -> Bool {
        guard armed, lidClosed, switches.allows(trigger) else { return false }
        if let last = lastSound, now - last < Self.quietSeconds { return false }
        if trigger == .displaysChanged, let closed = lidClosedAt, now - closed < Self.lidCloseSettleSeconds { return false }
        lastSound = now
        return true
    }
}
