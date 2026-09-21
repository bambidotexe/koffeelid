// The onboarding wizard: an ordinary window that steps through pages with one button.
//
// Portable: AppKit only, nothing app-specific except the places marked EDIT. A NEW project copies this
// file with GrantRow.swift and ControlActionHandler.swift, deletes this header, edits those places, and
// declares its pages in `pages`. Strings here are plain literals; route every one through the project's
// own localization helper (KoffeeLid: L("English key") with an fr entry in the string catalog).
// (In KoffeeLid the live copy is App/Sources/UI/OnboardingWindowController.swift.)

import AppKit

// MARK: - The pages

/// A capsule on the first page: an SF Symbol and two or three words, in the brand colour.
struct Pill {
    let symbol: String
    let text: String
}

/// One page of the wizard. Order is the order the user walks them, and the order in `pages` below.
///
/// `hero` opens and closes the wizard; `list` is a page of grants or setup actions. Everything between is
/// optional: a project adds as many `list` and `hero` pages as its setup needs, or none.
enum OnboardingPage {
    /// The first page, and any full-width page that is a picture and a sentence rather than a list: the app
    /// icon, a headline with one word accented, a short description, optional capsules, one button.
    case hero(title: String, accent: String?, body: String, pills: [Pill], button: String)
    /// A page of rows. `advanceWhen` decides whether its button reads "Continue" or "Skip": on the
    /// permissions page that is every required grant being there; on an optional page, any one row done.
    case list(header: String, intro: String, items: [GrantItem], advanceWhen: ([GrantItem]) -> Bool)
    /// The last page. Its button finishes and closes the window.
    case final(title: String, body: String, button: String)

    /// The window's height while this page is shown. The window resizes around its top-left corner.
    var height: CGFloat {
        switch self {
        case .hero: Metrics.heroHeight
        case .list: Metrics.listHeight
        case .final: Metrics.finalHeight
        }
    }
}

/// Every required grant is there. The permissions page's rule.
func everyRequiredGrant(_ items: [GrantItem]) -> Bool {
    items.filter(\.required).allSatisfy { $0.granted() }
}

/// Any one row is done. An optional page's rule.
func anyOneDone(_ items: [GrantItem]) -> Bool {
    items.contains { $0.granted() }
}

// MARK: - The window

