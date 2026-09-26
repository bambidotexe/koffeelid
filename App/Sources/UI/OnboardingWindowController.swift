import AppKit
import ServiceManagement
import KoffeeLidCore

/// Four pages: the pitch, one permissions page (every macOS grant the app needs, required ones
/// flagged), one hooks page (auto-arm on activity: Claude Code, Codex, Copilot, OpenCode and terminal), and
/// "All set".
///
/// An ordinary window: the normal level and the default collection behaviour, the same as `SettingsWindow`
/// and `UpdateWindow`. It comes up in front because it is the last window to open, and from then on it takes
/// its turn like any other: a permission dialog, the administrator dialog and System Settings all open over
/// it and stay there until the user leaves them, and the wizard keeps its place underneath. It belongs to the
/// Space it opened in and keeps its place in it across a Space switch. The app is activated once, when the
/// window opens, and never again from here.
///
/// Nothing tells an app that a grant was made in System Settings, so the two list pages poll every
/// `pollInterval` the way the Settings window does. Only a change of step builds a page: a grant that moves
/// redraws the one row it belongs to, and a row whose flow is still running shows its loading state.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var step = 0
    /// The espresso brown of the mug; used to accent one word of the headline.
    private static let brand = NSColor(srgbRed: 0.42, green: 0.25, blue: 0.15, alpha: 1)
    private var observers: [NSObjectProtocol] = []
    /// Whether another window of the app still needs it active once the wizard goes away. Injected, as
    /// `SettingsWindow`'s is: an accessory app with no window left is still the active application, which
    /// would send the user's keystrokes nowhere.
    var othersNeedUsActive: @MainActor () -> Bool = { false }

    /// The rows of the page on screen, by grant. A grant that moves updates its own row and nothing else:
    /// rebuilding the page to show it blanked the window and drew it again.
    private var rows: [SettingsGrant: GrantRow] = [:]
    /// The page's primary button, whose title follows whether the page's own condition is met. Weak: the
    /// page that owns it is thrown away on a change of step.
    private weak var primaryButton: NSButton?
    private var poll: Timer?
    /// Brings the wizard back when the pane a grant button sent the user to quits.
    private let focusReturn = FocusReturnWatch()
    /// Slow enough to be free, fast enough that coming back from System Settings finds the page already right.
    private static let pollInterval: TimeInterval = 2

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "KoffeeLid"; w.center(); w.isReleasedWhenClosed = false
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
        focusReturn.stop()
        if !othersNeedUsActive() { NSApp.deactivate() }
    }

    // MARK: pages

    /// Builds the page for `step`. Called on a change of step and nowhere else — a grant, a hook or a
    /// running flow changes one row, never the page.
    private func render() {
        guard let window, let content = window.contentView else { return }
        rows.removeAll()
        primaryButton = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        let page: NSView
        let height: CGFloat
        switch step {
        case 0: page = introPage(); height = 440
        case 1: page = permissionsPage(); height = 560
        case 2: page = hooksPage(); height = 560
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
                    body: L("Close the MacBook and walk away: Claude Code, Codex, Copilot, OpenCode, builds, servers and downloads keep running on a dark, silent display. Open the lid and your Mac locks."),
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
        listPage(header: L("Permissions"),
                 intro: L("KoffeeLid needs a few things from macOS. Items marked with a warning are required for a closed Mac to stay awake safely."),
                 items: PermissionCatalog.items)
    }

    private func hooksPage() -> NSView {
        listPage(header: L("Arm while you work"),
                 intro: L("Optional. Let KoffeeLid arm itself while Claude Code, Codex, Copilot, OpenCode or a terminal command is running, and disarm a minute after nothing is. Setting up any of them turns auto-arm on; all five can be changed later in Settings."),
                 items: HookCatalog.items)
    }

    private func listPage(header: String, intro: String, items: [PermissionItem]) -> NSView {
        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = .systemFont(ofSize: 22, weight: .bold)
        let introLabel = NSTextField(wrappingLabelWithString: intro)
        introLabel.font = .systemFont(ofSize: 13); introLabel.textColor = .secondaryLabelColor; introLabel.preferredMaxLayoutWidth = 460

        let list = NSStackView(); list.orientation = .vertical; list.spacing = 12; list.alignment = .leading
        for (i, item) in items.enumerated() {
            if i > 0 { let sep = NSBox(); sep.boxType = .separator; list.addArrangedSubview(sep); sep.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
            let row = GrantRow(item: item,
                               window: { [weak self] in self?.window },
                               focusReturn: focusReturn,
                               didFinish: { [weak self] in self?.updatePrimaryButton() })
            rows[item.id] = row
            list.addArrangedSubview(row.view)
        }
        list.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }

        let primary = NSButton(title: "", target: nil, action: nil)
        primary.bezelStyle = .rounded; primary.keyEquivalent = "\r"; primary.actionHandler = { [weak self] in self?.advance() }
        primaryButton = primary
        // The footer is a plain view with the button pinned to its trailing edge and to **both** its top
        // and bottom, which fixes the footer's height to the button's. An `NSStackView` holding an invisible
        // spacer is the trap: a spacer has no intrinsic height, so nothing decides the footer's height and
        // the vertical stack hands it every point of slack the page is not using. Granting a permission swaps
        // a row's 26 pt button for an 18 pt label, the list shrinks, the footer grows to absorb it, and the
        // button sits wherever the slack put it: still drawn, `AXFrame` still plausible, no constraint broken,
        // and a press on it does not land.
        let footer = NSView()
        primary.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(primary)
        NSLayoutConstraint.activate([
            primary.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            primary.topAnchor.constraint(equalTo: footer.topAnchor),
            primary.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])

        // The slack goes here, deliberately, and into nothing else: above the footer, so the stepping button
        // stays at the bottom right of the page however tall the rows happen to be.
        let slack = NSView()
        slack.setContentHuggingPriority(.init(1), for: .vertical)
        slack.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let stack = NSStackView(views: [headerLabel, introLabel, list, slack, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.setCustomSpacing(20, after: introLabel)
        stack.setCustomSpacing(24, after: list)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 40, bottom: 28, right: 40)
        // Width constraints only once every view shares the stack as ancestor.
        list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -80).isActive = true
        footer.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        updatePrimaryButton()
        return stack
    }

    /// "Continue" once the page's own condition is met, "Skip" until then: every required grant on the
    /// Permissions page, any hook on the hooks page. Set in place, so the page is not rebuilt for a word.
    private func updatePrimaryButton() {
        guard let primaryButton else { return }
        let title: String
        switch step {
        case 1: title = PermissionCatalog.items.filter(\.required).allSatisfy { $0.granted() } ? L("Continue") : L("Skip")
        case 2: title = HookCatalog.items.contains { $0.granted() } ? L("Continue") : L("Skip")
        default: return
        }
        if primaryButton.title != title { primaryButton.title = title }
    }


    // MARK: helpers

    /// Re-reads every grant and lets each row redraw itself if its own state moved. Notification
    /// authorization is asynchronous, so the read goes through `refreshNotifications` and the rows are
    /// refreshed in its callback, once the cached value is current. A page with no rows (the pitch, "All
    /// set") has nothing to do here.
    private func refreshGrants() {
        PermissionCatalog.refreshNotifications { [weak self] in
            guard let self else { return }
            for row in self.rows.values { row.refresh() }
            self.updatePrimaryButton()
        }
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

/// One row of a list page: what the grant is, why it is wanted, and a trailing control that follows its
/// state. Built once and updated in place — rebuilding the page to show a grant that moved blanked the
/// window and drew it again.
///
/// While a grant flow is running the row keeps the button that started it, disabled, with a spinner beside
/// it, and the poll leaves that loading state alone until the flow reports back. Flows that report more than
/// once settle the row on the first only.
@MainActor
private final class GrantRow {
    let view: NSStackView

    /// What the trailing control is showing. Compared before redrawing, so a refresh that changes nothing
    /// touches no view.
    private enum Shown: Equatable { case nothing, granted, notGranted, busy(String) }

    private let item: PermissionItem
    private let window: () -> NSWindow?
    private let focusReturn: FocusReturnWatch
    /// Called once a flow has reported back: the page's primary button may have to change with it.
    private let didFinish: () -> Void
    private let trailing = NSView()
    private var shown: Shown = .nothing
    private var busy = false

    init(item: PermissionItem, window: @escaping () -> NSWindow?, focusReturn: FocusReturnWatch,
         didFinish: @escaping () -> Void) {
        self.item = item
        self.window = window
        self.focusReturn = focusReturn
        self.didFinish = didFinish

        let title = NSTextField(labelWithString: item.title); title.font = .systemFont(ofSize: 14, weight: .semibold)
        let titleRow = NSStackView(views: [title]); titleRow.spacing = 6
        if item.required {
            let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: L("Required"))!)
            warn.contentTintColor = .systemOrange; warn.symbolConfiguration = .init(pointSize: 12, weight: .semibold); warn.toolTip = L("Required")
            titleRow.addArrangedSubview(warn)
        }
        let why = NSTextField(wrappingLabelWithString: item.why)
        why.font = .systemFont(ofSize: 12); why.textColor = .secondaryLabelColor; why.preferredMaxLayoutWidth = 320
        let text = NSStackView(views: [titleRow, why]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
        text.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view = NSStackView(views: [text, spacer, trailing]); view.alignment = .centerY; view.spacing = 12
        refresh()
    }

    /// Re-reads the grant and redraws the trailing control only if it should look different. A row whose
    /// flow is still running keeps its loading state: the poll must not take it away.
    func refresh() {
        guard !busy else { return }
        show(item.granted() ? .granted : .notGranted)
    }

    private func show(_ next: Shown) {
        guard next != shown else { return }
        shown = next
        trailing.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch next {
        case .nothing:
            content = NSView()
        case .busy(let title):
            let button = Self.button(title); button.isEnabled = false
            let spinner = NSProgressIndicator()
            spinner.style = .spinning; spinner.controlSize = .small; spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            let pair = NSStackView(views: [spinner, button]); pair.spacing = 8
            content = pair
        case .granted:
            let done = NSTextField(labelWithString: item.doneTitle)
            done.font = .systemFont(ofSize: 13); done.textColor = .secondaryLabelColor
            if let remove = item.remove {
                let title = item.removeTitle ?? L("Remove")
                let button = Self.button(title)
                button.actionHandler = { [weak self] in
                    guard let self else { return }
                    self.start(title) { settle in remove(self.window(), settle) }
                }
                let pair = NSStackView(views: [done, button]); pair.spacing = 8
                content = pair
            } else {
                content = done
            }
        case .notGranted:
            let button = Self.button(item.buttonTitle)
            button.actionHandler = { [weak self] in
                guard let self else { return }
                self.start(self.item.buttonTitle) { settle in self.item.action(self.window(), settle) }
            }
            content = button
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        trailing.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: trailing.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            content.topAnchor.constraint(equalTo: trailing.topAnchor),
            content.bottomAnchor.constraint(equalTo: trailing.bottomAnchor),
        ])
    }

    /// Runs one grant flow with the row in its loading state, and reads the grant again when it reports back.
    private func start(_ title: String, _ flow: (_ settle: @escaping () -> Void) -> Void) {
        busy = true
        show(.busy(title))
        var settled = false
        flow { [weak self] in
            guard !settled else { return }
            settled = true
            guard let self else { return }
            self.busy = false
            self.refresh()
            self.didFinish()
            self.item.reclaimFocusIfNeeded(self.window())
            if let opened = self.item.mayOpen { self.focusReturn.whenQuit(opened, bringBack: self.window()) }
        }
    }

    private static func button(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        return button
    }
}
