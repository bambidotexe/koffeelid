import AppKit
import KoffeeLidCore

final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onRightClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    /// What the bar shows: the empty cup, the armed cup, the round-eyed cup, or (auto: an activity arm,
    /// which the menu still lists as Off) the armed cup wearing the badges of the apps at work.
    enum State {
        case off, auto, armed, caffeinate
        var glyph: MugShape.State {
            switch self { case .off: return .off; case .auto, .armed: return .armed; case .caffeinate: return .caffeinate }
        }
    }
    var state: State = .off { didSet { render() } }
    /// The app icons the auto-armed cup wears, front first; every other state ignores them.
    var badges: [NSImage] = [] { didSet { render() } }
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
        let badged = state == .auto && !badges.isEmpty
        button.image = badged ? badgedMugImage(badges: badges, warning: warning) : Self.mugImage(state: state.glyph)
        // A template image is tinted by the bar, orange for the warning. The badged cup carries the icons'
        // colours, so it is no template: it draws its own ink, orange itself for the warning.
        button.contentTintColor = warning ? .systemOrange : nil
        button.title = angleText.map { " " + $0 } ?? ""
        button.imagePosition = angleText == nil ? .imageOnly : .imageLeft
        var tip = "KoffeeLid — " + Self.tooltipTitle(for: state)
        if standingBy { tip += " · " + L("Standing by: external display") }
        button.toolTip = tip
    }

    static func tooltipTitle(for state: State) -> String {
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

    /// The auto-arm line: the title followed by the badges of the apps at work, 16 pt each, in the cup's order.
    static func menuTitle(_ text: String, badges: [NSImage]) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: text, attributes: [.font: font])
        for (i, badge) in badges.enumerated() {
            let attachment = NSTextAttachment()
            attachment.image = badge
            attachment.bounds = NSRect(x: 0, y: -4, width: 16, height: 16)
            title.append(NSAttributedString(string: i == 0 ? "  " : " ", attributes: [.font: font]))
            title.append(NSAttributedString(attachment: attachment))
        }
        return title
    }

    private static var cache: [MugShape.State: NSImage] = [:]

    /// The KoffeeLid mug (`MugShape`, from the SVG artwork): an empty cup when off, coffee and closed eyes
    /// when armed, round eyes for Armed + screen on. 22 pt wide (the cup is wider than tall) for the 22 pt
    /// menu bar. The button centres the image, so 1 pt of headroom above the cup sits it half a point low
    /// (an even image height also keeps the button's offset on a whole point), matching the neighbouring
    /// glyphs. Drawn opaque: a template image, the bar tints it.
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

    /// The badges: 9 pt squares (an app icon still reads at that size on a Retina bar), 3 pt apart in the
    /// stack, with 0.75 pt of cup cleared around each.
    static let badgeSide: CGFloat = 9, badgeStep: CGFloat = 3, badgeKnockout: CGFloat = 0.75

    /// The armed cup wearing the apps at work: the same cup as `mugImage(state: .armed)`, at the same place,
    /// the badges stacked from its bottom-right corner up and to the right (the first in front), the image
    /// widening to hold them. The icons carry colour, so this is no template image: the cup is drawn in
    /// the bar's own text colour, resolved at draw time so it follows the bar's appearance, or in orange
    /// for the warning.
    static func badgedMugImage(badges: [NSImage], warning: Bool) -> NSImage {
        let width: CGFloat = 22, height = width * MugShape.aspect
        let mug = NSRect(x: 0.5, y: 0.5, width: width, height: height)
        let frames = MugShape.badgeFrames(count: badges.count, in: mug, side: badgeSide, step: badgeStep)
        let right = frames.map(\.maxX).max() ?? mug.maxX
        let size = NSSize(width: ceil(right + 0.5), height: ceil(height) + 2)
        let image = NSImage(size: size, flipped: false) { _ in
            MugShape.draw(in: mug, state: .armed, ink: warning ? .systemOrange : .labelColor)
            MugShape.drawBadges(badges, frames: frames, knockout: badgeKnockout)
            return true
        }
        return image
    }

    /// The last badged cup, kept while the same icons and warning are asked for again (`render` runs on
    /// every angle sample while the angle is shown).
    private var badged: (badges: [NSImage], warning: Bool, image: NSImage)?
    private func badgedMugImage(badges: [NSImage], warning: Bool) -> NSImage {
        if let b = badged, b.warning == warning, b.badges.count == badges.count, zip(b.badges, badges).allSatisfy({ $0 === $1 }) {
            return b.image
        }
        let image = Self.badgedMugImage(badges: badges, warning: warning)
        badged = (badges, warning, image)
        return image
    }
}
