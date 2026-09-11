import AppKit

/// Click-through panel that covers the whole built-in display, menu bar included: while the plane folds,
/// the black backdrop must hide the menu bar (our own status item, the screen-recording indicator) so
/// nothing static sits above the moving desktop. `.screenSaver` is above the menu bar and status items but
/// below the lock screen and shielding windows.
final class EffectOverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = 0
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
