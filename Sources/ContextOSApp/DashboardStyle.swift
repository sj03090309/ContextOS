import SwiftUI
import AppKit

enum DashboardSurface: Hashable { case popover, window }

/// One live dashboard may have two presentations. Keep the live cadence until
/// the last presentation closes, without multiplying collectors or timers.
struct DashboardVisibility {
    private var surfaces: Set<DashboardSurface> = []
    var isVisible: Bool { !surfaces.isEmpty }
    mutating func open(_ surface: DashboardSurface) -> Bool {
        let wasVisible = isVisible
        surfaces.insert(surface)
        return !wasVisible && isVisible
    }
    mutating func close(_ surface: DashboardSurface) -> Bool {
        let wasVisible = isVisible
        surfaces.remove(surface)
        return wasVisible && !isVisible
    }
}

/// One short response to an action, with no decorative animation loop.
enum PanelMotion {
    static func response(reduced: Bool) -> Animation? {
        reduced ? nil : .spring(duration: 0.28, bounce: 0.08)
    }
    static func feedback(reduced: Bool) -> Animation? {
        reduced ? nil : .easeOut(duration: 0.14)
    }
}

struct PanelPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(configuration.isPressed && !reduced ? 0.985 : 1)
            .animation(PanelMotion.feedback(reduced: reduced), value: configuration.isPressed)
    }
}

/// Does not depend on SwiftUI's fitting-size feedback or on content length.
enum DashboardLayout {
    static let width: CGFloat = 340
    static func height(visibleHeight: CGFloat) -> CGFloat {
        min(520, max(180, visibleHeight - 56))
    }
}

struct PanelEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Brand.accent.opacity(0.75))
                .frame(width: 28, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5)
    }
}

struct PanelSectionHeading: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 2)
    }
}
