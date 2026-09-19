import AppKit

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
