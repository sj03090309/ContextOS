import SwiftUI
import AppKit
import Combine
import ContextOSCore
import ContextOSUsage

@main
enum ContextOSApp {
    @MainActor static func main() {
        // AppKit owns every window. A transparent SwiftUI WindowGroup still
        // opens a real default window on URL/reopen events; hiding guessed
        // scene identifiers cannot make that lifecycle reliable.
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
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
    private lazy var model = DashboardModel()
    private let usageWindow = UsageWindowController()
    private lazy var dashboardWindow = DashboardWindowController(model: model, ui: dashboardUI)
    private var didLaunch = false
    private var pendingPage: DashboardUIState.Page?

    func application(_ application: NSApplication, open urls: [URL]) {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "ContextOSURLScheme") as? String ?? "contextos"
        guard urls.contains(where: { WidgetSnapshotStore.accepts($0, scheme: scheme) }) else { return }
        if didLaunch { showUsage() } else { pendingPage = .usage }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if didLaunch { openDashboardWindow() } else { pendingPage = .overview }
        return false
    }
    private var isUsageReview: Bool {
        Bundle.main.bundleIdentifier == "com.contextos.review" || Bundle.main.bundleIdentifier == "com.contextos.timecandidate"
            || ProcessInfo.processInfo.arguments.contains("--usage-review")
    }
    private var reviewTitle: String {
        Bundle.main.bundleIdentifier == "com.contextos.timecandidate" ? "ContextOS · 시간 후보" : "ContextOS Review · 합성 데이터"
    }
    private func showUsage() {
        if isUsageReview {
            usageWindow.show(UsageReviewRoot(), title: reviewTitle)
        } else {
            dashboardUI.navigate(to: .usage)
            showPopover()
        }
    }
    private func showPage(_ page: DashboardUIState.Page) {
        if isUsageReview { showUsage(); return }
        dashboardUI.navigate(to: page)
        showPopover()
    }
    private lazy var mascot = MascotRenderer(state: model.mascot)
    private var subscriptions: Set<AnyCancellable> = []
    /// The panel's tab and open cards, which outlive its views.
    private let dashboardUI = DashboardUIState()
    /// Releases the panel's views once it has stayed shut for a while.
    private var panelRelease: Timer?
    private static let panelReleaseDelay: TimeInterval = 120

