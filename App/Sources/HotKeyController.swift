import Carbon.HIToolbox
import AppKit

/// Two global shortcuts: ⌃⌥⌘L targets Armed, ⌃⌥⌘K targets Armed + screen on. Each is registered only
/// while its preference (`armWithShortcut` / `armWithCaffeinateShortcut`) is on.
final class HotKeyController {
    enum Key: UInt32 { case armed = 1, caffeinate = 2 }

    private let prefs: Preferences
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onPressed: ((Key) -> Void)?

    init(prefs: Preferences) { self.prefs = prefs }
    deinit { unregister() }

    @discardableResult
    func register() -> Bool {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let key = Key(rawValue: id.id) { Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue().onPressed?(key) }
            return noErr
        }, 1, &spec, selfPtr, &handler)
        var ok = true
        var wanted: [(Key, UInt32, UInt32)] = []
        if prefs.armWithShortcut { wanted.append((.armed, prefs.hotKeyCode, prefs.hotKeyModifiers)) }
        if prefs.armWithCaffeinateShortcut { wanted.append((.caffeinate, prefs.caffeinateHotKeyCode, prefs.caffeinateHotKeyModifiers)) }
        for (key, code, mods) in wanted {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4B46_4C44) /* KFLD */, id: key.rawValue)
            let status = RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else { DiagnosticLog.shared.log("hotkey \(key) registration FAILED (status \(status))"); ok = false }
        }
        return ok
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }

    static func describe(code: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        let names: [UInt32: String] = [UInt32(kVK_ANSI_L): "L", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_K): "K", UInt32(kVK_Space): "Space",
                                       UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6"]
        return s + (names[code] ?? "key \(code)")
    }
}
