// The kit every settings page is built from. Portable: SwiftUI only, nothing app-specific.
// A NEW project copies this file as it is, deletes this header, and builds its pages from it.
// (In KoffeeLid itself the live copy is App/Sources/UI/SettingsKit.swift: edit that one, and keep the
// numbers here and in SKILL.md equal to it in the same commit.)

import SwiftUI

/// Every spacing number of the window, once. Spacing is small on purpose: the window is a list of
/// switches and wastes no space.
enum SettingsMetrics {
    /// The width of the content. The window is not resizable and every page is laid out for this.
    static let contentWidth: CGFloat = 640
    /// Between the page's edge and its cards, left and right.
    static let pageMargin: CGFloat = 16
    static let pageTop: CGFloat = 10
    static let pageBottom: CGFloat = 14
    /// Between one group's last line and the next group's title.
    static let groupSpacing: CGFloat = 12
    /// How far a row's text sits from the card's edge. The group's title, hint and callouts take the
    /// same inset, so the four read as one column.
    static let inset: CGFloat = 10
    /// Between the title and the card, and between the card and whatever comes first under it.
    static let cardGap: CGFloat = 5
    /// Between the hint and the first callout under it.
    static let hintToCallout: CGFloat = 4
    /// Between one callout and the next.
    static let calloutSpacing: CGFloat = 3
    static let cardRadius: CGFloat = 10
    /// Above and below a row's content.
    static let rowPadding: CGFloat = 5
    /// No row is shorter, so a row holding a switch and one holding a button line up.
    static let rowMinHeight: CGFloat = 30
    /// Between the things on one row.
    static let rowSpacing: CGFloat = 8
    /// The widest a status mark grows before its sentence wraps.
    static let markMaxWidth: CGFloat = 400
    /// The app icon that heads the General page, and the air above it.
    static let appIconSide: CGFloat = 144
    static let appIconTop: CGFloat = 2
    /// The height of anything tall that lives inside a card: a text editor, a list.
    static let embeddedHeight: CGFloat = 240
}

/// One page: a column of groups inside the page's margins.
struct SettingsPage<Groups: View>: View {
    private let groups: Groups

    init(@ViewBuilder groups: () -> Groups) { self.groups = groups() }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            groups
        }
        .padding(.horizontal, SettingsMetrics.pageMargin)
        .padding(.top, SettingsMetrics.pageTop)
        .padding(.bottom, SettingsMetrics.pageBottom)
    }
}

/// The app's own icon, alone and centred: the first thing on the General page and on no other.
struct SettingsAppIcon: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: SettingsMetrics.appIconSide, height: SettingsMetrics.appIconSide)
            .frame(maxWidth: .infinity)
            .padding(.top, SettingsMetrics.appIconTop)
    }
}

/// One group, always the same parts in the same order: a title, a card of rows, and below and OUTSIDE
/// the card a hint, then warnings, then notes. Nothing explanatory goes inside a card.
///
/// hint: what the group does, grey. warning: something the user must fix, orange, present only while
/// it is wrong. note: the one thing the user must not miss, blue. A group with nothing to say has none.
struct SettingsGroup<Rows: View>: View {
    private let title: String
    private let hint: String?
    private let warnings: [String]
    private let notes: [String]
    private let rows: Rows

    init(title: String, hint: String? = nil, warnings: [String] = [], notes: [String] = [],
         @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.hint = hint
        self.warnings = warnings
        self.notes = notes
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.leading, SettingsMetrics.inset)
                .padding(.bottom, SettingsMetrics.cardGap)
            card
            if let hint {
                Text(hint)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SettingsMetrics.cardGap)
                    .padding(.horizontal, SettingsMetrics.inset)
            }
            if !warnings.isEmpty || !notes.isEmpty {
                VStack(alignment: .leading, spacing: SettingsMetrics.calloutSpacing) {
                    ForEach(warnings, id: \.self) { SettingsCallout($0, kind: .warning) }
                    ForEach(notes, id: \.self) { SettingsCallout($0, kind: .note) }
                }
                .padding(.top, hint == nil ? SettingsMetrics.cardGap : SettingsMetrics.hintToCallout)
                .padding(.horizontal, SettingsMetrics.inset)
            }
        }
    }

    /// The dividers are drawn here, never by the caller: a line between each pair of rows, starting
    /// where the text starts.
    private var card: some View {
        Group(subviews: rows) { collection in
            VStack(spacing: 0) {
                ForEach(collection.indices, id: \.self) { index in
                    if index > collection.startIndex {
                        Divider().padding(.leading, SettingsMetrics.inset)
                    }
                    collection[index]
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// One warning or one note under a card: a symbol and a sentence in the same colour.
private struct SettingsCallout: View {
    enum Kind {
        case warning, note

        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .note: "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .warning: .orange
            case .note: .blue
            }
        }
    }

    private let text: String
    private let kind: Kind

    init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        // The sentence is a column of its own, so a wrapped line continues under its first word and
        // not under the symbol.
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: kind.symbol)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .foregroundStyle(kind.color)
    }
}

/// The frame every row in a card shares. Use it directly for a row that is not label-plus-control.
struct SettingsRowFrame<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.vertical, SettingsMetrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowMinHeight, alignment: .leading)
    }
}

