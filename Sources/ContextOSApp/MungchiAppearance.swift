import SwiftUI

enum MascotColor: String, CaseIterable, Identifiable {
    case white, mint, sky, lavender, peach, cream

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: "흰색"
        case .mint: "민트"
        case .sky: "하늘"
        case .lavender: "라벤더"
        case .peach: "복숭아"
        case .cream: "크림"
        }
    }

    var hex: String {
        switch self {
        case .white: "FFFFFF"
        case .mint: "40C977"
        case .sky: "76B9EC"
        case .lavender: "AD9BEC"
        case .peach: "F3A785"
        case .cream: "E6D3A4"
        }
    }

    var swatch: Color { MascotRGB(hex: hex).color }
}

struct MungchiPalette {
    let body: Color
    let highlight: Color
    let eyes: Color
    let outline: Color
    let ground: Color

    init(hex: String, dark: Bool) {
        let tint = MascotRGB(hex: hex)
        let background = MascotRGB(hex: dark ? "1D1E23" : "F8F6F1")
        body = tint.color
        highlight = tint.mixed(with: background, fraction: 0.37).color
        let face = tint.mixed(with: background, fraction: 0.20)
        eyes = face.luminance > 0.179 ? Color(red: 0.08, green: 0.11, blue: 0.10) : .white
        let tintLuminance = tint.luminance
        let backgroundLuminance = background.luminance
        let darker = min(tintLuminance, backgroundLuminance)
        let lighter = max(tintLuminance, backgroundLuminance)
        let edge: Color = dark ? .white : .black
        outline = (lighter + 0.05) / (darker + 0.05) < 2 ? edge.opacity(0.5) : .clear
        ground = tint.mixed(with: MascotRGB(hex: dark ? "FFFFFF" : "000000"), fraction: 0.28)
            .color.opacity(0.24)
    }
}

struct MascotRGB {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x40C977
        red = Double((value >> 16) & 255) / 255
        green = Double((value >> 8) & 255) / 255
        blue = Double(value & 255) / 255
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func mixed(with other: Self, fraction: Double) -> Self {
        Self(red: red + (other.red - red) * fraction,
             green: green + (other.green - green) * fraction,
             blue: blue + (other.blue - blue) * fraction)
    }
}

/// The preview's elliptical corner radii, with a soft dome and a flatter base.
struct MungchiSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.48, 0))
        path.addCurve(to: point(1, 0.59), control1: point(0.767, 0), control2: point(1, 0.264))
        path.addLine(to: point(1, 0.61))
        path.addCurve(to: point(0.62, 1), control1: point(1, 0.825), control2: point(0.830, 1))
        path.addLine(to: point(0.40, 1))
        path.addCurve(to: point(0, 0.59), control1: point(0.179, 1), control2: point(0, 0.816))
        path.addLine(to: point(0, 0.57))
        path.addCurve(to: point(0.48, 0), control1: point(0, 0.255), control2: point(0.215, 0))
        path.closeSubpath()
        return path
    }
}

struct MungchiFace: View {
    let palette: MungchiPalette
    let gaze: CGFloat
    var eyesOpen: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let shape = MungchiSilhouette()
            shape.fill(RadialGradient(colors: [palette.highlight, palette.body],
                                      center: UnitPoint(x: 0.28, y: 0.21),
                                      startRadius: 0, endRadius: max(size.width, size.height) * 0.78))
            shape.stroke(palette.outline, lineWidth: 0.85)
            ForEach([0.38, 0.56], id: \.self) { x in
                Ellipse()
                    .fill(palette.eyes)
                    .frame(width: size.width * 0.076, height: size.height * 0.107 * eyesOpen)
                    .position(x: size.width * (x + 0.076 * gaze),
                              y: size.height * (0.494 - 0.054 * gaze))
            }
        }
    }
}
