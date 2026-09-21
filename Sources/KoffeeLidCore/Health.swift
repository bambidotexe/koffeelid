import Foundation

/// How one line of the Health page reads. The page answers one question at a glance, whether KoffeeLid is
/// doing its job, and these four levels are the whole of its answer. The same four colours mean the same
/// thing on every page of the Settings window, so a state never reads green in one place and orange in
/// another.
public enum HealthLevel: Int, Comparable {
    /// A reading: a time, a count, a value. Nothing to judge, nothing to fix. Blue. A switch of KoffeeLid's
    /// own that the user turned off is one too: it is the state they asked for.
    case info
    /// As it should be. Green.
    case good
    /// Not as it should be, and KoffeeLid still keeps a closed Mac awake: an optional permission or setup
    /// missing, a feature switched on that cannot work, a crash this week. Degraded, not broken. Orange.
    case warning
    /// Not as it should be, and because of it KoffeeLid cannot keep a closed Mac awake, or cannot do it
    /// safely: a required grant missing, the mechanism down, an arm refused. Red, with the stop sign.
    case failure

    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One line of the Health page, in words: what is reported on the left, one word at the trailing edge in
/// its level's colour, and while the line is orange or red the sentence that says how to put it right,
/// which the page shows as a warning under the group.
public struct HealthRow: Equatable, Identifiable {
    /// Stable and never translated: the line's identity, whatever its label says in either language.
    public let id: String
    public let label: String
    public let level: HealthLevel
    /// One word from the window's vocabulary, or a short value for a reading ("3 h 12 min", "48 MB").
    public let word: String
    /// What only a bug report needs (a path, a date, an identifier): the row's tooltip, and a line of the
    /// copied report. Never on the row itself.
    public let detail: String?
    /// What to do, and where, while the row is orange or red. Shown under the group; ignored while green or
    /// blue, so a row can carry its sentence whatever its level.
    public let fix: String?

    public init(id: String, label: String, level: HealthLevel, word: String, detail: String? = nil,
                fix: String? = nil) {
        self.id = id
        self.label = label
        self.level = level
        self.word = word
        self.detail = detail
        self.fix = fix
    }
}

/// One group of the Health page, in words: a subject the user thinks in, its lines, and under the card the
/// sentences that say how to put right whichever of them is wrong.
public struct HealthGroup: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let hint: String?
    public let rows: [HealthRow]

    public init(id: String, title: String, hint: String? = nil, rows: [HealthRow]) {
        self.id = id
        self.title = title
        self.hint = hint
        self.rows = rows
    }

    /// One sentence per line that is orange or red and says how to fix it, in the order of the lines, each
    /// once. None while every line is fine: a warning is shown only while something is wrong.
    public var warnings: [String] {
        var seen = Set<String>()
        return rows.filter { $0.level >= .warning }.compactMap(\.fix).filter { seen.insert($0).inserted }
    }
}

/// The page in one line: what the first row of the Health page says about everything under it.
public struct HealthSummary: Equatable {
    /// Lines that are red: each one stops KoffeeLid from doing what it is for.
    public let blocking: Int
    /// Lines that are orange: each one degrades it.
    public let toLookAt: Int

    public init(levels: [HealthLevel]) {
        blocking = levels.filter { $0 == .failure }.count
        toLookAt = levels.filter { $0 == .warning }.count
    }

    public init(groups: [HealthGroup]) {
        self.init(levels: groups.flatMap(\.rows).map(\.level))
    }

    public init(sections: [HealthSection]) {
        self.init(levels: sections.flatMap(\.items).map(\.level))
    }

    /// Red wins over orange: one line that stops the app is what the user must hear first.
    public var level: HealthLevel {
        if blocking > 0 { return .failure }
        return toLookAt > 0 ? .warning : .good
    }
}

/// The Health page's numbers.
public enum HealthConstants {
    /// How far back the Health page counts crash reports. A week covers the gap between two weekly update
    /// checks, and a crash older than that has either been fixed by a release or been seen again since.
    public static let crashWindow: TimeInterval = 7 * 24 * 60 * 60

    /// The shortest time the Health page's overview reads *Checking* after Check Again. Most checks answer in
    /// a few milliseconds, and a mark that changes back before it can be seen reads as a button that did
    /// nothing; half a second is seen and does not keep anyone waiting.
    public static let minimumBusy: TimeInterval = 0.5
}
