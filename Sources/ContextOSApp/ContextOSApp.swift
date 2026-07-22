import SwiftUI
import AppKit
import Combine
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = DashboardModel()
    private lazy var mascot = MascotRenderer(state: model.mascot)
    private var subscriptions: Set<AnyCancellable> = []
    private var glyphLayerHost: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no standalone window.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
            // 뭉치 is drawn into a layer of its own rather than into
            // `button.image`. Assigning the button's image makes AppKit redraw
            // the whole cell — button, menu-bar background, and the item's
            // replicant snapshot — which measured at ~0.6% of a core per swap
            // per second, i.e. ~10% just to animate an 18px glyph. Swapping a
            // layer's `contents` hands Core Animation a different texture and
            // skips all of it: the same animation costs ~1%.
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
            host.wantsLayer = true
            // `.resizeAspect`, not `.center`: with `.center` a layer sizes its
            // contents as `pixels / contentsScale` and crops the overflow, so the
            // glyph is only the right size while the bitmap's scale and the
            // layer's agree. They don't have to — the frames are rasterized for
            // one screen and the layer's scale comes from whichever screen the
            // menu bar is on. On a 2x built-in + 1x external that mismatch drew
            // 뭉치 at half size and cropped it to the band across its eyes.
            // `.resizeAspect` fits the bitmap to the layer's 30×24, so the glyph
            // is always the right size and the scale only decides sharpness.
            host.layer?.contentsGravity = .resizeAspect
            button.addSubview(host)
            glyphLayerHost = host
            // An empty image of the right size still reserves the layout space
            // the glyph occupies, without ever being drawn into.
            button.image = NSImage(size: NSSize(width: 30, height: 24))
        }

        popover.behavior = .transient        // closes when you click away
        popover.animates = true
        // A transient popover also closes on click-away, which never goes
        // through togglePopover — so the "it's hidden now" signal comes from the
        // popover itself rather than from our own button handler.
        popover.delegate = self
        // Two hosting views, not one: see `PopoverContentController`.
        popover.contentViewController = PopoverContentController(model: model)

        mascot.appearanceSource = statusItem.button
        mascot.start()
        // React to each new frame instead of polling for one. The old 60Hz timer
        // spun up a Task 60 times a second to ask whether anything had changed;
        // the answer is published, so it can just be listened to.
        mascot.$image
            .sink { [weak self] image in
                guard let layer = self?.glyphLayerHost?.layer else { return }
                // Hand the layer the bitmap's own scale so it isn't resampled on
                // the way in; `.resizeAspect` has already made the *size* right,
                // this is only about staying sharp.
                if let rep = image.representations.first, image.size.width > 0 {
                    let dpr = CGFloat(rep.pixelsWide) / image.size.width
                    if dpr > 0 && layer.contentsScale != dpr { layer.contentsScale = dpr }
                }
                layer.contents = image
            }
            .store(in: &subscriptions)
        model.$todaySaved
            .map { $0 > 0 ? " " + TokenEstimator.korean($0) : "" }
            .removeDuplicates()
            .sink { [weak self] title in self?.statusItem.button?.title = title }
            .store(in: &subscriptions)
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

extension AppDelegate {
    /// NSPopover keeps its hosted view alive after dismissal, so the dashboard
    /// has to be told to stop animating; nothing else will.
    func popoverDidClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .contextOSPopoverClosed, object: nil)
    }
}

extension Notification.Name {
    static let contextOSPopoverOpened = Notification.Name("contextOSPopoverOpened")
    static let contextOSPopoverClosed = Notification.Name("contextOSPopoverClosed")
}

/// Renders "뭉치" — the ContextOS blob mascot — to a bitmap on every animation
/// tick. Three tiers: idle → a slow gentle breathing bob; working (a Claude Code
/// session is alive) → a livelier hop; active (MCP optimizing) → a fast
/// squash-and-stretch bounce.
@MainActor
final class MascotRenderer: ObservableObject {
    @Published private(set) var image = NSImage(size: .zero)

    private var timer: Timer?
    /// Chew state, shared with the dashboard's 뭉치 so the two move as one.
    private let state: MascotState