/// The wizard.
///
/// **An ordinary window.** The normal level, the default collection behaviour, the same as every other
/// window of the app. It comes up in front because it is the last window to open, and from then on it takes
/// its turn like any other: a permission prompt, an administrator dialog and System Settings all open over
/// it and stay there until the user leaves them. It belongs to the Space it opened in and keeps its place
/// there across a Space switch. The app is activated once, when the window opens.
///
/// **Two things bring it back**, both of them a grant flow ending, and nothing else:
/// `GrantItem.returnsFocus` for a flow that owned a modal dialog, and `GrantItem.mayOpen` for a flow that
/// sent the user to another app, through `FocusReturnWatch`. Read the two doc comments on those before
/// touching either: getting this wrong is what made the window either cover System Settings or sink behind
/// the user's terminal.
///
/// **No prompt is ever shown unless the user clicked for it.** Nothing in this window, and nothing in the
/// app's start-up path, calls a request API; only a row's button does.
///
/// **Nothing tells an app that a grant was made in System Settings**, so a list page re-reads its grants
/// every `Metrics.pollInterval` while the window is up. A page is built only on a change of step: a grant
/// that moves redraws the one row it belongs to.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    /// EDIT: the pages, in order. The first is the pitch, the last is `final`, and what is between them is
    /// the app's own setup. Build it in the initialiser so the grant catalogue is read fresh.
    private let pages: [OnboardingPage]
    /// EDIT: called when the last page's button is pressed. Record that onboarding is done here.
    private let onFinish: () -> Void
    /// Whether another window of the app still needs it active once the wizard goes away. Injected, never
    /// inferred from `NSApp.windows`: an accessory app with no window left is still the active application,
    /// which would send the user's keystrokes nowhere.
    var othersNeedUsActive: @MainActor () -> Bool = { false }

    /// EDIT: one colour, used to accent a word of the headline and to tint the capsules. Take it from the
    /// app's icon.
    private static let brand = NSColor(srgbRed: 0.42, green: 0.25, blue: 0.15, alpha: 1)

    private var step = 0
    private var observers: [NSObjectProtocol] = []
    /// The rows of the page on screen, by grant. A grant that moves updates its own row and nothing else.
    private var rows: [GrantID: GrantRow] = [:]
    /// The page's primary button, whose title follows whether the page's rule is met. Weak: the page that
    /// owns it is thrown away on a change of step.
    private weak var primaryButton: NSButton?
    private var poll: Timer?
    /// Brings the wizard back when the app a grant button sent the user to quits.
    private let focusReturn = FocusReturnWatch()

    init(title: String, pages: [OnboardingPage], onFinish: @escaping () -> Void) {
        self.pages = pages
        self.onFinish = onFinish
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: Metrics.heroHeight),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.center()
        w.isReleasedWhenClosed = false
        // Nothing else. No `level`, and no `collectionBehavior`: both are what made this window misbehave.
        w.contentView = NSView()
        super.init(window: w)
        w.delegate = self
        // Coming back from System Settings: re-read the grants. The poll covers a window that is already
        // key and so never sees this edge.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                self?.refreshGrants()
            })
        // The app coming forward brings the wizard with it, the way any app's window does.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.comeForward()
            })
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
    /// never lands on top of the Settings window. Ordering front, never `NSApp.activate(ignoringOtherApps:)`.
    private func comeForward() {
        guard let window, window.isVisible, !othersNeedUsActive() else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        focusReturn.stop()
        if !othersNeedUsActive() { NSApp.deactivate() }
    }

    // MARK: Building a page

    /// Builds the page for `step`. Called on a change of step and nowhere else: a grant that moves, a flow
    /// that starts or ends, and a poll tick all change one row, never the page.
    private func render() {
        guard let window, let content = window.contentView, pages.indices.contains(step) else { return }
        rows.removeAll()
        primaryButton = nil
        content.subviews.forEach { $0.removeFromSuperview() }

        let page = pages[step]
        let view: NSView
        switch page {
        case let .hero(title, accent, body, pills, button):
            view = hero(title: title, accent: accent, body: body, pills: pills, button: button)
        case let .list(header, intro, items, advanceWhen):
            view = listPage(header: header, intro: intro, items: items, advanceWhen: advanceWhen)
        case let .final(title, body, button):
            view = hero(title: title, accent: nil, body: body, pills: [], button: button)
        }

        // Grow downward from a fixed title bar.
        var frame = window.frame
        let dy = page.height - content.frame.height
        frame.origin.y -= dy
        frame.size.height += dy
        window.setFrame(frame, display: true, animate: window.isVisible)

        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func hero(title: String, accent: String?, body: String, pills: [Pill], button: String) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.heightAnchor.constraint(equalToConstant: Metrics.heroIcon).isActive = true

        let headline = NSTextField(wrappingLabelWithString: "")
        // A selectable label enters the field editor on a click and loses its attributes.
        headline.isSelectable = false
        headline.allowsEditingTextAttributes = true
        headline.font = .systemFont(ofSize: Metrics.heroTitle, weight: .bold)
        headline.alignment = .center
        headline.attributedStringValue = Self.accented(title, word: accent)
        headline.preferredMaxLayoutWidth = Metrics.heroTextWidth
        headline.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.heroTextWidth).isActive = true

        let description = NSTextField(wrappingLabelWithString: body)
        description.isSelectable = false
        description.font = .systemFont(ofSize: Metrics.heroBody)
        description.alignment = .center
        description.preferredMaxLayoutWidth = Metrics.heroTextWidth
        description.textColor = .secondaryLabelColor

        var extras: [NSView] = []
        if !pills.isEmpty {
            let row = NSStackView()
            row.spacing = 8
            pills.forEach { row.addArrangedSubview(Self.pill($0)) }
            row.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.pillRowWidth).isActive = true
            extras = [row]
        }

        let next = NSButton(title: button, target: nil, action: nil)
        next.bezelStyle = .rounded
        next.keyEquivalent = "\r"
        next.actionHandler = { [weak self] in self?.advance() }

        let stack = NSStackView(views: [icon, headline, description] + extras + [next])
        stack.orientation = .vertical
        stack.spacing = Metrics.heroSpacing
        stack.setCustomSpacing(Metrics.heroTitleToBody, after: headline)
        stack.edgeInsets = Metrics.heroInsets
        return stack
    }

    private func listPage(header: String, intro: String, items: [GrantItem],
                          advanceWhen: @escaping ([GrantItem]) -> Bool) -> NSView {
        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = .systemFont(ofSize: Metrics.listTitle, weight: .bold)
        let introLabel = NSTextField(wrappingLabelWithString: intro)
        introLabel.font = .systemFont(ofSize: Metrics.listIntro)
        introLabel.textColor = .secondaryLabelColor
        introLabel.preferredMaxLayoutWidth = Metrics.listIntroWidth

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = Metrics.listRowSpacing
        list.alignment = .leading
        for (i, item) in items.enumerated() {
            if i > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                list.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            let row = GrantRow(item: item,
                               window: { [weak self] in self?.window },
                               focusReturn: focusReturn,
                               didFinish: { [weak self] in self?.updatePrimaryButton() })
            rows[item.id] = row
            list.addArrangedSubview(row.view)
        }
        list.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }

        let primary = NSButton(title: "", target: nil, action: nil)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.actionHandler = { [weak self] in self?.advance() }
        primaryButton = primary
        // The footer is a plain view with the button pinned to its trailing edge and to **both** its top
        // and bottom, which is what fixes the footer's height to the button's.
        //
        // An `NSStackView` holding an invisible spacer is the trap, and it shipped in three apps: a spacer
        // has no intrinsic height, so nothing decides the footer's own height, and the vertical stack hands
        // it every point of slack the page is not using. Granting a permission swaps that row's 26 pt button
        // for an 18 pt "Granted" label; the list shrinks by 36 pt, the footer grows to absorb it, and the
        // button sits wherever the slack put it rather than at the bottom of the page. It is still drawn,
        // `AXFrame` still names a plausible rectangle, no constraint breaks, and a press on it does not land.
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
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.listSpacing
        stack.setCustomSpacing(Metrics.listIntroToList, after: introLabel)
        stack.setCustomSpacing(Metrics.listToFooter, after: list)
        stack.edgeInsets = Metrics.listInsets
        // Width constraints only once every view shares the stack as an ancestor.
        list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Metrics.listSideInset).isActive = true
        footer.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        updatePrimaryButton()
        return stack
    }

    /// "Continue" once the page's rule is met, "Skip" until then. Set in place, so the page is never
    /// rebuilt for a word.
    private func updatePrimaryButton() {
        guard let primaryButton, pages.indices.contains(step),
              case let .list(_, _, items, advanceWhen) = pages[step] else { return }
        let title = advanceWhen(items) ? "Continue" : "Skip"
        if primaryButton.title != title { primaryButton.title = title }
    }

    // MARK: Following the system

    /// Re-reads every grant and lets each row redraw itself if its own state moved. A page with no rows has
    /// nothing to do here.
    ///
    /// EDIT: a grant read asynchronously (notification authorization) must be refreshed into its cache
    /// before the rows are asked, so do that here and refresh the rows in its callback.
    private func refreshGrants() {
        for row in rows.values { row.refresh() }
        updatePrimaryButton()
    }

    /// Idempotent.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: Metrics.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGrants() }
        }
    }

    /// Idempotent.
    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    private func advance() {
        if step < pages.count - 1 {
            step += 1
            render()
        } else {
            onFinish()
            close()
        }
    }

    // MARK: Drawing

    /// A rounded capsule with an SF Symbol and a short label, in the brand colour.
    private static func pill(_ pill: Pill) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: pill.symbol, accessibilityDescription: nil)!)
        image.contentTintColor = brand
        image.symbolConfiguration = .init(pointSize: Metrics.pillSymbol, weight: .semibold)
        let label = NSTextField(labelWithString: pill.text)
        label.font = .systemFont(ofSize: Metrics.pillLabel, weight: .medium)
        label.textColor = brand
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, label])
        row.spacing = Metrics.pillSpacing
        row.edgeInsets = Metrics.pillInsets
        row.wantsLayer = true
        row.layer?.backgroundColor = brand.withAlphaComponent(Metrics.pillTint).cgColor
        row.layer?.cornerRadius = Metrics.pillRadius
        return row
    }

    /// The headline, with `word` in the brand colour where it occurs. `word` is localized separately, so a
    /// translation accents its own word and not a fragment of another.
    private static func accented(_ text: String, word: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: Metrics.heroTitle, weight: .bold),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])
        if let word, let range = text.range(of: word, options: .caseInsensitive) {
            string.addAttribute(.foregroundColor, value: brand, range: NSRange(range, in: text))
        }
        return string
    }
}
