#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$OUT"
# 1024px master: espresso gradient rounded square, white MugShape (the Armed glyph; the rim, the handle and
# the eyes are even-odd holes showing the gradient). The shape file is pasted in front so the glyph and the icon never drift.
{ cat "$ROOT/App/Sources/MugShape.swift"; cat <<'SWIFT'
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let px: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 0, y: 0, width: px, height: px)
let box = r.insetBy(dx: px * 0.08, dy: px * 0.08)
let path = NSBezierPath(roundedRect: box, xRadius: px * 0.185, yRadius: px * 0.185)
let gradient = NSGradient(starting: NSColor(srgbRed: 0.42, green: 0.25, blue: 0.15, alpha: 1), ending: NSColor(srgbRed: 0.27, green: 0.15, blue: 0.09, alpha: 1))!
gradient.draw(in: path, angle: -90)
let mw = px * 0.66
let m = NSRect(x: (px - mw) / 2, y: (px - mw * MugShape.aspect) / 2, width: mw, height: mw * MugShape.aspect)
MugShape.draw(in: m, state: .armed, ink: .white)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: url)
SWIFT
} | swift - "$OUT/master.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/master.png" --out "$OUT/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$OUT/master.png" --out "$OUT/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$OUT/master.png"
cat > "$OUT/Contents.json" <<'JSON'
{ "images" : [
  {"idiom":"mac","scale":"1x","size":"16x16","filename":"icon_16x16.png"},{"idiom":"mac","scale":"2x","size":"16x16","filename":"icon_16x16@2x.png"},
  {"idiom":"mac","scale":"1x","size":"32x32","filename":"icon_32x32.png"},{"idiom":"mac","scale":"2x","size":"32x32","filename":"icon_32x32@2x.png"},
  {"idiom":"mac","scale":"1x","size":"128x128","filename":"icon_128x128.png"},{"idiom":"mac","scale":"2x","size":"128x128","filename":"icon_128x128@2x.png"},
  {"idiom":"mac","scale":"1x","size":"256x256","filename":"icon_256x256.png"},{"idiom":"mac","scale":"2x","size":"256x256","filename":"icon_256x256@2x.png"},
  {"idiom":"mac","scale":"1x","size":"512x512","filename":"icon_512x512.png"},{"idiom":"mac","scale":"2x","size":"512x512","filename":"icon_512x512@2x.png"}
 ], "info" : { "author" : "xcode", "version" : 1 } }
JSON
cat > "$ROOT/App/Resources/Assets.xcassets/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
echo "icon regenerated in $OUT"
