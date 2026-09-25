import SwiftUI
import AppKit
import ContextOSCore

/// 뭉치, melting into the top of the panel.
///
/// On open it drops in as a droplet and fuses into the band along the panel's
/// top edge, joined by a gooey neck (a Canvas metaball: blur + alpha threshold).
/// Settled, it breathes and blinks. While an agent works it eats: little file
/// cards fly in from both sides on a curve, soften into droplets of the same
/// stuff 뭉치 is made of, and are drawn into it — the metaball fuses each one
/// in with a neck rather than letting it vanish behind the blob — while 뭉치
/// chews with happy, squinting eyes and a warm glow around it.
struct MeltingMascot: View {
    /// Chew state, shared with the menu-bar 뭉치 so both eat the same bite at
    /// the same instant.
    @ObservedObject var state: MascotState
    @ObservedObject var settings: AppSettings
    /// When this view's melt-in began. Only the *entrance* is timed from here —
    /// the chew itself runs off the absolute clock, so re-opening the popover
    /// replays the drop without knocking the two mascots out of step.
    @State private var start = Date()
    /// NSPopover keeps its hosted view alive after dismissal, so this view is
    /// not torn down at once — it just stops being on screen. Nothing tells
    /// SwiftUI that, so the timeline has to be paused by hand or it keeps
    /// redrawing a blurred metaball at a panel nobody is looking at.
    @State private var hidden = false
    /// The melt-in has finished. Past it, a 뭉치 set to hold still has nothing
    /// left to animate and the timeline can stop altogether.
    @State private var settled = false
    /// Bumped once an ease-out has finished, so `isStill` is asked again.
    @State private var stillCheck = 0

