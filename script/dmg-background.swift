#!/usr/bin/env swift
// Draws the backdrop the disk-image window shows behind its two icons: the app's name, one line on what it
// does, and an arrow from where the app sits to where the Applications folder sits. The icons themselves are
// real files, placed by the image's own layout: this only paints what is behind them.
//
//   swift dmg-background.swift <name> <accent hex> <out.png> [out@2x.png] [description]
//
// The accent colours the arrow only; the field and the words keep the palette of the app icon. The
// description defaults to the app's one-line purpose when the caller passes none.
//
// The geometry below is the one the layout uses; both must agree or the arrow misses the icons.

import AppKit
import Foundation

// The canvas, in points. Finder paints it at natural size from the top-left of the icon view and cuts off
// whatever its own bars (title, tabs, status, path) cover at the bottom, up to about 120 points of it. Every
// mark therefore sits in the top `contentHeight` points; below that the canvas is plain field, so a cut is
// invisible.
let canvasSize = CGSize(width: 660, height: 480)
let contentHeight: CGFloat = 340

// The icon centres are what `script/dmg-settings.py` positions the two files at. A 128-point icon centred at
// y 250 covers 186 to 314, and the label Finder writes under it reaches about 336.
let appIconCentre = CGPoint(x: 165, y: 250)
let dropIconCentre = CGPoint(x: 495, y: 250)
let iconSide: CGFloat = 128

// The palette belongs with the app icon: a dark chocolate brown on cream, the field a shade lighter at the
// top than at the bottom. A linear gradient is the only depth the field gets: anything with a soft edge bands.
let creamTop = NSColor(srgbRed: 0.973, green: 0.949, blue: 0.910, alpha: 1)
let creamBottom = NSColor(srgbRed: 0.945, green: 0.910, blue: 0.855, alpha: 1)
let brown = NSColor(srgbRed: 0.420, green: 0.247, blue: 0.141, alpha: 1)

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("dmg-background: " + message + "\n").utf8))
    exit(1)
}

/// "#RRGGBB" or "RRGGBB".
func colour(_ hex: String) -> NSColor {
    let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard text.count == 6, let value = UInt32(text, radix: 16) else { die("accent must be six hex digits, got \(hex)") }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                   green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255,
                   alpha: 1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    die("usage: dmg-background.swift <name> <accent hex> <out.png> [out@2x.png] [description]")
}
let appName = arguments[1]
let accent = colour(arguments[2])
let description = arguments.count >= 6 ? arguments[5] : "Keeps your MacBook running with the lid closed"

// MARK: - The arrow

/// A cubic Bézier, the arrow's spine, in the canvas's top-down coordinates.
struct Spine {
    let p0, p1, p2, p3: CGPoint

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// The unit tangent, pointing the way the spine is travelled.
    func direction(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let dx = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
        let dy = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
        let length = max(hypot(dx, dy), 0.0001)
        return CGPoint(x: dx / length, y: dy / length)
    }
}

func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }

/// A closed polygon wound counter-clockwise, so that every piece of the arrow winds the same way and the
/// non-zero rule fills their union with no hole where they overlap.
func polygon(_ points: [CGPoint]) -> CGPath {
    var area: CGFloat = 0
    for i in points.indices {
        let a = points[i], b = points[(i + 1) % points.count]
        area += a.x * b.y - b.x * a.y
    }
    let wound = area < 0 ? points.reversed() : points
    let path = CGMutablePath()
    path.addLines(between: wound)
    path.closeSubpath()
    return path
}

/// The arrow as one filled shape: a shaft that starts as a rounded point and thickens along the spine, and a
/// barbed head the shaft runs into. Widths are in points.
func arrowPath(along spine: Spine) -> CGPath {
    let tailHalfWidth: CGFloat = 1.2
    let shaftHalfWidth: CGFloat = 3.8
    let headLength: CGFloat = 25
    let headHalfWidth: CGFloat = 10.5
    // How far behind the tip the head's back notch sits, and how far past that notch the shaft continues, so
    // that the shaft's corners end inside the head.
    let notchDepth: CGFloat = 0.7 * headLength
    let shaftOverlap: CGFloat = 3

    let steps = 120
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = spine.point(at: t), d = spine.direction(at: t)
        let n = CGPoint(x: -d.y, y: d.x)
        // The stroke gains weight slowly at first, then fills out towards the head, like a brush pressed
        // harder as it travels.
        let w = tailHalfWidth + (shaftHalfWidth - tailHalfWidth) * pow(t, 1.4)
        left.append(p + n * w)
        right.append(p - n * w)
    }
    // The tail's round cap, walked from the right side round the back to the left side.
    let tail = spine.point(at: 0), tailDirection = spine.direction(at: 0)
    let tailNormal = CGPoint(x: -tailDirection.y, y: tailDirection.x)
    var cap: [CGPoint] = []
    for k in 1..<16 {
        let phi = CGFloat.pi * CGFloat(k) / 16
        cap.append(tail - tailNormal * (tailHalfWidth * cos(phi)) - tailDirection * (tailHalfWidth * sin(phi)))
    }
    let shaft = polygon(left + right.reversed() + cap)

    let end = spine.point(at: 1), d = spine.direction(at: 1)
    let n = CGPoint(x: -d.y, y: d.x)
    let notch = end - d * shaftOverlap
    let tip = notch + d * notchDepth
    let back = tip - d * headLength
    let head = polygon([tip, back + n * headHalfWidth, notch, back - n * headHalfWidth])

    let arrow = CGMutablePath()
    arrow.addPath(shaft)
    arrow.addPath(head)
    return arrow
}

