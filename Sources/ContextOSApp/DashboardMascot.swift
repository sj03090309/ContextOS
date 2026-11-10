import SwiftUI
import AppKit

/// 뭉치 breathes in a taller pose while an agent works.
struct MeltingMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: MascotState
    @ObservedObject var settings: AppSettings
    var surface: DashboardSurface = .popover

    // NSPopover keeps its hosted view alive after dismissal.
    @State private var hidden = false
    @State private var stillCheck = 0
    private static let blinkStarts = [1.2, 5.9, 11.8]

    private var staticMotion: Bool { reduced || settings.mascotMotion == .off }
    private var breathesAtRest: Bool { !staticMotion && settings.mascotMotion.breathes }

    var body: some View {
        let _ = stillCheck // Re-evaluate expiry even with the timeline paused.
        let now = Date()
        let transitioning = state.isWorkTransitioning(at: now) || state.isNodding(at: now)
        let paused = hidden || staticMotion || (!transitioning && !breathesAtRest && !state.isWorking)
        // The slow breath can use fewer redraws than a nod or pose change.
        let frameInterval = 1.0 / (transitioning ? 20 : 10)
        let showsCompletion = !hidden && state.showsOptimizationCompletion(at: now)
        let palette = MungchiPalette(hex: settings.mascotTint, dark: colorScheme == .dark)
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { timeline in
                    frame(at: paused ? now : timeline.date, size: geo.size, palette: palette)
                        .accessibilityHidden(true)
                }
                if showsCompletion {
                    Label("컨텍스트 최적화 완료", systemImage: "checkmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Brand.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: max(0, geo.size.width / 2 - 42), alignment: .trailing)
                        .padding(.trailing, 14)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverOpened)) { notification in
            guard notification.object as? DashboardSurface == surface else { return }
            hidden = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverClosed)) { notification in
            guard notification.object as? DashboardSurface == surface else { return }
            hidden = true
        }
        .task(id: hidden ? nil : state.workChangedAt) {
            guard !hidden, let workTransitionEnd = state.workTransitionEnd else { return }
            await checkStillness(after: workTransitionEnd)
        }
        .task(id: hidden ? nil : state.optimizationCompletedAt) {
            guard !hidden, let completedAt = state.optimizationCompletedAt else { return }
            await checkStillness(after: completedAt.addingTimeInterval(MascotState.nodDuration))
            await checkStillness(after: completedAt.addingTimeInterval(MascotState.completionDuration))
        }
    }

    private func checkStillness(after deadline: Date) async {
        let delay = deadline.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        if !Task.isCancelled { stillCheck += 1 }
    }

    private func frame(at now: Date, size: CGSize, palette: MungchiPalette) -> some View {
        let pose = staticMotion ? (state.isWorking ? CGFloat(1) : 0) : CGFloat(state.workProgress(at: now))
        let nod = staticMotion ? 0 : CGFloat(state.nodProgress(at: now))
        let idleBreath = breathesAtRest
            ? CGFloat(MascotState.breath(at: now, period: MascotState.restBreathPeriod)) * (1 - pose) : 0
        let focusBreath = staticMotion ? 0
            : CGFloat(MascotState.breath(at: now, period: MascotState.focusBreathPeriod)) * pose
        let scaleX = 1.04 - 0.10 * pose - 0.020 * idleBreath - 0.032 * focusBreath + 0.03 * nod
        let scaleY = 0.88 + 0.16 * pose + 0.042 * idleBreath + 0.08 * focusBreath - 0.07 * nod
        let blink = staticMotion ? 0 : Self.blink(now) * (breathesAtRest ? 1 : pose)
        let eyesOpen = 1 - max(0.88 * blink, 0.3 * nod)
        let groundY = size.height - 7
        return ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(palette.ground)
                .frame(width: 42 - 2 * pose - focusBreath + 2 * nod, height: 5)
                .position(x: size.width / 2, y: groundY + 2)
            MungchiFace(palette: palette, gaze: pose + 0.08 * focusBreath - 0.12 * nod, eyesOpen: eyesOpen)
                .frame(width: 36, height: 32)
                .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
                .rotationEffect(.degrees(3 * pose + focusBreath - 4 * nod), anchor: .bottom)
                .position(x: size.width / 2, y: groundY - 16 + 1.5 * nod)
        }
        .frame(width: size.width, height: size.height)
    }

    private static func blink(_ now: Date) -> CGFloat {
        let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 15)
        for start in blinkStarts {
            let elapsed = phase - start
            if (0..<0.24).contains(elapsed) {
                return CGFloat(elapsed < 0.08 ? elapsed / 0.08 : (0.24 - elapsed) / 0.16)
            }
        }
        return 0
    }
}

/// Hosts the popover's two SwiftUI trees side by side: the dashboard, and 뭉치
/// laid over the strip the dashboard leaves for it.
///
/// They are deliberately separate `NSHostingView`s. In one tree, each of the
/// mascot's frames invalidated the shared view graph, and SwiftUI answered by
/// re-running layout and `ViewGraph.updateOutputs` for the entire panel — the
/// profile put ~250 of 550 working samples in `NSHostingView.layout`.
/// Two trees keep mascot ticks from reaching the dashboard's graph.
@MainActor
final class PopoverContentController: NSViewController {

    private let ui: DashboardUIState
    private let mascotHost: NSHostingView<MeltingMascot>
    private let dashboardHost: NSHostingView<AnyView>
    /// Height of the strip the dashboard reserves for 뭉치.
    static let mascotHeight: CGFloat = 50

    init(model: DashboardModel, ui: DashboardUIState, workTime: WorkTimeController = .shared,
         surface: DashboardSurface = .popover) {
        self.ui = ui
        self.mascotHost = NSHostingView(rootView: MeltingMascot(state: model.mascot,
                                                                settings: AppSettings.shared, surface: surface))
        self.dashboardHost = NSHostingView(rootView: AnyView(
            DashboardView(workTime: workTime, surface: surface).environmentObject(model).environmentObject(ui)))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: ui.panelHeight))
        // The container owns the size. An unconstrained hosting-view fitting
        // size can exceed the screen and make NSPopover pick a side edge.
        dashboardHost.sizingOptions = []
        mascotHost.sizingOptions = []
        dashboardHost.translatesAutoresizingMaskIntoConstraints = false
        mascotHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dashboardHost)
        container.addSubview(mascotHost)      // over the strip the dashboard left

        NSLayoutConstraint.activate([
            dashboardHost.topAnchor.constraint(equalTo: container.topAnchor),
            dashboardHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dashboardHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dashboardHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            mascotHost.topAnchor.constraint(equalTo: container.topAnchor),
            mascotHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mascotHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mascotHost.heightAnchor.constraint(equalToConstant: Self.mascotHeight)
        ])
        view = container
    }

    /// Resolve the size before showing; detail expansion scrolls inside it.
    func prepare(for screen: NSScreen?) {
        ui.panelHeight = DashboardLayout.height(visibleHeight: screen?.visibleFrame.height ?? 820)
        preferredContentSize = NSSize(width: DashboardLayout.width, height: ui.panelHeight)
        view.setFrameSize(preferredContentSize)
    }
}
