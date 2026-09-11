import Foundation
import KoffeeLidCore

final class ThermalMonitor {
    var onChange: ((ThermalLevel) -> Void)?
    private var observer: NSObjectProtocol?
    var current: ThermalLevel { Self.map(ProcessInfo.processInfo.thermalState) }

    static func map(_ s: ProcessInfo.ThermalState) -> ThermalLevel {
        switch s { case .nominal: return .nominal; case .fair: return .fair; case .serious: return .serious; case .critical: return .critical; @unknown default: return .serious }
    }
    func start() {
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.onChange?(self.current)
        }
    }
    func stop() { if let o = observer { NotificationCenter.default.removeObserver(o) }; observer = nil }
}