// The spine leaves the app icon's right edge a little below the icons' centre line, lifts early over the gap
// and settles into the folder's left edge at that line, so the head reads as landing. Its tip ends up about
// 16 points short of the folder.
let arrowSpine = Spine(p0: CGPoint(x: appIconCentre.x + iconSide / 2 + 18, y: 262),
                       p1: CGPoint(x: appIconCentre.x + iconSide / 2 + 64, y: 226),
                       p2: CGPoint(x: dropIconCentre.x - iconSide / 2 - 62, y: 242),
                       p3: CGPoint(x: dropIconCentre.x - iconSide / 2 - 30, y: 252))
let arrow = arrowPath(along: arrowSpine)

// The rule the canvas is built on, checked before anything is drawn: the arrow, and the icons with the
// labels under them, end above `contentHeight`. The words sit above the icons and need no check of their own.
let labelBottom = max(appIconCentre.y, dropIconCentre.y) + iconSide / 2 + 22
guard labelBottom <= contentHeight, arrow.boundingBox.maxY <= contentHeight else {
    die("the layout reaches below \(Int(contentHeight)) points, where Finder may cut the backdrop")
}

// MARK: - The rendering

/// One drawing, rendered at whatever scale the caller asks for. The context is flipped so that every number
/// above reads top-down, the way the layout file states them.
func render(scale: CGFloat) -> Data {
    let pixels = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { die("could not allocate the bitmap") }
    // The rep's size in points against its size in pixels is what makes the context scale the drawing.
    bitmap.size = canvasSize

    NSGraphicsContext.saveGraphicsState()
    guard let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { die("could not open a context") }
    let cg = bitmapContext.cgContext
    cg.translateBy(x: 0, y: canvasSize.height)
    cg.scaleBy(x: 1, y: -1)
    let context = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current = context
    let canvas = NSRect(origin: .zero, size: canvasSize)

    // The field, over the whole canvas: the overflow below `contentHeight` is the same quiet gradient, with
    // nothing on it, so wherever Finder cuts it nothing is lost.
    NSGradient(colors: [creamTop, creamBottom])?.draw(in: canvas, angle: 90)

    // The name, centred over the icons, in the rounded face that matches the icon's soft shapes.
    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    let titleDescriptor = NSFont.systemFont(ofSize: 46, weight: .bold).fontDescriptor.withDesign(.rounded)
    let titleFont = titleDescriptor.flatMap { NSFont(descriptor: $0, size: 46) } ?? NSFont.systemFont(ofSize: 46, weight: .bold)
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: brown,
        .paragraphStyle: centred,
        .kern: -1.2,
    ]
    let title = appName as NSString
    let titleHeight = title.size(withAttributes: titleAttributes).height
    title.draw(in: NSRect(x: 0, y: 82 - titleHeight / 2, width: canvasSize.width, height: titleHeight),
               withAttributes: titleAttributes)

    // What the app does, in one line under the name, in a brown that steps back from the title.
    let descriptionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: brown.blended(withFraction: 0.3, of: creamBottom) ?? brown,
        .paragraphStyle: centred,
    ]
    let subtitle = description as NSString
    let subtitleHeight = subtitle.size(withAttributes: descriptionAttributes).height
    subtitle.draw(in: NSRect(x: 0, y: 127 - subtitleHeight / 2, width: canvasSize.width, height: subtitleHeight),
                  withAttributes: descriptionAttributes)

    // The arrow, in the accent: lighter where it starts, full where it lands.
    cg.saveGState()
    cg.addPath(arrow)
    cg.clip()
    let bounds = arrow.boundingBox
    NSGradient(colors: [accent.blended(withFraction: 0.32, of: creamTop) ?? accent, accent])?
        .draw(in: bounds, angle: 0)
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { die("could not encode the PNG") }
    return data
}

do {
    try render(scale: 1).write(to: URL(fileURLWithPath: arguments[3]))
    if arguments.count >= 5 { try render(scale: 2).write(to: URL(fileURLWithPath: arguments[4])) }
} catch {
    die("could not write: \(error.localizedDescription)")
}
