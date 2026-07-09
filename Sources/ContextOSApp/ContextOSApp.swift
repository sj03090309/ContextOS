import SwiftUI
import AppKit
import ContextOSCore

@main
struct ContextOSApp: App {
    @StateObject private var model = DashboardModel()
    @StateObject private var mascot = MascotRenderer()

    init() {
        // Menu-bar agent: no Dock icon, no standalone window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView().environmentObject(model)
        } label: {
            MenuBarLabel(model: model, mascot: mascot)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The live menu-bar label: the ContextOS mascot + today's saved tokens.
///
/// Note: a raw custom `Shape`/`Canvas` view does not render inside a
/// `MenuBarExtra` label's status-item hosting — only `Image`-backed content
/// (SF Symbols, or a rendered bitmap) does. So the mascot is drawn to an
/// `NSImage` every frame (see `MascotRenderer`) and shown via `Image(nsImage:)`.
struct MenuBarLabel: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var mascot: MascotRenderer

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: mascot.image)
            if model.todaySaved > 0 {
                Text(TokenEstimator.korean(model.todaySaved))
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .onAppear {
            mascot.setActive(model.flashing)
            mascot.start()
        }
        .onChange(of: model.flashing) { _, newValue in
            mascot.setActive(newValue)
        }
    }
}

/// Renders "별똥이" — the ContextOS sparkle mascot — to a bitmap on every
/// animation tick. Idle → a slow gentle sway; active (MCP optimizing) → a
/// fast continuous spin.
@MainActor
final class MascotRenderer: ObservableObject {
    @Published private(set) var image = NSImage(size: .zero)

    private var timer: Timer?
    private var active = false
    private let startedAt = Date()

    func setActive(_ value: Bool) { active = value }

    func start() {
        guard timer == nil else { return }
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    private func render() {
        let t = Date().timeIntervalSince(startedAt)
        // Fast continuous spin while active; a small idle sway otherwise.
        let angle: Double = active
            ? (t * 360 * 2.2).truncatingRemainder(dividingBy: 360)
            : sin(t * 1.4) * 9

        // Solid black on transparent + isTemplate: macOS then auto-adapts the
        // icon to the menu bar's light/dark appearance, same as SF Symbols do.
        let glyph = SparkleShape()
            .fill(Color.black)
            .frame(width: 15, height: 15)
            .rotationEffect(.degrees(angle))
            .frame(width: 17, height: 17) // pad so rotated tips aren't clipped

        let renderer = ImageRenderer(content: glyph)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let nsImage = renderer.nsImage {
            nsImage.isTemplate = true
            image = nsImage
        }
    }
}

/// A 4-point sparkle with concave sides, normalized to a unit bounding box.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let R = min(rect.width, rect.height) / 2
        let k = R * 0.16
        var p = Path()
        p.move(to: CGPoint(x: cx, y: cy - R))
        p.addQuadCurve(to: CGPoint(x: cx + R, y: cy), control: CGPoint(x: cx + k, y: cy - k))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy + R), control: CGPoint(x: cx + k, y: cy + k))
        p.addQuadCurve(to: CGPoint(x: cx - R, y: cy), control: CGPoint(x: cx - k, y: cy + k))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy - R), control: CGPoint(x: cx - k, y: cy - k))
        p.closeSubpath()
        return p
    }
}