    func applicationDidFinishLaunching(_ notification: Notification) {
        defer {
            didLaunch = true
            if let page = pendingPage { pendingPage = nil; showPage(page) }
        }
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(title: "ContextOS"); item.submenu = appMenu
        let openWindow = NSMenuItem(title: "대시보드를 창으로 열기", action: #selector(openDashboardWindow), keyEquivalent: "o")
        openWindow.keyEquivalentModifierMask = [.command, .shift]
        openWindow.target = self
        appMenu.addItem(openWindow)
        appMenu.addItem(.separator())
        for (index, page) in DashboardUIState.Page.primary.enumerated() {
            let pageItem = NSMenuItem(title: page.label, action: #selector(openPageFromMenu(_:)), keyEquivalent: String(index + 1))
            pageItem.target = self
            pageItem.tag = index
            appMenu.addItem(pageItem)
        }
        appMenu.addItem(.separator())
        let detail = NSMenuItem(title: "AI 사용 현황…", action: #selector(openUsageFromMenu), keyEquivalent: "")
        detail.target = self; appMenu.addItem(detail)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ContextOS 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "모두 앞으로 가져오기", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        if isUsageReview {
            NSApp.setActivationPolicy(.regular)
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--usage-render-dir"), args.indices.contains(index + 1) {
                do { try UsageReviewRenderer.render(to: URL(fileURLWithPath: args[index + 1])) }
                catch { NSLog("Usage review rendering failed: %@", error.localizedDescription) }
                NSApp.terminate(nil)
                return
            }
            usageWindow.show(UsageReviewRoot(), title: reviewTitle)
            return
        }
        // No Dock icon, no standalone window.
        NSApp.setActivationPolicy(.accessory)
        dashboardUI.openWindow = { [weak self] in self?.openDashboardWindow() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.setAccessibilityLabel("ContextOS 대시보드")
            button.toolTip = "ContextOS 대시보드"
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
            let size = MenuBarMascotArtwork.canvasSize
            let host = MascotHostView(frame: NSRect(origin: .zero, size: size))
            mascot.host = host
            host.onEnvironmentChange = { [weak self] in self?.mascot.environmentChanged() }
            button.addSubview(host)
            // Keep the layout placeholder fixed while the glyph animates.
            button.image = NSImage(size: size)
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

        mascot.start()
        Publishers.CombineLatest(model.$todaySaved, AppSettings.shared.$showMenuBarSavings)
            .map { saved, show in show && saved > 0 ? TokenEstimator.korean(saved) : "" }
            .removeDuplicates()
            .sink { [weak self] title in self?.statusItem.button?.attributedTitle = Self.menuBarTitle(title) }
            .store(in: &subscriptions)
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

    @objc private func openUsageFromMenu() { showUsage() }

    @objc private func openDashboardWindow() {
        guard !isUsageReview else { showUsage(); return }
        dashboardWindow.show(preferredScreen: statusItem?.button?.window?.screen)
    }

    @objc private func openPageFromMenu(_ sender: NSMenuItem) {
        guard DashboardUIState.Page.primary.indices.contains(sender.tag) else { return }
        dashboardUI.navigate(to: DashboardUIState.Page.primary[sender.tag])
        showPopover()
    }

    @objc private func togglePopover() {
        guard statusItem?.button != nil else { return }
        mascot.userInteracted()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panelRelease?.invalidate()
            panelRelease = nil
            if popover.contentViewController == nil {
                // Two hosting views, not one: see `PopoverContentController`.
                popover.contentViewController = PopoverContentController(model: model, ui: dashboardUI)
            }
            if let controller = popover.contentViewController as? PopoverContentController {
                controller.prepare(for: button.window?.screen)
                popover.contentSize = controller.preferredContentSize
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            // Usage, agents and git only refresh while someone can see them.
            model.panelDidOpen()
            // NSPopover reuses its hosted view, so onAppear only fires once. Signal
            // the dashboard to replay the droplet melt-in on every open.
            NotificationCenter.default.post(name: .contextOSPopoverOpened, object: DashboardSurface.popover)
        }
    }
}

extension AppDelegate {
    /// NSPopover keeps its hosted view alive after dismissal, so the dashboard
    /// has to be told to stop animating; nothing else will.
    func popoverDidClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .contextOSPopoverClosed, object: DashboardSurface.popover)
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

/// The menu-bar button owns layout and input. The glyph uses private layers
/// so their transforms never change the button's frame or hit target.
final class MascotHostView: NSView {
    let poseLayer = CALayer()
    let artworkLayer = CALayer()
    var onEnvironmentChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        poseLayer.frame = bounds
        artworkLayer.frame = bounds
        artworkLayer.contentsGravity = .resizeAspect
        poseLayer.addSublayer(artworkLayer)
        layer?.addSublayer(poseLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

@MainActor
final class MascotRenderer {
    private struct ArtworkKey: Equatable {
        let scale: CGFloat
        let dark: Bool
        let tint: String
    }

    private enum Breath {
        case resting, working

        @MainActor var period: TimeInterval {
            self == .working ? MascotState.focusBreathPeriod : MascotState.restBreathPeriod
        }
    }

    weak var host: MascotHostView?
    private let state: MascotState
    private let settings = AppSettings.shared
    private var artworkKey: ArtworkKey?
    private var attached = false
    private var breath: Breath?
    private var breathTimer: Timer?

    private var screensAsleep = false
    private var screenLocked = false
    private var sessionInactive = false
    private var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var subscriptions: Set<AnyCancellable> = []

    init(state: MascotState) {
        self.state = state
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        screenLocked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    func start() {
        guard subscriptions.isEmpty else { return }
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMotion() }
            .store(in: &subscriptions)
        settings.$mascotMotion
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMotion() }
            .store(in: &subscriptions)
        settings.$mascotTint
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.environmentChanged() }
            .store(in: &subscriptions)
        observeScreens()
        environmentChanged()
    }

    func environmentChanged() {
        guard let host else { return }
        let isAttached = host.window != nil
        if let window = host.window {
            let appearance = host.superview?.effectiveAppearance ?? host.effectiveAppearance
            let key = ArtworkKey(scale: window.backingScaleFactor,
                                 dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                                 tint: settings.mascotTint)
            if artworkKey != key,
               let image = MenuBarMascotArtwork.image(hex: key.tint, dark: key.dark, scale: key.scale) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                host.artworkLayer.contentsScale = key.scale
                host.artworkLayer.contents = image
                CATransaction.commit()
                artworkKey = key
            }
        }
        guard isAttached != attached else { return }
        attached = isAttached
        updateMotion()
    }

    func userInteracted() {
        setSuspended(asleep: false, locked: false, inactive: false)
    }

    private func updateMotion() {
        guard let host else { return }
        let motion = settings.mascotMotion
        let animates = attached && !screensAsleep && !screenLocked && !sessionInactive
            && !reducedMotion && motion != .off
        updatePose(on: host.poseLayer, animates: animates, at: Date())

        let next: Breath? = animates ? (state.isWorking ? .working : motion.breathes ? .resting : nil) : nil
        if !animates { host.artworkLayer.removeAnimation(forKey: "breath") }
        guard next != breath else { return }
        breathTimer?.invalidate()
        breathTimer = nil
        breath = next
        if let next {
            startBreath(next)
            let timer = Timer(timeInterval: next.period, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.startBreath(next) }
            }
            // The compositor handles the pulse. Wake the app once per cycle.
            timer.tolerance = 0.15
            RunLoop.main.add(timer, forMode: .common)
            breathTimer = timer
        } else if animates, let current = host.artworkLayer.presentation()?.transform {
            let settle = CABasicAnimation(keyPath: "transform")
            settle.fromValue = NSValue(caTransform3D: current)
            settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            settle.duration = 0.18
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            settle.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 30, preferred: 24)
            host.artworkLayer.add(settle, forKey: "breath")
        } else {
            host.artworkLayer.removeAnimation(forKey: "breath")
        }
    }

    private func startBreath(_ breath: Breath) {
        guard self.breath == breath, let layer = host?.artworkLayer else { return }
        let current = layer.presentation()?.transform ?? CATransform3DIdentity
        let working = breath == .working
        let peak = CATransform3DMakeScale(working ? 0.96 : 0.98, working ? 1.09 : 1.045, 1)
        let pulse = CAKeyframeAnimation(keyPath: "transform")
        pulse.values = [current, peak, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        pulse.keyTimes = [0, NSNumber(value: MascotState.breathPeakFraction), 1]
        let easing = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.timingFunctions = [easing, easing]
        // Each breath has a quiet pause, with no animation registered between pulses.
        pulse.duration = breath.period * MascotState.breathActiveFraction
        pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 24, preferred: 18)
        layer.add(pulse, forKey: "breath")
    }

    private func updatePose(on layer: CALayer, animates: Bool, at now: Date) {
        let current = layer.presentation()?.transform ?? layer.transform
        let target = poseTransform(work: state.isWorking ? 1 : 0, nod: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
        guard animates else {
            layer.removeAnimation(forKey: "pose")
            return
        }

        let workEnd = state.isWorkTransitioning(at: now) ? state.workTransitionEnd ?? now : now
        let nodEnd = state.isNodding(at: now)
            ? state.optimizationCompletedAt?.addingTimeInterval(MascotState.nodDuration) ?? now : now
        let duration = max(workEnd, nodEnd).timeIntervalSince(now)
        guard duration > 0 else {
            layer.removeAnimation(forKey: "pose")
            return
        }
        // Join the same progress curves as the dashboard, including when work
        // reverses or a completion arrives partway through a posture change.
        let samples = 8
        var transforms = [NSValue(caTransform3D: current)]
        for step in 1...samples {
            let instant = now.addingTimeInterval(duration * Double(step) / Double(samples))
            let transform = step == samples ? target
                : poseTransform(work: state.workProgress(at: instant), nod: state.nodProgress(at: instant))
            transforms.append(NSValue(caTransform3D: transform))
        }
        let gesture = CAKeyframeAnimation(keyPath: "transform")
        gesture.values = transforms
        gesture.duration = duration
        gesture.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        layer.add(gesture, forKey: "pose")
    }

    private func poseTransform(work: Double, nod: Double) -> CATransform3D {
        CATransform3DMakeAffineTransform(
            CGAffineTransform(translationX: 0, y: 0.55 * work - 0.8 * nod)
                .rotated(by: -0.055 * work + 0.035 * nod)
                .scaledBy(x: 1.03 - 0.08 * work + 0.035 * nod, y: 0.96 + 0.12 * work - 0.07 * nod))
    }

    private func setSuspended(asleep: Bool? = nil, locked: Bool? = nil, inactive: Bool? = nil) {
        let wasSuspended = screensAsleep || screenLocked || sessionInactive
        if let asleep { screensAsleep = asleep }
        if let locked { screenLocked = locked }
        if let inactive { sessionInactive = inactive }
        guard wasSuspended != (screensAsleep || screenLocked || sessionInactive) else { return }
        updateMotion()
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
        on(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { renderer in
            renderer.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            renderer.updateMotion()
        }
    }
}
