import SwiftUI

/// Rasterizes the small, softly lit menu-bar pose once per scale, tint and appearance.
enum MenuBarMascotArtwork {
    static let canvasSize = CGSize(width: 20, height: 24)

    @MainActor
    static func image(hex: String, dark: Bool, scale: CGFloat) -> CGImage? {
        guard scale.isFinite, (1...8).contains(scale),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = Int((canvasSize.width * scale).rounded())
        let height = Int((canvasSize.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / canvasSize.width, y: -CGFloat(height) / canvasSize.height)

        let tint = MascotRGB(hex: hex)
        let white = MascotRGB(hex: "FFFFFF")
        let black = MascotRGB(hex: "000000")
        let backdrop = MascotRGB(hex: dark ? "23262C" : "EEEFF1")
        let contour = MungchiSilhouette().path(in: CGRect(x: 1.75, y: 4.0, width: 16.5, height: 14.8)).cgPath
        let crown = tint.mixed(with: white, fraction: 0.28)
        let base = tint.mixed(with: black, fraction: 0.23)

        context.saveGState()
        context.addPath(contour)
        context.clip()
        if let body = CGGradient(colorsSpace: space,
                                 colors: [crown.cgColor(), tint.cgColor(), base.cgColor()] as CFArray,
                                 locations: nil) {
            context.drawLinearGradient(body, start: CGPoint(x: 8, y: 4), end: CGPoint(x: 12, y: 18.8),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if let sheen = CGGradient(colorsSpace: space,
                                  colors: [white.cgColor(alpha: 0.43), white.cgColor(alpha: 0)] as CFArray,
                                  locations: nil) {
            context.drawRadialGradient(sheen, startCenter: CGPoint(x: 6.5, y: 7), startRadius: 0,
                                       endCenter: CGPoint(x: 6.5, y: 7), endRadius: 6, options: [])
        }
        context.restoreGState()

        // A thin edge stays legible even when a custom tint is close to the menu bar.
        let backgroundLuminance = backdrop.luminance
        let tintLuminance = tint.luminance
        let contrast = (max(backgroundLuminance, tintLuminance) + 0.05)
            / (min(backgroundLuminance, tintLuminance) + 0.05)
        let edge = contrast < 2 ? (dark ? white : black) : base
        context.addPath(contour)
        context.setStrokeColor(edge.cgColor(alpha: contrast < 2 ? 0.52 : 0.62))
        context.setLineWidth(0.55)
        context.strokePath()

        let face = tint.mixed(with: white, fraction: 0.10)
        let eye = face.luminance > 0.179 ? MascotRGB(hex: "182620") : white
        context.setFillColor(eye.cgColor())
        for x in [7.25, 11.15] {
            context.fillEllipse(in: CGRect(x: x, y: 11.1, width: 1.48, height: 1.78))
        }

        return context.makeImage()
    }
}