    // Brand gradient (icon colors, appearance-adaptive) filling the metaball.
    private let grad = LinearGradient(
        colors: [Brand.blobTop, Brand.blobBottom],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // Damped-bounce constants. The droplet first touches down at `impactTime`,
    // then jiggles with a decaying wobble.
    private let decay: CGFloat = 2.6
    private let omega: CGFloat = 4.2
    private var impactTime: CGFloat { .pi / (2 * omega) }
    private let settleTime: CGFloat = 2.6

    /// Height of the band 뭉치 melts into.
    private static let bandHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            // 20fps rather than the display's rate. Each frame re-renders a
            // Canvas that blurs and alpha-thresholds a metaball, and measured
            // against the panel: 30fps costs ~15% of a core, 20fps ~11%, 15fps
            // ~10% — below 20 the savings stop, because what is left is Core
            // Animation compositing the blurred layer, which no frame rate
            // avoids. The menu bar runs its own rate and stays in step
            // regardless: both read the same absolute clock.
            //
            // `.animation(paused:)` and not `.periodic`: a periodic schedule
            // keeps firing at a dismissed popover, which pinned the app at ~22%
            // of a core forever after the panel was opened once.
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: hidden || isStill)) { timeline in
                frame(at: timeline.date, start: start, size: geo.size)
            }
        }
        .onAppear { start = Date() }
        // Replay the melt-in each time the popover is opened (the hosted view is
        // reused, so onAppear alone won't fire again).
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverOpened)) { _ in
            start = Date()
            settled = false
            hidden = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverClosed)) { _ in
            hidden = true
        }
        .task(id: start) {
            try? await Task.sleep(nanoseconds: UInt64((settleTime + 0.2) * 1_000_000_000))
            if !Task.isCancelled { settled = true }
        }
        .task(id: state.eating) {
            // The chew eases out for about a second after it stops; ask again
            // once it has, so a still 뭉치 can pause its timeline.
            guard !state.eating else { return }
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if !Task.isCancelled { stillCheck += 1 }
        }
        .accessibilityHidden(true)
    }

    /// Nothing left to move: settled, not chewing, and set not to breathe.
    private var isStill: Bool {
        _ = stillCheck
        return settled && !settings.mascotMotion.breathes && !state.isAnimating(at: Date())
    }

    // MARK: - One frame

    private func frame(at now: Date, start: Date, size: CGSize) -> some View {
        let t = now.timeIntervalSince(start)
        let k = chewIntensity(at: now)
        let c = blobCenter(t, at: now, k: k, size)
        let radii = blobRadii(t, at: now, k: k)
        let bites = self.bites(t, at: now, k: k, center: c)
        let melt = meltProgress(t)
        return ZStack {
            // A warm aura while eating, pulsing with each bite.
            if k > 0.02 {
                glow(center: c, k: k, now: now)
            }
            // The cards and the droplets they turn into, behind the blob so
            // they vanish *into* it.
            ForEach(bites.indices, id: \.self) { index in
                card(bites[index])
                droplet(bites[index])
            }
            grad.mask(metaball(size: size, center: c, radii: radii, bites: bites))
            // A soft specular highlight on the upper-left shoulder gives the
            // blob some depth.
            Ellipse()
                .fill(Color.white.opacity(0.2))
                .frame(width: radii.rx * 0.46, height: radii.ry * 0.24)
                .rotationEffect(.degrees(-32))
                .blur(radius: 0.6)
                .position(x: c.x - radii.rx * 0.55, y: c.y - radii.ry * 0.5)
                .opacity(min(1, max(0, (melt - 0.3) / 0.4)))
            eyes(center: c, t: t, k: k, now: now)
                .opacity(min(1, max(0, (melt - 0.6) / 0.4)))
        }
    }

    // MARK: - Motion

    /// How hard 뭉치 is chewing, 0…1 — zero when it is set not to move.
    private func chewIntensity(at now: Date) -> Double {
        settings.mascotMotion.chews ? state.intensity(at: now) : 0
    }

    // 0 → ~1 with a slow, visible damped bounce (two settling hops).
    private func meltProgress(_ t: TimeInterval) -> CGFloat {
        let x = max(0, CGFloat(t))
        if x >= settleTime { return 1 }
        return 1 - exp(-decay * x) * cos(omega * x)
    }

    private func blobCenter(_ t: TimeInterval, at now: Date, k: Double, _ size: CGSize) -> CGPoint {
        let p = meltProgress(t)
        let startY: CGFloat = 3          // starts high, right under the arrow
        let restY = size.height - Self.bandHeight - 12
        var y = startY + (restY - startY) * min(p, 1.18)
        if t >= Double(settleTime) {
            // Blend the calm resting breath into the chewing bob by the same
            // eased intensity the menu bar uses, off the same clock.
            let breath = settings.mascotMotion.breathes ? MascotBeat.breath(now) * 1.4 : 0
            let chew = -MascotBeat.chomp(now) * 2.4
            y += CGFloat(breath * (1 - k) + chew * k)
        }
        return CGPoint(x: size.width / 2, y: y)
    }

    // Bigger droplet that elongates as it falls and jelly-wobbles on impact.
    private func blobRadii(_ t: TimeInterval, at now: Date, k: Double) -> (rx: CGFloat, ry: CGFloat) {
        let r = 11 + 4 * min(meltProgress(t), 1)      // grows 11 → 15
        let x = CGFloat(max(0, t))
        if x < impactTime {
            let f = x / impactTime                    // 0 → 1 during the fall
            return (r * (1 - 0.16 * f), r * (1 + 0.36 * f))   // teardrop stretch
        }
        // Settled: squash-and-stretch on the same chomp the menu bar draws,
        // scaled by the same eased intensity, so both mouths close together.
        if x >= settleTime {
            let chomp = CGFloat(MascotBeat.chomp(now) * k)
            return (r * (1 + 0.26 * chomp), r * (1 - 0.22 * chomp))
        }
        let dt = x - impactTime
        let wobble = exp(-3.2 * dt) * sin(2 * .pi * 2.4 * dt)  // decaying jelly
        return (r * (1 + 0.36 * wobble), r * (1 - 0.36 * wobble))
    }

    // MARK: - Bites

    private struct Bite {
        var position: CGPoint
        var cardScale: CGFloat
        var cardOpacity: CGFloat
        var tilt: Angle
        /// Radius of the droplet the card has softened into.
        var droplet: CGFloat
        /// Its share of the metaball in the last stretch — what draws the neck
        /// that fuses it into 뭉치. Too small to survive the blur on its own,
        /// which is why the droplet itself is drawn separately.
        var neck: CGFloat
    }

    /// One bite per side, timed off the absolute clock, so this bite is the one
    /// the menu bar is chewing right now.
    private func bites(_ t: TimeInterval, at now: Date, k: Double, center c: CGPoint) -> [Bite] {
        guard k > 0.02, t >= Double(settleTime) else { return [] }
        let strength = CGFloat(k)
        return (0..<MascotBeat.lanes).map { lane in
            let p = CGFloat(MascotBeat.foodPhase(now, lane: lane))
            let side: CGFloat = lane == 0 ? -1 : 1
            // Accelerates toward the mouth, as if being drawn in.
            let pull = pow(p, 1.7)
            let reach: CGFloat = 70
            let x = c.x + side * reach * (1 - pull)
            // Floats in level with the brow, then dips into the blob — low
            // enough to stay clear of the popover's top edge.
            let y = c.y - 10 * (1 - pull) - 6 * sin(.pi * pull)
            // The card flies the first stretch, then melts into a droplet that
            // is drawn in, necks into 뭉치, and is swallowed.
            let appear = min(1, p / 0.12)
            let melt = Self.smoothstep(0.4, 0.56, p)
            let swallow = Self.smoothstep(0.82, 1, p)
            return Bite(
                position: CGPoint(x: x, y: y),
                cardScale: (1 - 0.28 * pull) * (1 - 0.45 * melt),
                cardOpacity: appear * (1 - melt) * strength,
                tilt: .degrees(Double(side * 26 * (1 - pull))),
                droplet: 4.3 * melt * (1 - 0.55 * swallow) * strength,
                neck: 7.5 * Self.smoothstep(0.72, 0.9, p) * strength)
        }
    }

    /// A tiny page of code, in 뭉치's own colors, so it reads as the same stuff
    /// it turns into.
    private func card(_ bite: Bite) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Brand.blobTop)
            VStack(alignment: .leading, spacing: 1.6) {
                Capsule().fill(Brand.mascotEye.opacity(0.75)).frame(width: 5, height: 1.1)
                Capsule().fill(Brand.mascotEye.opacity(0.55)).frame(width: 3.6, height: 1.1)
                Capsule().fill(Brand.mascotEye.opacity(0.55)).frame(width: 4.6, height: 1.1)
            }
            .padding(.top, 2.4)
            .padding(.leading, 1.9)
        }
        .frame(width: 9, height: 11)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .scaleEffect(bite.cardScale)
        .rotationEffect(bite.tilt)
        .opacity(bite.cardOpacity)
        .position(bite.position)
    }

    /// The softened card: a drop of 뭉치's own color, stretched along its flight.
    @ViewBuilder
    private func droplet(_ bite: Bite) -> some View {
        if bite.droplet > 0.3 {
            Ellipse()
                .fill(Brand.blobTop)
                .frame(width: bite.droplet * 2.35, height: bite.droplet * 2)
                .position(bite.position)
        }
    }

    private func glow(center c: CGPoint, k: Double, now: Date) -> some View {
        let pulse = 1 + 0.08 * CGFloat(MascotBeat.chomp(now) * k)
        return Ellipse()
            .fill(RadialGradient(colors: [Brand.mascotGlow.opacity(0.22 * k), Brand.mascotGlow.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: 40))
            .frame(width: 88 * pulse, height: 58 * pulse)
            .position(c)
    }

    // MARK: - Eyes

    /// Round eyes that blink now and then; while eating they squint into
    /// happy arcs.
    private func eyes(center c: CGPoint, t: TimeInterval, k: Double, now: Date) -> some View {
        let happy = Self.smoothstep(0.35, 0.8, CGFloat(k))
        let blink = settings.mascotMotion.breathes ? Self.blink(now) : 0
        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                let point = CGPoint(x: c.x + CGFloat(side) * 5.2, y: c.y - 1.5)
                Circle()
                    .fill(Brand.mascotEye)
                    .frame(width: 4.5, height: 4.5)
                    .scaleEffect(x: 1, y: 1 - 0.88 * blink)
                    .opacity(1 - happy)
                    .position(point)
                HappyEye()
                    .stroke(Brand.mascotEye, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 5.2, height: 2.6)
                    .opacity(happy)
                    .position(x: point.x, y: point.y - 0.4)
            }
        }
    }

    /// A quick blink every few seconds, 0 (open) → 1 (shut) → 0.
    static func blink(_ now: Date) -> CGFloat {
        let period = 4.6
        let length = 0.16
        let into = now.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        guard into < length else { return 0 }
        return CGFloat(sin(into / length * .pi))
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Metaball

    private func metaball(size: CGSize, center c: CGPoint, radii: (rx: CGFloat, ry: CGFloat),
                          bites: [Bite]) -> some View {
        Canvas { ctx, canvas in
            ctx.addFilter(.alphaThreshold(min: 0.5))
            // A larger blur stretches the gooey neck over a longer gap, so the
            // "soaking in" reads clearly.
            ctx.addFilter(.blur(radius: 9))
            ctx.drawLayer { layer in
                // The surface the droplet soaks into, fused to the panel top.
                let band = CGRect(x: 0, y: canvas.height - Self.bandHeight,
                                  width: canvas.width, height: Self.bandHeight + 14)
                layer.fill(Path(roundedRect: band, cornerRadius: 12), with: .color(.white))
                // The body — an ellipse so it can stretch while falling and
                // squash-wobble on impact.
                layer.fill(Path(ellipseIn: CGRect(x: c.x - radii.rx, y: c.y - radii.ry,
                                                  width: radii.rx * 2, height: radii.ry * 2)),
                           with: .color(.white))
                // A droplet close enough to 뭉치 fuses in with a gooey neck.
                for bite in bites where bite.neck > 0.5 {
                    layer.fill(Path(ellipseIn: CGRect(x: bite.position.x - bite.neck,
                                                      y: bite.position.y - bite.neck,
                                                      width: bite.neck * 2, height: bite.neck * 2)),
                               with: .color(.white))
                }
            }
        }
    }
}

