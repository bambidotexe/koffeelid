import AppKit

/// Window with a standard (opaque) title bar and no title text: the page starts below the bar, so
/// scrolling never runs under the traffic lights. The page is the content view controller (so it is
/// retained and gets viewWillAppear); it paints its own background.
final class SettingsWindow: NSWindow {
    init(page: PaneViewController) {
        let size = NSSize(width: SettingsForm.width + 2 * SettingsForm.margin, height: 400)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        titleVisibility = .hidden
        isMovableByWindowBackground = true; isReleasedWhenClosed = false
        contentViewController = page
        setContentSize(page.preferredContentSize)
        center()
    }
}

final class SettingsWindowController: NSWindowController {
    private var advanced: AdvancedWindowController?

    init() {
        let vc = SettingsViewController()
        let w = SettingsWindow(page: vc)
        super.init(window: w)
        vc.onOpenAdvanced = { [weak self] in self?.showAdvanced() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func showAdvanced() {
        if advanced == nil { advanced = AdvancedWindowController() }
        advanced?.showWindow(nil)
        advanced?.window?.makeKeyAndOrderFront(nil)
    }

}

final class AdvancedWindowController: NSWindowController {
    private(set) var page = AdvancedViewController()
    init() { super.init(window: SettingsWindow(page: page)) }
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild the page from the current preferences (after "Reset to defaults").
    func reload() {
        page = AdvancedViewController()
        window?.contentViewController = page
        window?.setContentSize(page.preferredContentSize)
    }
}

/// Base class: pages build their form once in `build(_:)`, paint the translucent background and
/// report the size that fits their content.
class PaneViewController: NSViewController {
    let form = SettingsForm()
    private let effect = NSVisualEffectView()

    override func loadView() {
        let container = NSView()
        // Adaptive, mostly opaque material (light and dark) instead of a forced dark HUD.
        effect.material = .underWindowBackground; effect.blendingMode = .behindWindow; effect.state = .active
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.verticalScrollElasticity = .allowed
        let document = NSView()
        document.addSubview(form.stack)
        scroll.documentView = document
        for v: NSView in [effect, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: container.leadingAnchor), v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                                         v.topAnchor.constraint(equalTo: container.topAnchor), v.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        }
        view = container
        build(form)
        form.stack.layoutSubtreeIfNeeded()
        let width = SettingsForm.width + 2 * SettingsForm.margin
        let height = form.stack.fittingSize.height + 2 * SettingsForm.margin
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        form.stack.frame = NSRect(x: SettingsForm.margin, y: SettingsForm.margin, width: SettingsForm.width, height: form.stack.fittingSize.height)
        form.stack.translatesAutoresizingMaskIntoConstraints = true
        form.stack.autoresizingMask = []
        // Never taller than the visible screen (menu bar and Dock excluded): the page scrolls instead of
        // hiding rows behind the Dock. A menu-bar app has no key window yet, so `NSScreen.main` can be nil.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let maxHeight = (screen?.visibleFrame.height ?? 700) - 40
        preferredContentSize = NSSize(width: width, height: min(height, maxHeight))
    }
    func build(_ f: SettingsForm) {}
}
