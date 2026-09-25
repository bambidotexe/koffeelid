import AppKit
import KoffeeLidCore

/// The icon each badge wears: the app's icon from the system, looked up once per app and kept. Nothing is
/// bundled: an app that is not installed gives no icon, and the cup wears nothing for its work.
@MainActor
enum ActivityIcons {
    private static var cache: [ActivityApp: NSImage?] = [:]

    /// The icons of `badges`, in their order, skipping every app that has none.
    static func icons(for badges: [ActivityBadge]) -> [NSImage] { badges.compactMap { icon(for: $0.app) } }

    static func icon(for app: ActivityApp) -> NSImage? {
        if let known = cache[app] { return known }
        let icon = lookUp(app)
        cache[app] = icon
        return icon
    }

    /// A badge is the icon's own rounded square filling its frame: an app icon draws that square on about
    /// 80 % of its canvas, with a shadow under it, and a 9 pt badge cannot spare the rest. The square is
    /// the box of the pixels at least half opaque on a 128 px rendering (the shadow is fainter), and the
    /// icon is then drawn so that box fills the image.
    private static func cropped(_ icon: NSImage) -> NSImage {
        let side = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return icon }
        // Rows count from the top; the box is wanted in unit coordinates from the bottom-left.
        let unit = CGFloat(side)
        let box = NSRect(x: CGFloat(minX) / unit, y: 1 - CGFloat(maxY + 1) / unit,
                         width: CGFloat(maxX - minX + 1) / unit, height: CGFloat(maxY - minY + 1) / unit)
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            let w = r.width / box.width, h = r.height / box.height
            icon.draw(in: NSRect(x: r.minX - box.minX * w, y: r.minY - box.minY * h, width: w, height: h),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private static func lookUp(_ app: ActivityApp) -> NSImage? {
        switch app {
        case .bundlePath(let path):
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return cropped(NSWorkspace.shared.icon(forFile: path))
        case .bundleIdentifier(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return cropped(NSWorkspace.shared.icon(forFile: url.path))
        }
    }
}
