import SwiftUI

/// A fixed dark palette for the dashboard surface (styled like a product
/// dashboard, independent of the system appearance).
enum Theme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.07)
    static let panel = Color(red: 0.09, green: 0.10, blue: 0.115)
    static let card = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let cardHover = Color(red: 0.14, green: 0.15, blue: 0.17)
    static let stroke = Color.white.opacity(0.07)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.5)
    static let textTertiary = Color.white.opacity(0.32)

    static let blue = Color(red: 0.29, green: 0.56, blue: 0.98)
    static let green = Color(red: 0.30, green: 0.80, blue: 0.55)
    static let orange = Color(red: 0.95, green: 0.55, blue: 0.30)
    static let red = Color(red: 0.94, green: 0.38, blue: 0.38)
    static let purple = Color(red: 0.64, green: 0.52, blue: 0.96)

    static func scoreColor(_ score: Int) -> Color {
        switch score {
        case 80...: return green
        case 50..<80: return orange
        default: return red
        }
    }
}

/// A rounded dark card container matching the reference dashboard.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
    }
}
