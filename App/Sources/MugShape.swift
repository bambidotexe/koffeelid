import AppKit

// The KoffeeLid mug, from the user's SVG artwork in App/Resources/Glyphs (viewBox 325 × 244, one even-odd
// `cup` path per state whose extra sub-paths are the eyes, plus a `liquid` ellipse in every state but off).
// Shared by StatusItemController (menu bar glyph) and script/make_icon.sh (app icon), which pastes this
// file in front of its own rendering code. Keep it AppKit-only with no other dependencies.
enum MugShape {
    /// The four glyphs: `mug-off.svg`, `mug-auto.svg`, `mug-armed.svg`, `mug-caffeinate.svg`.
    enum State: String, CaseIterable { case off, auto, armed, caffeinate }

    /// Content bounds of the cup path (the same in every file).
    static let box = NSRect(x: 2, y: 9.41, width: 320.75, height: 224.31)
    /// Height / width of the content bounds.
    static var aspect: CGFloat { box.height / box.width }

    static let cup = "M272.46,70.69C303.85,72.21 322.75,89.99 322.75,118.27C322.75,148.01 302.2,165.95 268.01,165.95L259.12,165.95C239.05,208.5 197.69,233.72 144.13,233.72L130.33,233.72C53.52,233.72 2,179.29 2,101.86L2,70.74C2,34.25 56.58,9.41 137.23,9.41C217.84,9.41 272.41,34.22 272.46,70.69ZM137.23,108.15C201.47,108.15 248.7,91.89 248.7,70.74C248.7,49.73 201.47,33.33 137.23,33.33C73.14,33.33 25.92,49.73 25.92,70.74C25.92,91.89 73.14,108.15 137.23,108.15ZM267.61,142.18L268.01,142.18C287.49,142.18 298.83,133.14 298.83,118.27C298.83,104.42 289.2,95.79 272.46,94.51L272.46,101.86C272.46,116.27 270.79,129.75 267.61,142.18Z"
    /// The eyes, appended to `cup` inside the same even-odd path (so they are cut-outs).
    static let autoEyes = "M57.57,166.1A53.56,53.56 0 0 0 119.98,166.1A5.5,5.5 0 0 0 113.57,157.16A42.56,42.56 0 0 1 63.98,157.16A5.5,5.5 0 0 0 57.57,166.1ZM150.37,160.98A33.88,33.88 0 1 0 217.23,156.31Z"
    static let armedEyes = "M59.44,180.57A33.88,33.88 0 1 1 118.12,180.57ZM154.81,180.57A33.88,33.88 0 1 1 213.49,180.57Z"
    static let caffeinateEyes = "M52.4,162.63A36.38,36.38 0 0 1 125.16,162.63A36.38,36.38 0 0 1 52.4,162.63ZM147.77,162.63A36.38,36.38 0 0 1 220.53,162.63A36.38,36.38 0 0 1 147.77,162.63Z"
    /// The coffee in the cup (path coordinates, y down): drawn over the opening's hole in every armed state.
    static let liquid = (cx: CGFloat(138.3), cy: CGFloat(70.89), rx: CGFloat(100.58), ry: CGFloat(30.05))

    static func pathData(for state: State) -> String {
        switch state {
        case .off: return cup
        case .auto: return cup + autoEyes
        case .armed: return cup + armedEyes
        case .caffeinate: return cup + caffeinateEyes
        }
    }

    /// Draws the state's glyph in `ink`, fitted into `r` (which should have `aspect`). Holes (the rim,
    /// the handle, the eyes) are even-odd cut-outs, so whatever is behind shows through.
    static func draw(in r: NSRect, state: State, ink: NSColor) {
        let scale = r.width / box.width
        var t = AffineTransform(translationByX: r.minX, byY: r.minY)
        t.scale(scale)
        t.translate(x: -box.minX, y: -box.minY)
        // SVG y grows downwards: flip inside the content box.
        t.translate(x: 0, y: box.minY * 2 + box.height); t.scale(x: 1, y: -1)
        let p = path(from: pathData(for: state)); p.windingRule = .evenOdd; p.transform(using: t)
        ink.set(); p.fill()
        if state != .off {
            let e = NSBezierPath(ovalIn: NSRect(x: liquid.cx - liquid.rx, y: liquid.cy - liquid.ry, width: liquid.rx * 2, height: liquid.ry * 2))
            e.transform(using: t); e.fill()
        }
    }

    /// Minimal SVG path-data parser: absolute M, L, H, V, C, A and Z (all this artwork uses).
    static func path(from d: String) -> NSBezierPath {
        let p = NSBezierPath()
        let scanner = Scanner(string: d); scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t")
        var cmd: Character = "M"
        var cur = NSPoint.zero
        func num() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
        while !scanner.isAtEnd {
            if let c = scanner.scanCharacter(), c.isLetter { cmd = c }
            else { scanner.currentIndex = d.index(before: scanner.currentIndex) }
            switch cmd {
            case "M": cur = NSPoint(x: num(), y: num()); p.move(to: cur); cmd = "L"
            case "L": cur = NSPoint(x: num(), y: num()); p.line(to: cur)
            case "H": cur.x = num(); p.line(to: cur)
            case "V": cur.y = num(); p.line(to: cur)
            case "C": let c1 = NSPoint(x: num(), y: num()), c2 = NSPoint(x: num(), y: num()); cur = NSPoint(x: num(), y: num()); p.curve(to: cur, controlPoint1: c1, controlPoint2: c2)
            case "A":
                let rx = num(), ry = num(), rotation = num(), large = num() != 0, sweep = num() != 0
                let end = NSPoint(x: num(), y: num())
                addArc(to: p, from: cur, to: end, rx: rx, ry: ry, rotationDegrees: rotation, largeArc: large, sweep: sweep)
                cur = end
            case "Z", "z": p.close(); cmd = "M"
            default: _ = num()   // unsupported command: skip a number to guarantee progress
            }
        }
        return p
    }

    /// SVG elliptical arc (endpoint parameterisation, spec appendix B.2.4) as ≤ 90° cubic Bézier pieces.
    static func addArc(to p: NSBezierPath, from p1: NSPoint, to p2: NSPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                       rotationDegrees: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if p1 == p2 { return }
        if rx == 0 || ry == 0 { p.line(to: p2); return }
        let phi = rotationDegrees * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy, y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry, cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy, len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let a = acos(max(-1, min(1, dot / len)))
            return ux * vy - uy * vx < 0 ? -a : a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, dtheta > 0 { dtheta -= 2 * .pi } else if sweep, dtheta < 0 { dtheta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
        let delta = dtheta / CGFloat(segments)
        let k = 4 / 3 * tan(delta / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: cx + cosPhi * rx * x - sinPhi * ry * y, y: cy + sinPhi * rx * x + cosPhi * ry * y)
        }
        var a1 = theta1
        for _ in 0..<segments {
            let a2 = a1 + delta
            let c1 = cos(a1), s1 = sin(a1), c2 = cos(a2), s2 = sin(a2)
            p.curve(to: map(c2, s2), controlPoint1: map(c1 - k * s1, s1 + k * c1), controlPoint2: map(c2 + k * s2, s2 - k * c2))
            a1 = a2
        }
    }
}