    /// Pre-rendered loops for the two states 뭉치 spends ~all of its life in.
    ///
    /// Rasterizing a SwiftUI view with `ImageRenderer` is expensive — doing it
    /// 20 times a second to animate an 18px glyph cost ~30% of a core while the
    /// app sat there doing nothing. But both steady states are exactly periodic:
    /// the breath repeats every π seconds, the chew every `MascotBeat.cycle`. So
    /// each loop is rendered once and then replayed by indexing on the phase,
    /// and the steady states cost no drawing at all.
    ///
    /// Only the ease between them (a few hundred ms) still renders live, because
    /// the blend is a second dimension and caching it would mean a whole table
    /// of frames to save a fraction of a second of work.
    private var idleLoop: [NSImage] = []
    private var eatLoop: [NSImage] = []
    /// The view whose appearance decides 뭉치's colour — the status button, since
    /// the menu bar's light/dark state is its own and does not follow the app's.
    weak var appearanceSource: NSView?

    /// The scale and menu-bar appearance the cached frames were rendered for.
    /// Either changing invalidates them.
    private var loopScale: CGFloat = 0
    private var loopIsDark: Bool?
    private var lastIndex = -1

    /// The breath's period: `sin(t · 2)` repeats every π seconds.
    private static let idlePeriod = Double.pi

    // Frame counts, i.e. how often the status item's image is swapped.
    //
    // This is the app's whole animation cost, and it is not cheap per swap:
    // AppKit answers every `button.image =` by re-snapshotting the status item
    // and its menu-bar replicants into a bitmap, measured at ~0.6% of a core per
    // swap-per-second. At 30fps that is ~25% of a core spent wiggling an 18px
    // glyph. So the rates are set against what each motion actually needs: the
    // chomp is 3.6Hz and gets 20fps (~5 samples per bite, which reads as
    // smooth), while the breath is only 0.32Hz and stays at 4fps because a
    // 1.6px bob needs nothing more.
    private static let idleFPS: Double = 4
    private static let eatFPS: Double = 16
    private static var idleFrames: Int { Int(idlePeriod * idleFPS) }
    private static var eatFrames: Int { Int(MascotBeat.cycle * eatFPS) }

    init(state: MascotState) {
        self.state = state
    }

    func start() {
        guard timer == nil else { return }
        tick()
        // Ticks a little above the fastest loop so no frame is missed, and so a
        // start/stop is picked up promptly. A tick that finds the same frame
        // costs an array index and nothing else.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / (Self.eatFPS + 4),
                                     repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let scale = menuBarScale
        let dark = menuBarIsDark
        if scale != loopScale || dark != loopIsDark { rebuildLoops(scale: scale, dark: dark) }

        let k = state.intensity(at: now)
        if k <= 0.02 {
            show(loop: idleLoop, phase: idlePhase(now), tag: 0)
        } else if k >= 0.98 {
            show(loop: eatLoop, phase: MascotBeat.foodPhase(now, lane: 0), tag: 1)
        } else {
            // Mid-ease: the blend is unique to this instant, so draw it.
            lastIndex = -1
            image = frame(at: now, intensity: k, scale: scale, dark: dark)
        }
    }

    /// 0…1 through one breath.
    private func idlePhase(_ time: Date) -> Double {
        (time.timeIntervalSince1970 / Self.idlePeriod).truncatingRemainder(dividingBy: 1)
    }

    /// Swap in a cached frame, touching the published image only when the frame
    /// actually changes — AppKit re-lays out the status item on every assignment.
    private func show(loop: [NSImage], phase: Double, tag: Int) {
        guard !loop.isEmpty else { return }
        // Round rather than floor: flooring would always pick the frame *before*
        // now, so the menu bar would sit a consistent half-frame behind the
        // dashboard's 뭉치. Rounding centres that error on zero for free.
        let index = Int((phase * Double(loop.count)).rounded()) % loop.count
        let key = tag * 1000 + index
        guard key != lastIndex else { return }
        lastIndex = key
        image = loop[index]
    }

