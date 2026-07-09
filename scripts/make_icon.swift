import AppKit
import Foundation

// Generates AppIcon.icns for ContextOS: a blue→purple rounded tile with a white
// sparkles glyph, matching the menu-bar look. Run: swift scripts/make_icon.swift

let blue = NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.98, alpha: 1)
let purple = NSColor(calibratedRed: 0.62, green: 0.50, blue: 0.96, alpha: 1)

func whiteSparkles(pointSize: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let base = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let tinted = NSImage(size: base.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: base.size)
    base.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

func renderIcon(px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded tile with a small margin (macOS app-tile look).
    let margin = size * 0.085
    let tile = NSRect(x: margin, y: margin, width: size - 2*margin, height: size - 2*margin)
    let radius = tile.width * 0.225
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(starting: blue, ending: purple)!.draw(in: path, angle: -55)

    // White sparkles centered, ~46% of the icon.
    let glyph = whiteSparkles(pointSize: size * 0.46)
    let g = glyph.size
    let gx = (size - g.width) / 2
    let gy = (size - g.height) / 2
    glyph.draw(in: NSRect(x: gx, y: gy, width: g.width, height: g.height))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in variants {
    try! renderIcon(px: px).write(to: iconset.appendingPathComponent("\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "✓ AppIcon.icns 생성 완료" : "✗ iconutil 실패")
