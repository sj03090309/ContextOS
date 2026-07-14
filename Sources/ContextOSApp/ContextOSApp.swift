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
        mascot.setState(active: model.flashing, working: model.working)
        guard let button = statusItem.button else { return }
        // Only touch the button when something actually changed — this runs at
        // up to 60Hz and AppKit re-lays-out the status item on every assignment.
        if button.image !== mascot.image { button.image = mascot.image }
        let title = model.todaySaved > 0 ? " " + TokenEstimator.korean(model.todaySaved) : ""
        if button.title != title { button.title = title }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            // NSPopover reuses its hosted view, so onAppear only fires once. Signal
            // the dashboard to replay the droplet melt-in on every open.
            NotificationCenter.default.post(name: .contextOSPopoverOpened, object: nil)
        }
    }
}

extension Notification.Name {
    static let contextOSPopoverOpened = Notification.Name("contextOSPopoverOpened")
}

/// Renders "뭉치" — the ContextOS blob mascot — to a bitmap on every animation
/// tick. Three tiers: idle → a slow gentle breathing bob; working (a Claude Code
/// session is alive) → a livelier hop; active (MCP optimizing) → a fast
/// squash-and-stretch bounce.
@MainActor
final class MascotRenderer: ObservableObject {
    @Published private(set) var image = NSImage(size: .zero)

    private var timer: Timer?
    private var active = false
    private var working = false
    private var frame = 0
    private let startedAt = Date()

    func setState(active: Bool, working: Bool) {
        self.active = active
        self.working = working
    }

    func start() {
        guard timer == nil else { return }
        render()
        // The timer ticks at 60Hz but rendering is decimated: 30fps while busy
        // (plenty for a ~3.5Hz chomp on an 18px glyph), 20fps while idle.
        // `working` can stay on for hours during a long agent session, so a full
        // 60fps bitmap render there would be a constant CPU tax for nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.frame += 1
                let step = (self.active || self.working) ? 2 : 3
                if self.frame % step == 0 { self.render() }
            }
        }
    }

    // "Both-sides suction" (style A): little bits fly into 뭉치 from the left and
    // right, one absorbed every half-cycle, each landing a chomp.
    private let foodCycle = 0.55

    private func render() {
        let t = Date().timeIntervalSince(startedAt)
        // 뭉치 eats the whole time the agent is working on the user's request —
        // from the moment they hit enter (working) through each optimization
        // (active) until the response settles — not just in a brief flash.
        let eating = active || working
        let bob: CGFloat        // vertical offset
        let scaleY: CGFloat     // squash & stretch
        let scaleX: CGFloat
        let tilt: CGFloat       // left/right wiggle, in degrees
        if eating {
            // Chomp timed to each bite arriving (2 per cycle, alternating sides).
            let frac = (t / foodCycle).truncatingRemainder(dividingBy: 1)
            let chomp = pow((cos(4 * .pi * frac) + 1) / 2, 5)
            bob = -chomp * 1.4
            scaleX = 1.0 + 0.36 * chomp     // gape wide then snap shut
            scaleY = 1.0 - 0.30 * chomp
            tilt = 0
        } else {
            // Idle → a calm, smooth breathing bob (pure sinusoids, no cusp).
            let phase = t * 2.0
            bob = sin(phase) * 1.6
            scaleY = 1 + 0.05 * cos(phase)
            scaleX = 1 - 0.05 * cos(phase)
            tilt = 0
        }

        // Solid black on transparent + isTemplate: macOS then auto-adapts the
        // icon to the menu bar's light/dark appearance, same as SF Symbols do.
        // Eyes are punched as holes via an even-odd fill so the bar shows through.
        let blob = BlobShape()
            .fill(Color.black, style: FillStyle(eoFill: true))
            .frame(width: 18, height: 18)
            .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            .offset(y: bob)

        // The food bits, behind the blob so they vanish *into* it. A constant
        // 30-wide frame (vs the blob's 18) gives them travel room and keeps the
        // status-item width from jumping when eating starts/stops.
        let glyph = ZStack {
            if eating {
                foodBit(lane: 0, t: t)   // from the left
                foodBit(lane: 1, t: t)   // from the right
            }
            blob
        }
        .frame(width: 30, height: 24)

        let renderer = ImageRenderer(content: glyph)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let nsImage = renderer.nsImage {
            nsImage.isTemplate = true
            image = nsImage
        }
    }

    /// One food bit flying in from a side toward 뭉치 and being absorbed.
    /// Lane 0 comes from the left, lane 1 from the right, staggered half a cycle.
    @ViewBuilder
    private func foodBit(lane: Int, t: TimeInterval) -> some View {
        let phase = (t / foodCycle + Double(lane) * 0.5).truncatingRemainder(dividingBy: 1)
        let dir: CGFloat = lane == 0 ? -1 : 1
        let x = dir * 16 * CGFloat(1 - phase)     // edge (±16) → center (0)
        let opacity = phase < 0.12 ? phase / 0.12
            : (phase > 0.82 ? max(0, (1 - phase) / 0.18) : 1)
        let scale = phase > 0.82 ? max(0.2, CGFloat((1 - phase) / 0.18)) : 1
        RoundedRectangle(cornerRadius: 1.2)
            .fill(Color.black)
            .frame(width: 5, height: 6)
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(x: x, y: -1)
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
