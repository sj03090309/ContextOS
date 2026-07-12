import AppKit
import Foundation

// Generates the ContextOS app icon: the 뭉치 blob mascot (cream, dark eyes) on
// an ink (charcoal) rounded tile — a restrained, editor-like identity.
// Outputs AppIcon.icns (repo root) + assets/icon.png (README header).
// Run: swift scripts/make_icon.swift

let inkTop = NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.141, alpha: 1)   // #1E1E24
let inkBottom = NSColor(calibratedRed: 0.078, green: 0.078, blue: 0.094, alpha: 1) // #141418
let cream = NSColor(calibratedRed: 0.937, green: 0.906, blue: 0.839, alpha: 1)    // #EFE7D6
let eyeInk = NSColor(calibratedRed: 0.090, green: 0.090, blue: 0.106, alpha: 1)   // #17171B

/// The 뭉치 silhouette, designed in a 48×48 y-down space (same path as the app).
func blobPath(in rect: NSRect) -> NSBezierPath {
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        // Flip y: design space is y-down, AppKit is y-up.
        NSPoint(x: rect.minX + x / 48 * rect.width,
                y: rect.minY + (48 - y) / 48 * rect.height)
    }
    let p = NSBezierPath()
    p.move(to: pt(24, 6))
    p.curve(to: pt(40, 26), controlPoint1: pt(34, 6), controlPoint2: pt(40, 14))
    p.curve(to: pt(24, 42), controlPoint1: pt(40, 38), controlPoint2: pt(33, 42))
    p.curve(to: pt(8, 26), controlPoint1: pt(15, 42), controlPoint2: pt(8, 38))
    p.curve(to: pt(24, 6), controlPoint1: pt(8, 14), controlPoint2: pt(14, 6))
    p.close()
    return p
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
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(starting: inkTop, ending: inkBottom)!.draw(in: tilePath, angle: -90)

    // 뭉치 centered, ~62% of the tile.
    let blobSize = tile.width * 0.62
    let blobRect = NSRect(x: (size - blobSize) / 2, y: (size - blobSize) / 2,
                          width: blobSize, height: blobSize)
    cream.setFill()
    blobPath(in: blobRect).fill()

    // Eyes (design coords: centers (18,24) & (30,24), r 3.1 in 48-space).
    eyeInk.setFill()
    let er = blobSize * 3.1 / 48
    for ex in [CGFloat(18), CGFloat(30)] {
        let cx = blobRect.minX + ex / 48 * blobSize
        let cy = blobRect.minY + (48 - 24) / 48 * blobSize
        NSBezierPath(ovalIn: NSRect(x: cx - er, y: cy - er, width: er * 2, height: er * 2)).fill()
    }

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

// README header image.
try! renderIcon(px: 256).write(to: URL(fileURLWithPath: "assets/icon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "✓ AppIcon.icns + assets/icon.png 생성 완료" : "✗ iconutil 실패")
