import AppKit
import KoffeeLidCore

final class DisplayTopologyMonitor {
    var onChange: ((DisplayTopology) -> Void)?
    private var observer: NSObjectProtocol?
    var current: DisplayTopology { Self.read() }

    static func read() -> DisplayTopology {
        var count: UInt32 = 0; var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success, count > 0 else {
            return DisplayTopology(builtInCount: 0, externalCount: 0, verified: false)
        }
        let online = ids.prefix(Int(count))
        let builtIn = online.filter { CGDisplayIsBuiltin($0) != 0 }.count
        return DisplayTopology(builtInCount: builtIn, externalCount: Int(count) - builtIn, verified: true)
    }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.onChange?(self.current)
        }
    }
    func stop() { if let o = observer { NotificationCenter.default.removeObserver(o) }; observer = nil }
}
