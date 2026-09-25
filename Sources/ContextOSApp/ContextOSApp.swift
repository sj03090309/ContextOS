import SwiftUI
import AppKit
import Combine
import ContextOSCore

@main
struct ContextOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI requires one scene even though ContextOS is a menu-bar-only
        // app. `Settings { EmptyView() }` made macOS open a blank “ContextOS
        // Settings” window at launch. Keep an inert scene solely for the app
        // lifecycle, hide it immediately, and remove the Settings menu command.
        WindowGroup("ContextOS", id: "contextos-lifecycle") {
            LifecycleSceneView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}

/// An invisible lifecycle host for the SwiftUI `App` protocol. The real UI is
/// the AppKit status item and its popover, installed by `AppDelegate`.
private struct LifecycleSceneView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
    }
}

/// Owns the status-bar item and the popover. Using AppKit's `NSStatusItem` +
/// `NSPopover` (instead of SwiftUI's `MenuBarExtra`) gives us the popover
/// **arrow anchored to the mascot** — the window visibly points back to the
/// menu-bar icon, the way native status-bar apps do.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, ObservableObject {
    private static let lifecycleWindowPrefix = "contextos-lifecycle-"
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = DashboardModel()
    private lazy var mascot = MascotRenderer(state: model.mascot)
    private var subscriptions: Set<AnyCancellable> = []
    private var glyphLayerHost: NSView?
    /// The panel's tab and open cards, which outlive its views.
    private let dashboardUI = DashboardUIState()
    /// Releases the panel's views once it has stayed shut for a while.
    private var panelRelease: Timer?
    private static let panelReleaseDelay: TimeInterval = 120

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
            let host = MascotHostView(frame: NSRect(x: 0, y: 0,
                                                    width: MascotRenderer.glyphWidth, height: 24))
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
            // AppKit tells the view when the menu bar turns light/dark or moves to
            // a screen of another scale; the renderer used to ask on every frame.
            host.onEnvironmentChange = { [weak self] in self?.mascot.environmentChanged() }
            button.addSubview(host)
            glyphLayerHost = host
            // An empty image of the right size still reserves the layout space
            // the glyph occupies, without ever being drawn into.
            button.image = NSImage(size: NSSize(width: MascotRenderer.glyphWidth, height: 24))
            // The number sits right against 뭉치 rather than a full space away.
            button.imageHugsTitle = true
        }

        popover.behavior = .transient        // closes when you click away
        popover.animates = true
        // A transient popover also closes on click-away, which never goes
        // through togglePopover — so the "it's hidden now" signal comes from the
        // popover itself rather than from our own button handler.
        popover.delegate = self
        // The panel's views are built the first time it opens, not at launch —
        // see `schedulePanelRelease`.

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
        Publishers.CombineLatest(model.$todaySaved, AppSettings.shared.$showMenuBarSavings)
            .map { saved, show in show && saved > 0 ? TokenEstimator.korean(saved) : "" }
            .removeDuplicates()
            .sink { [weak self] title in self?.statusItem.button?.attributedTitle = Self.menuBarTitle(title) }
            .store(in: &subscriptions)
        hideLifecycleWindow()
    }

    /// Today's savings as the menu bar shows it: a notch smaller and a weight
    /// heavier than the bar's own text, so it reads as a figure beside 뭉치
    /// instead of a sentence, and takes less of a crowded bar.
    private static func menuBarTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .kern: -0.1
        ])
    }

    /// `WindowGroup` is required by SwiftUI's `App` lifecycle, but ContextOS
    /// has no document window. Limit this to our scene identifier so project
    /// windows opened from the dashboard remain visible.
    func applicationDidBecomeActive(_ notification: Notification) {
        hideLifecycleWindow()
    }

    private func hideLifecycleWindow() {
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.identifier?.rawValue.hasPrefix(Self.lifecycleWindowPrefix) == true }
                .forEach { $0.orderOut(nil) }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        mascot.userInteracted()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            panelRelease?.invalidate()
            panelRelease = nil
            if popover.contentViewController == nil {
                // Two hosting views, not one: see `PopoverContentController`.
                popover.contentViewController = PopoverContentController(model: model, ui: dashboardUI)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            // Usage, agents and git only refresh while someone can see them.
            model.panelDidOpen()
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
        dashboardUI.showSettings = false
        model.panelDidClose()
        schedulePanelRelease()
    }

    /// NSPopover holds on to its content view controller — and with it both
    /// SwiftUI trees, the calendar, the cards and 뭉치's metaball — for as long
    /// as the app runs, though the panel is on screen for seconds a day. Once
    /// it has stayed shut for a couple of minutes, let it all go; opening it
    /// again rebuilds it the way the very first open always did, and
    /// `dashboardUI` brings back the tab and the cards that were open.
    private func schedulePanelRelease() {
        panelRelease?.invalidate()
        let timer = Timer(timeInterval: Self.panelReleaseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.popover.isShown else { return }
                self.popover.contentViewController = nil
                self.panelRelease = nil
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        panelRelease = timer
    }
}

