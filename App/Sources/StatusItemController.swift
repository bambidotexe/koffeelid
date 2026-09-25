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
    /// The badges' view. App icons carry colour, which a template image cannot, and only the bar draws a
    /// template image in the tint it gives every icon on the wallpaper of the day: so the cup stays a
    /// template image with holes cut where the badges go, and the icons lie over the button in this view,
    /// put on the image's own rect at every change (`layoutBadges`). Clicks go through it.
    private final class BadgeView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private let badgeView = BadgeView()
    private var frameObserver: NSObjectProtocol?
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
        if let button = item.button {
            badgeView.imageScaling = .scaleNone
            badgeView.isHidden = true
            button.clipsToBounds = false                    // the badges overflow the item rather than widen it
            button.addSubview(badgeView)
            button.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                self?.layoutBadges()
            }
        }
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
        button.image = badged ? Self.badgedMugImage(count: badges.count) : Self.mugImage(state: state.glyph)
        // Both are template images: the bar tints the cup, orange for the warning; the badges keep their colours.
        button.contentTintColor = warning ? .systemOrange : nil
        badgeView.image = badged ? badgesImage(badges) : nil
        badgeView.isHidden = !badged
        layoutBadges()
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

    /// The badges: 9 pt squares (an app icon still reads at that size on a Retina bar), stacked 2 pt to the
    /// right and 4 pt up from one to the next (more up than right, so the stack stays near the cup), with
    /// 0.75 pt of cup cleared around each. The front one hangs off the cup's bottom-right corner, 3 pt to
    /// the right and 2 pt down: clear of the eyes, over the foot of the handle, its bottom half a point
    /// above the bar's edge.
    static let badgeSide: CGFloat = 9, badgeStep = NSPoint(x: 2, y: 4), badgeKnockout: CGFloat = 0.75
    static let badgeOverhang: CGFloat = 3, badgeDrop: CGFloat = 2

    /// The geometry of the badged cup with `count` badges, in the cup image's coordinates: the cup's rect
    /// and the image's size, exactly `mugImage`'s so the item never changes size and the cup never moves;
    /// the badges' frames (the first in front), which overflow the image to the right and below, into the
    /// item's own margin and the bar's; and the bottom-left of the badges' own image.
    static func badgeLayout(count: Int) -> (mug: NSRect, frames: [NSRect], size: NSSize, origin: NSPoint) {
        let width: CGFloat = 22, height = width * MugShape.aspect
        let size = NSSize(width: ceil(width) + 1, height: ceil(height) + 2)
        let mug = NSRect(x: (size.width - width) / 2, y: 0.5, width: width, height: height)
        let anchor = NSPoint(x: mug.maxX + badgeOverhang, y: mug.minY - badgeDrop)
        let frames = MugShape.badgeFrames(count: count, anchor: anchor, side: badgeSide, step: badgeStep)
        let union = frames.reduce(NSRect.null) { $0.union($1) }
        return (mug, frames, size, union.origin)
    }

    private static var badgedCache: [Int: NSImage] = [:]

    /// The armed cup with the holes of `count` badges cut (the part of each that falls on the image): a
    /// template image, the bar tints it.
    static func badgedMugImage(count: Int) -> NSImage {
        if let cached = badgedCache[count] { return cached }
        let layout = badgeLayout(count: count)
        let image = NSImage(size: layout.size, flipped: false) { _ in
            MugShape.draw(in: layout.mug, state: .armed, ink: .black)
            for frame in layout.frames { MugShape.cutBadgeHole(frame, knockout: badgeKnockout) }
            return true
        }
        image.isTemplate = true
        badgedCache[count] = image
        return image
    }

    /// The badges alone, the first in front, each in its hole: laid over the cup at `badgeLayout(count:).origin`.
    static func badgesImage(_ badges: [NSImage]) -> NSImage {
        let layout = badgeLayout(count: badges.count)
        let frames = layout.frames.map { $0.offsetBy(dx: -layout.origin.x, dy: -layout.origin.y) }
        let size = frames.reduce(NSRect.null) { $0.union($1) }.size
        return NSImage(size: size, flipped: false) { _ in
            MugShape.drawBadges(badges, frames: frames, knockout: badgeKnockout)
            return true
        }
    }

    /// The last badges image, kept while the same icons are asked for again (`render` runs on every angle
    /// sample while the angle is shown).
    private var badged: (badges: [NSImage], image: NSImage)?
    private func badgesImage(_ badges: [NSImage]) -> NSImage {
        if let b = badged, b.badges.count == badges.count, zip(b.badges, badges).allSatisfy({ $0 === $1 }) { return b.image }
        let image = Self.badgesImage(badges)
        badged = (badges, image)
        return image
    }

    /// Puts the badge view where the button draws its image, so the icons land in the holes cut for them.
    private func layoutBadges() {
        guard let button = item.button, !badgeView.isHidden, let image = badgeView.image else { return }
        var imageRect = (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds) ?? .zero
        if imageRect.isEmpty, let cup = button.image {
            imageRect = NSRect(x: (button.bounds.width - cup.size.width) / 2, y: (button.bounds.height - cup.size.height) / 2,
                               width: cup.size.width, height: cup.size.height)
        }
        // `origin` is measured from the cup image's bottom-left; the button's coordinates run from its top.
        let origin = Self.badgeLayout(count: badges.count).origin
        let y = button.isFlipped ? imageRect.maxY - origin.y - image.size.height : imageRect.minY + origin.y
        badgeView.frame = NSRect(x: imageRect.minX + origin.x, y: y, width: image.size.width, height: image.size.height)
        // The badges overflow the item into its margin; the bar's views around the button clip to their
        // bounds, and would cut the back of a stack, so none of them clips while badges show.
        var view: NSView? = button
        while let v = view, v.window?.contentView != v { v.clipsToBounds = false; view = v.superview }
    }
}