    /// The backing scale of the screen the menu bar is on.
    ///
    /// Not `NSScreen.main` — that is the *focused* screen, which is a different
    /// one whenever the menu bar with 뭉치 in it isn't the screen you're typing
    /// on. Read every tick like the appearance, so moving the bar between a
    /// Retina and a 1x display re-renders the loops at the new scale by itself.
    private var menuBarScale: CGFloat {
        appearanceSource?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    /// Whether the menu bar is currently dark.
    ///
    /// Read every tick rather than observed: it is a property read, and polling
    /// it means the colour self-corrects on a theme switch, a wallpaper change
    /// behind the bar, or a move to another display — without a KVO observer to
    /// forget to tear down.
    private var menuBarIsDark: Bool {
        // The status button reports `NSAppearanceNameVibrantDark` rather than
        // `darkAqua`, which is why the raw name is no use here — `bestMatch`
        // resolves the vibrant variants onto the two that matter.
        let appearance = appearanceSource?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func rebuildLoops(scale: CGFloat, dark: Bool) {
        loopScale = scale
        loopIsDark = dark
        lastIndex = -1
        // Any epoch works: the loops are periodic, so sampling one period from
        // anywhere produces the same set of frames.
        let epoch = Date(timeIntervalSince1970: 0)
        idleLoop = (0..<Self.idleFrames).map { index in
            let t = Self.idlePeriod * Double(index) / Double(Self.idleFrames)
            return frame(at: epoch.addingTimeInterval(t), intensity: 0, scale: scale, dark: dark)
        }
        eatLoop = (0..<Self.eatFrames).map { index in
            let t = MascotBeat.cycle * Double(index) / Double(Self.eatFrames)
            return frame(at: epoch.addingTimeInterval(t), intensity: 1, scale: scale, dark: dark)
        }
    }

    /// Draw 뭉치 as it looks at `now`, chewing `intensity` hard.
    private func frame(at now: Date, intensity k: Double, scale: CGFloat, dark: Bool) -> NSImage {
        let blend = CGFloat(max(0, min(1, k)))

        // Idle breathing (calm sinusoids).
        let breath = MascotBeat.breath(now)
        let idleBob = breath * 1.6
        let idleSY = 1 + 0.05 * breath
        let idleSX = 1 - 0.05 * breath

        // Eating chomp, timed to each bite arriving.
        let chomp = MascotBeat.chomp(now)
        let eatBob = -chomp * 1.4
        let eatSX = 1.0 + 0.34 * chomp
        let eatSY = 1.0 - 0.28 * chomp

        // Blend idle → eating by the eased intensity.
        let bob = idleBob * (1 - blend) + eatBob * blend
        let scaleX = idleSX * (1 - blend) + eatSX * blend
        let scaleY = idleSY * (1 - blend) + eatSY * blend

        // The colour is picked here rather than left to `isTemplate`: the glyph
        // reaches the screen as a CALayer's contents, and template inversion is
        // a feature of NSImage drawing that a raw layer never gets — which is
        // why an untinted 뭉치 came out black-on-black in a dark menu bar.
        // Eyes are punched as holes via an even-odd fill so the bar shows through.
        let tint = dark ? Color.white : Color.black
        let blob = BlobShape()
            .fill(tint, style: FillStyle(eoFill: true))
            .frame(width: 18, height: 18)
            .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
            .offset(y: bob)

        // The food bits, behind the blob so they vanish *into* it. A constant
        // 30-wide frame (vs the blob's 18) gives them travel room and keeps the
        // status-item width from jumping when eating starts/stops. Their opacity
        // rides the intensity, so they fade in/out with the ramp.
        let glyph = ZStack {
            if blend > 0.02 {
                ForEach(0..<MascotBeat.lanes, id: \.self) { lane in
                    self.foodBit(lane: lane, now: now, fade: blend, tint: tint)
                }
            }
            blob
        }
        .frame(width: 30, height: 24)

        let renderer = ImageRenderer(content: glyph)
        renderer.scale = scale
        return renderer.nsImage ?? image
    }

    /// One food bit flying in from a side toward 뭉치 and being absorbed.
    /// Lane 0 comes from the left, lane 1 from the right, staggered half a cycle.
    @ViewBuilder
    private func foodBit(lane: Int, now: Date, fade: CGFloat, tint: Color) -> some View {
        let phase = MascotBeat.foodPhase(now, lane: lane)
        let fadeScale = MascotBeat.foodFade(phase)
        let dir: CGFloat = lane == 0 ? -1 : 1
        let x = dir * 16 * CGFloat(1 - phase)     // edge (±16) → center (0)
        RoundedRectangle(cornerRadius: 1.2)
            .fill(tint)
            .frame(width: 5, height: 6)
            .scaleEffect(max(0.2, CGFloat(fadeScale.scale)))
            .opacity(fadeScale.opacity * fade)
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
