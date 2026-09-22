import Foundation

/// How a line of the Health table reads. The table answers one question at a glance, whether KoffeeLid
/// works, so it has three colours and no fourth: a reading is not a check, and goes in the Information table
/// (`InfoRow`), never here.
public enum HealthLevel: Int, Comparable {
    /// Working. Green.
    case good
    /// Not working as it should, and KoffeeLid still keeps a closed Mac awake: an optional permission or setup
    /// missing, a crash this week. Degraded, not broken. Orange.
    case warning
    /// Not working, and because of it KoffeeLid cannot keep a closed Mac awake, or cannot do it safely: a
    /// required grant missing, the mechanism down. Red, with the stop sign.
    case failure

    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One line of the Health table, in words: what is checked on the left, one word at the trailing edge in its
/// level's colour, and while the line is orange or red the sentence that says how to put it right, which the
/// page shows as a warning under the table.
public struct HealthRow: Equatable, Identifiable {
    /// Stable and never translated: the line's identity, whatever its label says in either language.
    public let id: String
    public let label: String
    public let level: HealthLevel
    /// One word from the window's vocabulary: Granted, Denied, Enabled, Disabled, Running, Missing, Failed.
    public let word: String
    /// What only a bug report needs (a path, a date, an identifier): the row's tooltip, never on the row.
    public let detail: String?
    /// What to do, and where, while the row is orange or red. Ignored while green, so a row can carry its
    /// sentence whatever its level.
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

/// One line of the Information table, in words: a reading worth having beside the checks (the last time a
/// hook reported, the lid's angle), blue, with nothing to judge and nothing to fix.
public struct InfoRow: Equatable, Identifiable {
    public let id: String
    public let label: String
    /// A short value: "3 min ago", "112°", "Armed".
    public let value: String
    /// The row's tooltip, never on the row.
    public let detail: String?

    public init(id: String, label: String, value: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.detail = detail
    }
}

/// How long the two tables may grow. The page is read at a glance or it is useless: a check the user would
/// not act on, a preference, a reading nobody asked for, each costs the ones that matter a look.
/// `HealthTests` builds the worst case KoffeeLid can report and holds it to these.
public enum HealthLimits {
    /// Lines of the Health table with everything that can go wrong gone wrong at once.
    public static let checks = 10
    /// Lines of the Information table with every reading there.
    public static let readings = 5
}

extension Array where Element == HealthRow {
    /// One sentence per line that is orange or red and says how to fix it, in the order of the lines, each
    /// once. None while every line is green: a warning is shown only while something is wrong.
    public var warnings: [String] {
        var seen = Set<String>()
        return filter { $0.level >= .warning }.compactMap(\.fix).filter { seen.insert($0).inserted }
    }
}

/// The Health page's numbers.
public enum HealthConstants {
    /// How far back the Health page counts crash reports. A week covers the gap between two weekly update
    /// checks, and a crash older than that has either been fixed by a release or been seen again since.
    public static let crashWindow: TimeInterval = 7 * 24 * 60 * 60

    /// The shortest time Check Again shows its spinner. Most checks answer in a few milliseconds, and a
    /// spinner that goes before it can be seen reads as a button that did nothing; half a second is seen and
    /// does not keep anyone waiting.
    public static let minimumBusy: TimeInterval = 0.5
}
