import Foundation
import KoffeeLidCore

final class LidObserver {
    private let power: PowerManager
    private var filter: LidStateTransitionFilter
    var onTransition: ((LidTransition) -> Void)?
    var onLog: ((String) -> Void)?
    var isClosed: Bool? { filter.isClosed }

    init(power: PowerManager) {
        self.power = power
        filter = LidStateTransitionFilter(baselineClosed: power.readLidClosed())
    }

    func handleNotification() {
        guard let closed = power.readLidClosed() else {
            onLog?("lid state-change notification: AppleClamshellState unavailable; preserving current state"); return
        }
        if let t = filter.feed(isClosed: closed) {
            onLog?("lid state notification: \(t == .closed ? "open -> closed" : "closed -> open")")
            onTransition?(t)
        } else {
            onLog?("lid state notification: \(closed ? "closed" : "open") unchanged from baseline; ignored")
        }
    }
}
