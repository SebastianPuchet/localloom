#!/bin/bash
# Regenerates Resources/AppIcon.icns from a Core Graphics drawing. Run only when the mark
# changes; the .icns is committed so a plain build never needs this.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/icon.swift" <<'SWIFT'
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// Rounded-square plate with a vertical indigo gradient.
let inset = size * 0.08
let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = CGPath(roundedRect: plate, cornerWidth: size * 0.22, cornerHeight: size * 0.22,
                  transform: nil)
context.saveGState()
context.addPath(path)
context.clip()
let colors = [
    CGColor(red: 0.24, green: 0.24, blue: 0.38, alpha: 1),
    CGColor(red: 0.09, green: 0.09, blue: 0.16, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                          locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: 0), options: [])
context.restoreGState()

// Screen rectangle.
let screen = CGRect(x: size * 0.24, y: size * 0.34, width: size * 0.52, height: size * 0.36)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
context.setLineWidth(size * 0.045)
context.addPath(CGPath(roundedRect: screen, cornerWidth: size * 0.05,
                       cornerHeight: size * 0.05, transform: nil))
context.strokePath()

// The webcam bubble, bottom-left, exactly where the app draws it.
let diameter = size * 0.26
let bubble = CGRect(x: size * 0.19, y: size * 0.20, width: diameter, height: diameter)
context.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.16, alpha: 1))
context.fillEllipse(in: bubble.insetBy(dx: -size * 0.02, dy: -size * 0.02))
context.setFillColor(CGColor(red: 0.98, green: 0.29, blue: 0.35, alpha: 1))
context.fillEllipse(in: bubble)

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swift "$WORK/icon.swift" "$WORK/icon.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" \
            "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$WORK/icon.png" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns"
