import CoreGraphics
import Foundation

/// Seconds since the user last touched the keyboard, trackpad or mouse, from the HID event stream
/// (`CGEventSource.secondsSinceLastEventType`; no permission needed, unlike a global event monitor).
/// A remote session (ssh, screen sharing keeps its own events out of this) generates none.
enum LocalInputMonitor {
    private static let types: [CGEventType] = [
        .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .scrollWheel,
    ]
    static func secondsSinceLastInput() -> TimeInterval {
        types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }
    /// The moment of the last input, or nil when there was none this session.
    static func lastInputDate(now: Date = Date()) -> Date? {
        let s = secondsSinceLastInput()
        return s.isFinite ? now.addingTimeInterval(-s) : nil
    }
}
