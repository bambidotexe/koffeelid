import AppKit
import ServiceManagement
import KoffeeLidCore

/// Four pages: the pitch, one permissions page (every macOS grant the app needs, required ones
/// flagged), one hooks page (auto-arm on activity: Claude Code and terminal), and "All set". Page views
/// are rebuilt on every render so their state is always current.
///
/// An ordinary window at the normal level. It comes up in front because it is the last window to open, and
/// from then on it takes its turn like any other: a permission dialog, the administrator dialog and System
/// Settings all open over it and stay there until the user leaves them, and the wizard keeps its place
/// underneath. The app is activated once, when the window opens, and never again from here.
///
/// Nothing tells an app that a grant was made in System Settings, so the two list pages poll every
/// `pollInterval` the way the Settings window does, and rebuild only when a grant has actually moved.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var step = 0
    /// The espresso brown of the mug; used to accent one word of the headline.
    private static let brand = NSColor(srgbRed: 0.42, green: 0.25, blue: 0.15, alpha: 1)
    private var observers: [NSObjectProtocol] = []
    /// Whether another window of the app still needs it active once the wizard goes away. Injected, as
    /// `SettingsWindow`'s is: an accessory app with no window left is still the active application, which
    /// would send the user's keystrokes nowhere.
    var othersNeedUsActive: @MainActor () -> Bool = { false }

    /// The grants and hooks the pages were last drawn from. Rebuilding the view tree on every tick would
    /// drop the focus ring and fight the user's clicks, so a tick that moved nothing draws nothing.
    private var drawnGrants: Set<SettingsGrant> = []
    private var poll: Timer?
    /// Slow enough to be free, fast enough that coming back from System Settings finds the page already right.
    private static let pollInterval: TimeInterval = 2

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "KoffeeLid"; w.center(); w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.contentView = NSView()
        super.init(window: w)
        w.delegate = self
        // Coming back from System Settings: refresh the grants. The poll covers the window that is already
        // key and never sees this edge.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in self?.refreshGrants() })
        // The app coming forward brings the wizard with it, the way any app's window does.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.comeForward() })
        refreshGrants()
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        poll?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startPolling()
    }

    /// The wizard back in front of the app's own windows, and only while it is the app's one window, so it
    /// never lands on top of Settings or the update window. Never `NSApp.activate(ignoringOtherApps:)`:
    /// that is what used to pull the wizard over the System Settings window it had just opened.
    private func comeForward() {
        guard let window, window.isVisible, !othersNeedUsActive() else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        if !othersNeedUsActive() { NSApp.deactivate() }
    }

    // MARK: pages

    private func render() {
        guard let window, let content = window.contentView else { return }
        drawnGrants = currentGrants()
        content.subviews.forEach { $0.removeFromSuperview() }
        let page: NSView
        let height: CGFloat
        switch step {
        case 0: page = introPage(); height = 440
        case 1: page = permissionsPage(); height = 560
        case 2: page = hooksPage(); height = 440
        default: page = finalPage(); height = 400
        }
        var frame = window.frame
        let dy = height - content.frame.height
        frame.origin.y -= dy; frame.size.height += dy
        window.setFrame(frame, display: true, animate: window.isVisible)
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor), page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.topAnchor.constraint(equalTo: content.topAnchor), page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func introPage() -> NSView {
        let highlights = NSStackView(); highlights.spacing = 8
        for (symbol, text) in [("terminal", L("Claude Code & agents")), ("arrow.down.circle", L("Downloads")), ("server.rack", L("Servers & builds"))] {
            highlights.addArrangedSubview(Self.pill(symbol: symbol, text: text))
        }
        highlights.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
        return hero(title: L("Your agents keep working. Lid closed."),
                    body: L("Close the MacBook and walk away: Claude Code, builds, servers and downloads keep running on a dark, silent display. Open the lid and your Mac locks."),
                    extra: highlights, button: L("Continue"))
    }

    private func finalPage() -> NSView {
        hero(title: L("All set"),
             body: String(format: L("Look for the mug in your menu bar, at the top right. Hold %@ and close the lid anytime to keep working."), Preferences.shared.gestureModifier.keyName),
             extra: nil, button: L("Finish"))
    }

    private func hero(title: String, body: String, extra: NSView?, button: String) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.heightAnchor.constraint(equalToConstant: 104).isActive = true
        let t = NSTextField(wrappingLabelWithString: "")
        // Selectable labels enter the field editor on click and lose their attributes.
        t.isSelectable = false; t.allowsEditingTextAttributes = true
        t.font = .systemFont(ofSize: 26, weight: .bold); t.alignment = .center
        t.attributedStringValue = Self.accented(title, word: L("agents"))
        t.preferredMaxLayoutWidth = 440; t.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
        let b = NSTextField(wrappingLabelWithString: body); b.isSelectable = false
        b.font = .systemFont(ofSize: 14); b.alignment = .center; b.preferredMaxLayoutWidth = 440; b.textColor = .secondaryLabelColor
        let next = NSButton(title: button, target: nil, action: nil)
        next.bezelStyle = .rounded; next.keyEquivalent = "\r"; next.actionHandler = { [weak self] in self?.advance() }
        let stack = NSStackView(views: [icon, t, b] + (extra.map { [$0] } ?? []) + [next])
        stack.orientation = .vertical; stack.spacing = 18; stack.setCustomSpacing(10, after: t)
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 40, bottom: 36, right: 40)
        return stack
    }

    private func permissionsPage() -> NSView {
        let permissions = PermissionCatalog.items
        let allRequired = permissions.filter(\.required).allSatisfy { $0.granted() }
        return listPage(header: L("Permissions"),
                        intro: L("KoffeeLid needs a few things from macOS. Items marked with a warning are required for a closed Mac to stay awake safely."),
                        items: permissions, continueTitle: allRequired ? L("Continue") : L("Skip"))
    }

    private func hooksPage() -> NSView {
        let hooks = HookCatalog.items
        let anySetUp = hooks.contains { $0.granted() }
        return listPage(header: L("Arm while you work"),
                        intro: L("Optional. Let KoffeeLid arm itself while Claude Code or a terminal command is running, and disarm a minute after nothing is. Setting up either turns auto-arm on; both can be changed later in Settings."),
                        items: hooks, continueTitle: anySetUp ? L("Continue") : L("Skip"))
    }

    private func listPage(header: String, intro: String, items: [PermissionItem], continueTitle: String) -> NSView {
        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = .systemFont(ofSize: 22, weight: .bold)
        let introLabel = NSTextField(wrappingLabelWithString: intro)
        introLabel.font = .systemFont(ofSize: 13); introLabel.textColor = .secondaryLabelColor; introLabel.preferredMaxLayoutWidth = 460

        let list = NSStackView(); list.orientation = .vertical; list.spacing = 12; list.alignment = .leading
        for (i, p) in items.enumerated() {
            if i > 0 { let sep = NSBox(); sep.boxType = .separator; list.addArrangedSubview(sep); sep.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
            list.addArrangedSubview(row(for: p))
        }
        list.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }

        let skip = NSButton(title: continueTitle, target: nil, action: nil)
        skip.bezelStyle = .rounded; skip.keyEquivalent = "\r"; skip.actionHandler = { [weak self] in self?.advance() }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, skip])

        let stack = NSStackView(views: [headerLabel, introLabel, list, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.setCustomSpacing(20, after: introLabel)
        stack.setCustomSpacing(24, after: list)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 40, bottom: 28, right: 40)
        // Width constraints only once every view shares the stack as ancestor.
        list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -80).isActive = true
        footer.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        return stack
    }

    private func row(for p: PermissionItem) -> NSView {
        let title = NSTextField(labelWithString: p.title); title.font = .systemFont(ofSize: 14, weight: .semibold)
        let titleRow = NSStackView(views: [title]); titleRow.spacing = 6
        if p.required {
            let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: L("Required"))!)
            warn.contentTintColor = .systemOrange; warn.symbolConfiguration = .init(pointSize: 12, weight: .semibold); warn.toolTip = L("Required")
            titleRow.addArrangedSubview(warn)
        }
        let why = NSTextField(wrappingLabelWithString: p.why)
        why.font = .systemFont(ofSize: 12); why.textColor = .secondaryLabelColor; why.preferredMaxLayoutWidth = 320
        let text = NSStackView(views: [titleRow, why]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
        text.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let trailing: NSView
        if p.granted() {
            let v = NSTextField(labelWithString: p.doneTitle); v.font = .systemFont(ofSize: 13); v.textColor = .secondaryLabelColor
            if let remove = p.remove {
                let b = NSButton(title: p.removeTitle ?? L("Remove"), target: nil, action: nil); b.bezelStyle = .rounded
                b.actionHandler = { [weak self] in remove(self?.window) { self?.render() } }
                let pair = NSStackView(views: [v, b]); pair.spacing = 8
                trailing = pair
            } else {
                trailing = v
            }
        } else {
            let b = NSButton(title: p.buttonTitle, target: nil, action: nil); b.bezelStyle = .rounded
            b.actionHandler = { [weak self] in p.action(self?.window) { self?.render() } }
            trailing = b
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, spacer, trailing]); row.alignment = .centerY; row.spacing = 12
        return row
    }

    // MARK: helpers

    /// Re-reads every grant and rebuilds the page only if one has moved. Notification authorization is
    /// asynchronous, so the read goes through `refreshNotifications` and the comparison happens in its
    /// callback, once the cached value is current.
    private func refreshGrants() {
        PermissionCatalog.refreshNotifications { [weak self] in
            guard let self, self.step == 1 || self.step == 2 else { return }
            if self.currentGrants() != self.drawnGrants { self.render() }
        }
    }

    /// Which of the grants and the hooks are there right now.
    private func currentGrants() -> Set<SettingsGrant> {
        Set((PermissionCatalog.items + HookCatalog.items).filter { $0.granted() }.map(\.id))
    }

    /// Idempotent.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGrants() }
        }
    }

    /// Idempotent.
    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    /// A rounded capsule with an SF Symbol and a short label, in the brand colour.
    private static func pill(symbol: String, text: String) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        image.contentTintColor = brand
        image.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5, weight: .medium); label.textColor = brand
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, label]); row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        row.wantsLayer = true
        row.layer?.backgroundColor = brand.withAlphaComponent(0.10).cgColor
        row.layer?.cornerRadius = 13
        return row
    }

    /// The headline with `word` (localized separately) in the brand colour when it occurs.
    private static func accented(_ text: String, word: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let s = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor.labelColor, .paragraphStyle: p])
        if let r = text.range(of: word, options: .caseInsensitive) { s.addAttribute(.foregroundColor, value: brand, range: NSRange(r, in: text)) }
        return s
    }

    private func advance() {
        if step < 3 { step += 1; render() }
        else { Preferences.shared.onboardingCompleted = true; close() }
    }
}
