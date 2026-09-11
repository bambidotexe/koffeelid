public enum LidTransition: Equatable { case closed, opened }

/// Collapses repeated `AppleClamshellState` notifications into real transitions.
public struct LidStateTransitionFilter {
    public private(set) var isClosed: Bool?
    public init(baselineClosed: Bool?) { isClosed = baselineClosed }

    public mutating func feed(isClosed newValue: Bool) -> LidTransition? {
        defer { isClosed = newValue }
        guard let old = isClosed, old != newValue else { return nil }
        return newValue ? .closed : .opened
    }
}
