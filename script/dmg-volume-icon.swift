#!/usr/bin/env swift
// Writes the iconset the disk image's volume icon is built from, taking the icon as macOS itself renders the
// built bundle.
//
//   swift dmg-volume-icon.swift <path to the .app> <output .iconset directory>
//
// The bundle's own AppIcon.icns is not used: an app whose icon comes from an Icon Composer document is
// rendered from Assets.car, with the rounding and the glass the system applies, and its .icns carries at best
// a flat stand-in of that. Asking NSWorkspace gives the volume the same icon Finder shows for the app.

import AppKit
import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("dmg-volume-icon: " + message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { die("usage: dmg-volume-icon.swift <path to the .app> <output .iconset>") }
let appPath = arguments[1]
let iconset = URL(fileURLWithPath: arguments[2], isDirectory: true)

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: appPath, isDirectory: &isDirectory), isDirectory.boolValue else {
    die("no such bundle: \(appPath)")
}

let icon = NSWorkspace.shared.icon(forFile: appPath)
guard icon.size.width > 0 else { die("the system returned no icon for \(appPath)") }

try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The ten names `iconutil` expects, each with the pixel side it is drawn at.
let members: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for member in members {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: member.side, pixelsHigh: member.side,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { die("could not allocate \(member.side) px") }
    rep.size = NSSize(width: member.side, height: member.side)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { die("could not open a context") }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // Drawing the whole image into a square of the wanted side lets AppKit pick the representation closest to
    // it, rather than scaling one size down to all of them.
    icon.draw(in: NSRect(x: 0, y: 0, width: member.side, height: member.side),
              from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { die("could not encode \(member.name)") }
    do {
        try png.write(to: iconset.appendingPathComponent(member.name + ".png"))
    } catch {
        die("could not write \(member.name): \(error.localizedDescription)")
    }
}