/// An upturned arc — a closed, smiling eye.
private struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.9))
        return path
    }
}

/// Hosts the popover's two SwiftUI trees side by side: the dashboard, and 뭉치
/// laid over the strip the dashboard leaves for it.
///
/// They are deliberately separate `NSHostingView`s. In one tree, each of the
/// mascot's frames invalidated the shared view graph, and SwiftUI answered by
/// re-running layout and `ViewGraph.updateOutputs` for the entire panel — the
/// profile put ~250 of 550 working samples in `NSHostingView.layout` while the
/// Canvas blur everyone would suspect was 30. Two trees means the mascot's
/// ticks cannot reach the dashboard's graph at all.
@MainActor
final class PopoverContentController: NSViewController {

    private let model: DashboardModel
    private let mascotHost: NSHostingView<MeltingMascot>
    private let dashboardHost: NSHostingView<AnyView>
    /// Height of the strip 뭉치 melts into, matching the space the dashboard
    /// reserves for it.
    static let mascotHeight: CGFloat = 50

    init(model: DashboardModel, ui: DashboardUIState) {
        self.model = model
        self.mascotHost = NSHostingView(rootView: MeltingMascot(state: model.mascot,
                                                                settings: AppSettings.shared))
        self.dashboardHost = NSHostingView(
            rootView: AnyView(DashboardView().environmentObject(model).environmentObject(ui)))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()
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

    /// The size the popover should be, driven by the dashboard alone — 뭉치 sits
    /// inside the space the dashboard already reserves.
    override func viewDidLayout() {
        super.viewDidLayout()
        let fitting = dashboardHost.fittingSize
        if fitting.width > 0, preferredContentSize != fitting {
            preferredContentSize = fitting
        }
    }
}