/// A label on the left and a control at the trailing edge. A disabled row dims its label too: a greyed
/// switch beside full-strength text reads as a control that is merely off.
struct SettingsRow<Control: View>: View {
    private let title: String
    private let enabled: Bool
    private let control: Control

    init(_ title: String, enabled: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.enabled = enabled
        self.control = control()
    }

    var body: some View {
        SettingsRowFrame {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // A wide control takes what the label leaves, never the other way round.
                    .layoutPriority(1)
                Spacer(minLength: SettingsMetrics.rowSpacing)
                control
            }
        }
        .disabled(!enabled)
    }
}

/// A switch and its label.
struct ToggleRow: View {
    private let title: String
    private let isOn: Binding<Bool>
    private let enabled: Bool

    init(_ title: String, isOn: Binding<Bool>, enabled: Bool = true) {
        self.title = title
        self.isOn = isOn
        self.enabled = enabled
    }

    var body: some View {
        SettingsRow(title, enabled: enabled) {
            // The label is the row's own text, so the toggle's is hidden. It is written anyway so that
            // VoiceOver reads the switch by the name the user sees.
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

/// A choice between two to four short words, as a segmented control at the trailing edge. One of the
/// two replacements for a radio group; the other is `TileRow`.
struct SegmentedRow<Option: Hashable>: View {
    private let title: String
    private let options: [Option]
    private let selection: Binding<Option>
    private let enabled: Bool
    private let label: (Option) -> String

    init(_ title: String, options: [Option], selection: Binding<Option>, enabled: Bool = true,
         label: @escaping (Option) -> String) {
        self.title = title
        self.options = options
        self.selection = selection
        self.enabled = enabled
        self.label = label
    }

    var body: some View {
        SettingsRow(title, enabled: enabled) {
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// A choice the user can SEE, as equal-width picture tiles: a drawing over its title, the selected
/// tile tinted and ringed in the accent colour. The group's hint then describes the SELECTED option
/// only, because the pictures already show them all.
struct TileRow<Option: Hashable, Picture: View>: View {
    private let options: [Option]
    private let selection: Binding<Option>
    private let enabled: Bool
    private let label: (Option) -> String
    private let picture: (Option) -> Picture

    init(options: [Option], selection: Binding<Option>, enabled: Bool = true,
         label: @escaping (Option) -> String, @ViewBuilder picture: @escaping (Option) -> Picture) {
        self.options = options
        self.selection = selection
        self.enabled = enabled
        self.label = label
        self.picture = picture
    }

    var body: some View {
        SettingsRowFrame {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button { selection.wrappedValue = option } label: { tile(option) }
                        // Plain, so the tile is the whole control, with a content shape so that a
                        // click anywhere inside it counts.
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func tile(_ option: Option) -> some View {
        let selected = option == selection.wrappedValue
        return VStack(spacing: 6) {
            picture(option)
            Text(label(option))
                .font(.body)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

/// What stands on the right of a status row. Five kinds, each owning its symbol and its colour, so a
/// state looks the same on every page. Never build a status any other way.
struct StatusMark {
    enum Kind {
        /// As it should be: green checkmark.
        case good
        /// Worth knowing, nothing to fix: blue info mark.
        case info
        /// Something to fix, or something that did not work: orange triangle.
        case warning
        /// Refused or wrong: red cross.
        case failure
        /// Still happening: a spinner where the symbol goes.
        case busy
    }

    let kind: Kind
    let text: String

    static func good(_ text: String) -> StatusMark { StatusMark(kind: .good, text: text) }
    static func info(_ text: String) -> StatusMark { StatusMark(kind: .info, text: text) }
    static func warning(_ text: String) -> StatusMark { StatusMark(kind: .warning, text: text) }
    static func failure(_ text: String) -> StatusMark { StatusMark(kind: .failure, text: text) }
    static func busy(_ text: String) -> StatusMark { StatusMark(kind: .busy, text: text) }

    fileprivate var symbol: String? {
        switch kind {
        case .good: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        case .busy: nil
        }
    }

    fileprivate var color: Color {
        switch kind {
        case .good: .green
        case .info: .blue
        case .warning: .orange
        case .failure: .red
        case .busy: .secondary
        }
    }
}

/// A state, always one row: what is reported on the left in ordinary text, its mark at the trailing
/// edge at the same size as everything else. A mark that is a sentence wraps, trailing aligned, its
/// symbol beside the first line. `mark: nil` reports nothing yet.
struct StatusRow: View {
    private let text: String
    private let mark: StatusMark?

    init(_ text: String, mark: StatusMark?) {
        self.text = text
        self.mark = mark
    }

    var body: some View {
        SettingsRow(text) {
            if let mark {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let symbol = mark.symbol {
                        Image(systemName: symbol)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(mark.text)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.body)
                .foregroundStyle(mark.color)
                .frame(maxWidth: SettingsMetrics.markMaxWidth, alignment: .trailing)
            }
        }
    }
}

/// A row that is only buttons, at the trailing edge. One button is the rule; two only when both are
/// always valid at once.
struct ButtonRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        SettingsRowFrame {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                Spacer(minLength: 0)
                content
            }
        }
    }
}
