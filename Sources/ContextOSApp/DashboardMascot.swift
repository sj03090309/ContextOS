import SwiftUI
import AppKit
import Combine

/// 뭉치 breathes in a taller pose while an agent works.
struct MeltingMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: MascotState
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: DashboardUIState
    var surface: DashboardSurface = .popover

    // NSPopover keeps its hosted view alive after dismissal.
    @State private var hidden = false
    @State private var attentive = false

    private var staticMotion: Bool { reduced || settings.mascotMotion == .off }
    private var breathesAtRest: Bool { !staticMotion && settings.mascotMotion.breathes }
    private var inactive: Bool { hidden || ui.showSettings || ui.showConnections }

    private var schedule: MascotTimelineSchedule {
        let nodEnd = state.optimizationCompletedAt?.addingTimeInterval(MascotState.nodDuration)
        let gestureEnd = max(state.workTransitionEnd ?? .distantPast, nodEnd ?? .distantPast)
        let breathPeriod: TimeInterval? = state.isWorking ? MascotState.focusBreathPeriod
            : (breathesAtRest ? MascotState.restBreathPeriod : nil)
        return MascotTimelineSchedule(gestureEnd: gestureEnd, breathPeriod: breathPeriod)
    }

    var body: some View {
        let palette = MungchiPalette(hex: settings.mascotTint, dark: colorScheme == .dark)
        GeometryReader { geo in
            if hidden {
                Color.clear
            } else if inactive || staticMotion {
                frame(at: Date(), size: geo.size, palette: palette)
            } else {
                TimelineView(schedule) { timeline in
                    frame(at: timeline.date, size: geo.size, palette: palette)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            guard !inactive, !staticMotion else { return }
            withAnimation(.easeInOut(duration: 0.22)) { attentive = inside }
        }
        .accessibilityHidden(true)
        .onChange(of: inactive || staticMotion) { _, disabled in
            if disabled { attentive = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverOpened)) { notification in
            guard notification.object as? DashboardSurface == surface else { return }
            hidden = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverClosed)) { notification in
            guard notification.object as? DashboardSurface == surface else { return }
            hidden = true
        }
    }

    private func frame(at now: Date, size: CGSize, palette: MungchiPalette) -> some View {
        let pose = staticMotion ? (state.isWorking ? CGFloat(1) : 0) : CGFloat(state.workProgress(at: now))
        let nod = staticMotion ? 0 : CGFloat(state.nodProgress(at: now))
        let glance: CGFloat = attentive && !inactive && !staticMotion ? 1 : 0
        let idleBreath = breathesAtRest
            ? CGFloat(MascotState.breath(at: now, period: MascotState.restBreathPeriod)) * (1 - pose) : 0
        let focusBreath = staticMotion ? 0
            : CGFloat(MascotState.breath(at: now, period: MascotState.focusBreathPeriod)) * pose
        let scaleX = 1.04 - 0.10 * pose - 0.020 * idleBreath - 0.032 * focusBreath + 0.03 * nod
        let scaleY = 0.88 + 0.16 * pose + 0.042 * idleBreath + 0.08 * focusBreath - 0.07 * nod + 0.025 * glance
        let blink = staticMotion ? 0 : CGFloat(MascotTimelineSchedule.blinkProgress(at: now)) * (breathesAtRest ? 1 : pose)
        let eyesOpen = 1 - max(0.88 * blink, 0.3 * nod)
        let groundY = size.height - 7
        return ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(palette.ground)
                .frame(width: 42 - 2 * pose - focusBreath + 2 * nod, height: 5)
                .position(x: size.width / 2, y: groundY + 2)
            MungchiFace(palette: palette, gaze: pose + 0.08 * focusBreath - 0.12 * nod + 0.32 * glance,
                        eyesOpen: eyesOpen)
                .frame(width: 36, height: 32)
                .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
                .rotationEffect(.degrees(3 * pose + focusBreath - 4 * nod + 2 * glance), anchor: .bottom)
                .position(x: size.width / 2, y: groundY - 16 + 1.5 * nod)
        }
        .frame(width: size.width, height: size.height)
    }

}

/// Hosts the popover's two SwiftUI trees side by side: the dashboard, and 뭉치
/// placed in the leading slot of the dashboard's activity header.
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
    private var overlayVisibility: AnyCancellable?

    init(model: DashboardModel, ui: DashboardUIState, workTime: WorkTimeController = .shared,
         surface: DashboardSurface = .popover) {
        self.ui = ui
        self.mascotHost = NSHostingView(rootView: MeltingMascot(state: model.mascot,
                                                                settings: AppSettings.shared, ui: ui, surface: surface))
        self.dashboardHost = NSHostingView(rootView: AnyView(
            DashboardView(workTime: workTime, surface: surface).environmentObject(model).environmentObject(ui)))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: DashboardLayout.width, height: ui.panelHeight))
        // The container owns the size. An unconstrained hosting-view fitting
        // size can exceed the screen and make NSPopover pick a side edge.
        dashboardHost.sizingOptions = []
        mascotHost.sizingOptions = []
        dashboardHost.translatesAutoresizingMaskIntoConstraints = false
        mascotHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dashboardHost)
        container.addSubview(mascotHost)
        overlayVisibility = ui.$showSettings.combineLatest(ui.$showConnections)
            .map { settings, connections in settings || connections }
            .removeDuplicates()
            .sink { [weak mascotHost = self.mascotHost] obscured in mascotHost?.isHidden = obscured }

        NSLayoutConstraint.activate([
            dashboardHost.topAnchor.constraint(equalTo: container.topAnchor),
            dashboardHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dashboardHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dashboardHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            mascotHost.topAnchor.constraint(equalTo: container.topAnchor, constant: DashboardLayout.mascotTop),
            mascotHost.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DashboardLayout.mascotLeading),
            mascotHost.widthAnchor.constraint(equalToConstant: DashboardLayout.mascotWidth),
            mascotHost.heightAnchor.constraint(equalToConstant: DashboardLayout.mascotHeight)
        ])
        view = container
    }

    /// Resolve the size before showing; detail pages scroll inside it.
    func prepare(for screen: NSScreen?) {
        ui.panelHeight = DashboardLayout.height(visibleHeight: screen?.visibleFrame.height ?? 820)
        preferredContentSize = NSSize(width: DashboardLayout.width, height: ui.panelHeight)
        view.setFrameSize(preferredContentSize)
    }
}
