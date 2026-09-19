import AppKit
import KoffeeLidCore

final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onRightClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    /// Which glyph: off, auto (an activity arm, which the menu still lists as Off), armed, armed + screen on.
    var state: MugShape.State = .off { didSet { render() } }
    /// The kernel flag could not be cleared; the icon turns orange until it is.
    var warning = false { didSet { render() } }
    /// Armed with an external display connected: the arm stands, the built-in-screen behaviours wait.
    var standingBy = false { didSet { render() } }
    var angleText: String? { didSet { render() } }
    /// "Show in menu bar": the item stays alive and keeps its state, `isVisible` is what the bar reads.
    /// Set from the preference at construction, before the item can draw once.
    var visible: Bool { didSet { item.isVisible = visible } }

    init(visible: Bool) {
        self.visible = visible
        super.init()
        item.isVisible = visible
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        render()
    }

    @objc private func clicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { onRightClick?(); return }
        guard let menu = menuProvider?() else { return }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    static func title(for mode: ArmMode) -> String {
        switch mode { case .off: return L("Off"); case .armed: return L("Armed"); case .caffeinate: return L("Armed + screen on") }
    }

    private func render() {
        guard let button = item.button else { return }
        button.image = Self.mugImage(state: state)
        // The image stays a template: AppKit only tints template images, so the orange warning needs it.
        button.contentTintColor = warning ? .systemOrange : nil
        button.title = angleText.map { " " + $0 } ?? ""
        button.imagePosition = angleText == nil ? .imageOnly : .imageLeft
        var tip = "KoffeeLid — " + Self.tooltipTitle(for: state)
        if standingBy { tip += " · " + L("Standing by: external display") }
        button.toolTip = tip
    }

    static func tooltipTitle(for state: MugShape.State) -> String {
        switch state { case .off: return L("Off"); case .auto: return L("Auto-armed"); case .armed: return L("Armed"); case .caffeinate: return L("Armed + screen on") }
    }

    /// A menu title followed by the state's cup in grey, so the menu explains the menu bar glyphs
    /// ("Armed ☕"). Inline after the label: menu items only place images on the left.
    static func menuTitle(_ text: String, glyph state: MugShape.State) -> NSAttributedString {
        let width: CGFloat = 16, height = (width * MugShape.aspect).rounded()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { r in
            MugShape.draw(in: r, state: state, ink: .secondaryLabelColor)   // resolved per appearance at draw time
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -2, width: width, height: height)
        let title = NSMutableAttributedString(string: text + "  ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(attachment: attachment))
        return title
    }

    private static var cache: [MugShape.State: NSImage] = [:]

    /// The KoffeeLid mug (`MugShape`, from the SVG artwork): an empty cup when off, coffee and closed eyes
    /// when auto-armed, sleepy eyes when armed, round eyes for Armed + screen on. 22 pt wide (the cup is
    /// wider than tall) for the 22 pt menu bar. The button centres the image, so 1 pt of headroom above
    /// the cup sits it half a point low (an even image height also keeps the button's offset on a whole
    /// point), matching the neighbouring glyphs. Drawn opaque: a template image, the bar tints it.
    static func mugImage(state: MugShape.State) -> NSImage {
        if let cached = cache[state] { return cached }
        let width: CGFloat = 22, height = width * MugShape.aspect
        let size = NSSize(width: ceil(width) + 1, height: ceil(height) + 2)
        let image = NSImage(size: size, flipped: false) { _ in
            MugShape.draw(in: NSRect(x: (size.width - width) / 2, y: 0.5, width: width, height: height), state: state, ink: .black)
            return true
        }
        image.isTemplate = true
        cache[state] = image
        return image
    }
}