extension Notification.Name {
    static let contextOSPopoverOpened = Notification.Name("contextOSPopoverOpened")
    static let contextOSPopoverClosed = Notification.Name("contextOSPopoverClosed")
}

/// Hosts 뭉치's layer inside the status button and passes on what AppKit tells
/// it about the menu bar — its light/dark appearance, and the backing scale of
/// the screen it is on — so the renderer never has to poll for either.
final class MascotHostView: NSView {
    var onEnvironmentChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEnvironmentChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onEnvironmentChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onEnvironmentChange?()
    }
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

    /// What the timer is currently paced for.
    ///
    /// The timer used to tick at a flat 20Hz — above the fastest loop, so no
    /// frame was missed — which woke the app 20 times a second for life, though
    /// the breath it spends nearly all of that life in only changes frame ~4
    /// times a second. Now it ticks exactly once per frame of whatever is
    /// playing, and only the short ease between the two runs at the full rate.
    private enum Pace: Equatable { case idle, eating, easing, still }
    private var pace: Pace?
    private static let easingFPS: Double = 20

    /// Nothing is on screen to animate: the displays are asleep, the screen is
    /// locked, or another user has the console. The timer is stopped outright
    /// rather than ticking into the dark.
    private var screensAsleep = false
    private var screenLocked = false
    private var sessionInactive = false
    private var suspended: Bool { screensAsleep || screenLocked || sessionInactive }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var eatingChange: AnyCancellable?
    private var motionChange: AnyCancellable?
    private let settings = AppSettings.shared

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

    /// Width of the glyph in the menu bar: the blob's own 18pt, plus just
    /// enough for its chew to widen it. It used to be 30, to leave room for food
    /// flying in from both sides — at 18px those bits read as a stray speck
    /// between 뭉치 and its number, and the room made the item needlessly wide.
    static let glyphWidth: CGFloat = 20
    private static var idleFrames: Int { Int(idlePeriod * idleFPS) }
    private static var eatFrames: Int { Int(MascotBeat.cycle * eatFPS) }

    init(state: MascotState) {
        self.state = state
        // The notifications below only report changes. Launched (or relaunched
        // by an update) behind a locked screen or with the displays off, start
        // paused — and know it before the first tick, which AppKit can trigger
        // as soon as the glyph's view lands in the menu bar.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        screenLocked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    func start() {
        guard eatingChange == nil else { return }
        // A start or stop is picked up the moment it happens rather than on the
        // next tick. `@Published` announces a change *before* making it, so the
        // tick is deferred until the new value is actually in.
        eatingChange = state.$eating
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tick() }
        // The settings menu's "뭉치 움직임": re-pace at once.
        motionChange = settings.$mascotMotion
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pace = nil
                self?.lastIndex = -1
                self?.tick()
            }
        observeScreens()
        environmentChanged()
        tick()
    }

    /// The menu bar may have changed appearance or scale — re-render the loops
    /// if it did. Called by the view hosting the glyph, which AppKit notifies.
    func environmentChanged() {
        let scale = menuBarScale
        let dark = menuBarIsDark
        guard scale != loopScale || dark != loopIsDark else { return }
        rebuildLoops(scale: scale, dark: dark)
        // Paused or not, the status item always holds a glyph: started behind a
        // locked screen, 뭉치 is still there, standing still, the moment it shows.
        if suspended, let still = idleLoop.first { image = still }
        tick()
    }

    /// Someone just clicked 뭉치, so the menu bar is plainly on screen — resume
    /// even if a wake or unlock notification went astray.
    func userInteracted() {
        setSuspended(asleep: false, locked: false, inactive: false)
    }

    private func tick() {
        guard !suspended else {
            // However it came to be running, a timer has nothing to draw now.
            timer?.invalidate()
            timer = nil
            pace = nil
            return
        }
        let now = Date()
        let motion = settings.mascotMotion
        // Set never to chew, 뭉치 ignores the chew state entirely.
        let eating = motion.chews && state.eating
        let k = motion.chews ? state.intensity(at: now) : 0
        // Steady only once the ease has all but reached where it is heading;
        // until then every frame is a unique blend and is drawn live. At rest
        // and set not to breathe, it stands still on the first frame.
        let pace: Pace = eating
            ? (k >= 0.98 ? .eating : .easing)
            : (k <= 0.02 ? (motion.breathes ? .idle : .still) : .easing)

        switch pace {
        case .idle:
            show(loop: idleLoop, phase: idlePhase(now), tag: 0)
        case .still:
            show(loop: idleLoop, phase: 0, tag: 0)
        case .eating:
            show(loop: eatLoop, phase: MascotBeat.foodPhase(now, lane: 0), tag: 1)
        case .easing:
            lastIndex = -1
            image = frame(at: now, intensity: k, scale: loopScale, dark: loopIsDark ?? false)
        }
        if pace != self.pace {
            self.pace = pace
            // A start or stop is also the cheap moment to double-check the menu
            // bar's appearance, in case a change slipped past the host view.
            environmentChanged()
            reschedule()
        }
    }

    /// Re-arm the timer for the current pace.
    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard !suspended, let pace else { return }

        let interval: TimeInterval
        var fire = Date()
        switch pace {
        case .still:
            return                      // nothing moves, so nothing ticks
        case .easing:
            interval = 1 / Self.easingFPS
            fire = fire.addingTimeInterval(interval)
        case .idle, .eating:
            let period = pace == .idle ? Self.idlePeriod : MascotBeat.cycle
            interval = period / Double(pace == .idle ? Self.idleFrames : Self.eatFrames)
            // `show` rounds the phase to the nearest frame, so frame j takes over
            // half a frame before its own instant. Firing just after each of
            // those points means every tick lands on a new frame: none skipped,
            // none shown twice, and the timer stays locked to the same absolute
            // clock the dashboard's 뭉치 reads.
            let t = fire.timeIntervalSince1970 / interval
            fire = Date(timeIntervalSince1970: (floor(t - 0.5) + 1.5) * interval + 0.001)
        }
        let timer = Timer(fire: fire, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func setSuspended(asleep: Bool? = nil, locked: Bool? = nil, inactive: Bool? = nil) {
        let was = suspended
        if let asleep { screensAsleep = asleep }
        if let locked { screenLocked = locked }
        if let inactive { sessionInactive = inactive }
        guard suspended != was else { return }
        if suspended {
            timer?.invalidate()
            timer = nil
        } else {
            // Back on screen: pick up wherever the clock is now.
            pace = nil
            lastIndex = -1
            environmentChanged()
            tick()
        }
    }

    private func observeScreens() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name,
                _ body: @escaping @MainActor (MascotRenderer) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            }
            observers.append((center, token))
        }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.setSuspended(asleep: true) }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.setSuspended(asleep: false) }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.setSuspended(locked: true) }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.setSuspended(locked: false) }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSuspended(inactive: true) }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSuspended(inactive: false) }
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
    /// on. Re-read whenever the host view reports a backing change, so moving the
    /// bar between a Retina and a 1x display re-renders the loops at the new scale.
    private var menuBarScale: CGFloat {
        appearanceSource?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    /// Whether the menu bar is currently dark.
    ///
    /// Re-read whenever the host view reports an appearance change — a theme
    /// switch, a wallpaper change behind the bar, or a move to another display.
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
        let eatSX = 1.0 + 0.24 * chomp
        let eatSY = 1.0 - 0.2 * chomp

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

        // In the menu bar the chew alone says "eating"; the food is the
        // dashboard's to show, where there is room for it.
        let glyph = blob
            .frame(width: Self.glyphWidth, height: 24)

        let renderer = ImageRenderer(content: glyph)
        renderer.scale = scale
        return renderer.nsImage ?? image
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
