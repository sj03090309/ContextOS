import SwiftUI
import AppKit
import ContextOSCore

@main
struct ContextOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar-only agent: the UI lives entirely in the status item + popover
        // managed by AppDelegate. This empty Settings scene keeps SwiftUI happy
        // without opening a window.
        Settings { EmptyView() }
    }
}

/// Owns the status-bar item and the popover. Using AppKit's `NSStatusItem` +
/// `NSPopover` (instead of SwiftUI's `MenuBarExtra`) gives us the popover
/// **arrow anchored to the mascot** — the window visibly points back to the
/// menu-bar icon, the way native status-bar apps do.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = DashboardModel()
    private let mascot = MascotRenderer()
    private var uiTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no standalone window.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = mascot.image
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient        // closes when you click away
        popover.animates = true
        let host = NSHostingController(rootView: DashboardView().environmentObject(model))
        host.sizingOptions = [.preferredContentSize]   // auto-fit the SwiftUI content
        popover.contentViewController = host

        mascot.start()
        // Push the freshly-rendered mascot frame (and today's savings) onto the
        // status button, and keep the mascot's idle/active state in sync.
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncButton() }
        }
    }

    private func syncButton() {
        mascot.setActive(model.flashing)
        guard let button = statusItem.button else { return }
        button.image = mascot.image
        button.title = model.todaySaved > 0 ? " " + TokenEstimator.korean(model.todaySaved) : ""
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Renders "뭉치" — the ContextOS blob mascot — to a bitmap on every animation
/// tick. Idle → a slow gentle bob; active (MCP optimizing) → a fast squash-and-
/// stretch bounce.
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
        // 60fps for smooth motion.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    private func render() {
        let t = Date().timeIntervalSince(startedAt)
        let bob: CGFloat        // vertical offset
        let scaleY: CGFloat     // squash & stretch
        let scaleX: CGFloat
        // Pure sinusoids (no abs/cusp) keep the bounce buttery smooth. The squash
        // is a quarter-phase behind the bob so it stretches at the top of the hop
        // and squashes at the bottom.
        if active {
            let phase = t * 6.0     // lively but smooth
            bob = sin(phase) * 3.4
            scaleY = 1 + 0.11 * cos(phase)
            scaleX = 1 - 0.11 * cos(phase)
        } else {
            let phase = t * 2.0     // gentle idle breathing
            bob = sin(phase) * 1.6
            scaleY = 1 + 0.05 * cos(phase)
            scaleX = 1 - 0.05 * cos(phase)
        }

        // Solid black on transparent + isTemplate: macOS then auto-adapts the
        // icon to the menu bar's light/dark appearance, same as SF Symbols do.
        // Eyes are punched as holes via an even-odd fill so the bar shows through.
        let glyph = BlobShape()
            .fill(Color.black, style: FillStyle(eoFill: true))
            .frame(width: 19, height: 19)
            .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
            .offset(y: bob)
            .frame(width: 22, height: 22) // pad so the bounce isn't clipped

        let renderer = ImageRenderer(content: glyph)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let nsImage = renderer.nsImage {
            nsImage.isTemplate = true
            image = nsImage
        }
    }
}

/// A rounded blob with two cut-out eyes, designed in a 48×48 space and scaled
/// to fit. Fill with even-odd style so the eyes read as holes.
private struct BlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 48 * rect.width,
                    y: rect.minY + y / 48 * rect.height)
        }
        var p = Path()
        // Body.
        p.move(to: pt(24, 6))
        p.addCurve(to: pt(40, 26), control1: pt(34, 6), control2: pt(40, 14))
        p.addCurve(to: pt(24, 42), control1: pt(40, 38), control2: pt(33, 42))
        p.addCurve(to: pt(8, 26), control1: pt(15, 42), control2: pt(8, 38))
        p.addCurve(to: pt(24, 6), control1: pt(8, 14), control2: pt(14, 6))
        p.closeSubpath()
        // Eyes (holes).
        let er: CGFloat = 3.1
        p.addEllipse(in: CGRect(origin: pt(18 - er, 24 - er),
                                size: CGSize(width: er / 24 * rect.width, height: er / 24 * rect.height)))
        p.addEllipse(in: CGRect(origin: pt(30 - er, 24 - er),
                                size: CGSize(width: er / 24 * rect.width, height: er / 24 * rect.height)))
        return p
    }
}
