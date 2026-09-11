import AppKit

/// Builds the settings layout: bold section headers, translucent rounded groups with
/// one control per row, secondary notes beneath, on a dark vibrancy window.
final class SettingsForm {
    static let width: CGFloat = 412          // content width; window is width + 2 × margin
    static let margin: CGFloat = 24
    let stack = NSStackView()
    private var currentRows: [NSView] = []

    init() {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }

    // MARK: structure

    func header(_ title: String) {
        let l = NSTextField(labelWithString: title); l.font = .systemFont(ofSize: 13, weight: .semibold)
        add(l, topSpacing: stack.arrangedSubviews.isEmpty ? 0 : 16)
    }

    func note(_ text: String) {
        let l = NSTextField(wrappingLabelWithString: text); l.font = .systemFont(ofSize: 11.5); l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = Self.width
        add(l, topSpacing: 6)
    }

    /// A blue text link, used for "Open diagnostics log" and "Advanced settings…".
    func link(_ title: String, _ action: @escaping () -> Void) {
        let b = NSButton(title: title, target: nil, action: nil); b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 12.5)])
        b.actionHandler = action
        add(b, topSpacing: 12)
    }

    /// Rows appended with the `row…` helpers are collected until `endGroup()` wraps them in a box.
    func group(_ build: (SettingsForm) -> Void) {
        currentRows = []
        build(self)
        let inner = NSStackView(views: currentRows); inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = 0
        inner.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        for r in currentRows { r.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true }
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 10; box.borderWidth = 0
        box.fillColor = NSColor.labelColor.withAlphaComponent(0.07);   // adapts to light / dark box.contentViewMargins = .zero; box.titlePosition = .noTitle
        box.contentView = inner
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor), inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.topAnchor.constraint(equalTo: box.topAnchor), inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        add(box, topSpacing: 6)
        currentRows = []
    }

    // MARK: rows (inside a group)

    /// Label on the left, trailing views on the right. Returns the row so a caller can hide it.
    @discardableResult
    func row(_ label: String, _ trailing: NSView..., detail: String? = nil) -> NSView {
        let l = NSTextField(labelWithString: label); l.font = .systemFont(ofSize: 13)
        let leading = NSStackView(views: [l]); leading.spacing = 6
        if let detail {
            let d = NSTextField(labelWithString: detail); d.font = .systemFont(ofSize: 13); d.textColor = .secondaryLabelColor
            leading.addArrangedSubview(d)
        }
        let h = NSStackView(views: [leading, NSView()] + trailing); h.orientation = .horizontal; h.alignment = .centerY; h.spacing = 8
        h.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        h.heightAnchor.constraint(greaterThanOrEqualToConstant: 33).isActive = true
        currentRows.append(h)
        return h
    }

    /// A full-width slider with its value on the right (the battery and volume sliders).
    func sliderRow(min: Double, max: Double, value: Double, ticks: Int = 0, fmt: @escaping (Double) -> String, _ action: @escaping (Double) -> Void) {
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        s.isContinuous = true; s.numberOfTickMarks = ticks; s.allowsTickMarkValuesOnly = false; s.controlSize = .small
        let v = NSTextField(labelWithString: fmt(value)); v.font = .systemFont(ofSize: 13); v.alignment = .right
        v.widthAnchor.constraint(equalToConstant: 48).isActive = true
        s.actionHandler = { [weak s, weak v] in guard let s else { return }; action(s.doubleValue); v?.stringValue = fmt(s.doubleValue) }
        let h = NSStackView(views: [s, v]); h.orientation = .horizontal; h.alignment = .centerY; h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        currentRows.append(h)
    }

    /// A labelled slider's knob and value label, so another control can move it (a slider that
    /// pushes its neighbour to keep an ordering).
    struct SliderHandle {
        let set: (Double) -> Void
    }

    /// Label + value line above a full-width slider (for tunables that need a name).
    @discardableResult
    func labelledSlider(_ label: String, min: Double, max: Double, value: Double, fmt: @escaping (Double) -> String, _ action: @escaping (Double) -> Void) -> SliderHandle {
        let l = NSTextField(labelWithString: label); l.font = .systemFont(ofSize: 13)
        let v = NSTextField(labelWithString: fmt(value)); v.font = .systemFont(ofSize: 13); v.textColor = .secondaryLabelColor
        let top = NSStackView(views: [l, NSView(), v]); top.orientation = .horizontal; top.alignment = .centerY
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil); s.isContinuous = true; s.controlSize = .small
        s.actionHandler = { [weak s, weak v] in guard let s else { return }; action(s.doubleValue); v?.stringValue = fmt(s.doubleValue) }
        let col = NSStackView(views: [top, s]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 2
        col.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        // arranged views live inside the insets: size them to the column minus the insets
        top.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -24).isActive = true
        s.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -24).isActive = true
        currentRows.append(col)
        return SliderHandle(set: { [weak s, weak v] value in s?.doubleValue = value; v?.stringValue = fmt(value) })
    }

    // MARK: controls

    static func `switch`(_ isOn: Bool, _ action: @escaping (Bool) -> Void) -> NSSwitch {
        let s = NSSwitch(); s.state = isOn ? .on : .off; s.controlSize = .small
        s.actionHandler = { [weak s] in guard let s else { return }; action(s.state == .on) }; return s
    }
    static func popup(_ titles: [String], selected: Int, _ action: @escaping (Int) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton(); p.addItems(withTitles: titles); p.selectItem(at: selected); p.controlSize = .small; p.font = .systemFont(ofSize: 12)
        p.actionHandler = { [weak p] in guard let p else { return }; action(p.indexOfSelectedItem) }; return p
    }
    static func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil); b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 12)
        b.actionHandler = action; return b
    }
    static func value(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabelColor; return l
    }

    private func add(_ v: NSView, topSpacing: CGFloat) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(topSpacing, after: last) }
        stack.addArrangedSubview(v)
    }
}

/// Closure target for any NSControl.
private final class ActionTrampoline: NSObject {
    let handler: () -> Void
    init(_ h: @escaping () -> Void) { handler = h }
    @objc func fire(_ sender: Any?) { handler() }
}
private var trampolineKey: UInt8 = 0
extension NSControl {
    var actionHandler: (() -> Void)? {
        get { (objc_getAssociatedObject(self, &trampolineKey) as? ActionTrampoline)?.handler }
        set {
            guard let h = newValue else { objc_setAssociatedObject(self, &trampolineKey, nil, .OBJC_ASSOCIATION_RETAIN); return }
            let t = ActionTrampoline(h)
            objc_setAssociatedObject(self, &trampolineKey, t, .OBJC_ASSOCIATION_RETAIN)
            target = t; action = #selector(ActionTrampoline.fire(_:))
        }
    }
}
