import SwiftUI
import AppKit
import ContextOSCore

/// The menu-bar monitor, styled as a native macOS "clean vibrancy" panel:
/// a translucent surface that adapts to the system light/dark appearance,
/// with one hero number (cumulative savings) up top, a segmented summary,
/// and a compact list of detected AI tools.
struct DashboardView: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeltingMascot(active: model.flashing)
                .frame(height: 62)
                .padding(.horizontal, -14) // span the full panel width
                .padding(.top, -14)
            header
            hero
            segments
            files
            agents
            footer
        }
        .padding(14)
        .frame(width: 300)
        // Pin the background to a single, constant vibrancy so its color doesn't
        // deepen when the popover becomes key (e.g. after a click).
        .background(VisualEffectBackground())
    }

    // ContextOS + live connection state.
    private var header: some View {
        HStack(spacing: 6) {
            Text("ContextOS").font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(model.connected ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(model.connected ? "연결됨" : "연결 안 됨")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // The one number that matters at a glance: cumulative tokens saved.
    private var hero: some View {
        VStack(spacing: 2) {
            Text(TokenEstimator.korean(model.totalSaved))
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.default, value: model.totalSaved)
            Text("누적 아낀 토큰")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // A macOS-style segmented summary strip.
    private var segments: some View {
        HStack(spacing: 0) {
            segment("오늘", TokenEstimator.korean(model.todaySaved))
            Divider().frame(height: 26)
            segment("최적화", "\(model.queryCount)")
            Divider().frame(height: 26)
            segment("AI 사용", TokenEstimator.korean(model.aiTokens))
        }
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }

    private func segment(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // Per-file token usage: how many tokens each file cost by being loaded into
    // context, and which AI loaded it.
    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("파일별 토큰 사용량")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if model.fileUsage.isEmpty {
                Text("아직 파일 사용 기록이 없어요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                let maxTokens = max(1, model.fileUsage.map(\.tokens).max() ?? 1)
                ForEach(model.fileUsage) { f in
                    fileRow(f, fraction: CGFloat(f.tokens) / CGFloat(maxTokens))
                }
            }
        }
    }

    private func fileRow(_ f: FileTokenUsage, fraction: CGFloat) -> some View {
        let color = Self.agentColor(f.agent)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(f.shortLabel)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(f.agent).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(TokenEstimator.korean(f.tokens))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
    }

    private static func agentColor(_ agent: String) -> Color {
        switch agent {
        case "Claude Code": return .orange
        case "Codex":       return .blue
        case "Copilot":     return .green
        case "Gemini":      return .purple
        default:            return .secondary
        }
    }

    // Detected AI tools, one compact row each.
    private var agents: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.agents.isEmpty {
                Text("찾은 AI 도구가 없어요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(model.agents) { agent in
                    HStack(spacing: 8) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(agent.name).font(.system(size: 12))
                        if let d = agent.detail {
                            Text(d).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if agent.name == "Claude Code" {
                            Text(model.connected ? "연결됨" : "미연결")
                                .font(.system(size: 11))
                                .foregroundStyle(model.connected ? Color.green : Color.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Text("자동 최적화 실행 중")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("새로고침")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("종료")
            }
        }
    }
}

/// A translucent panel background pinned to the `.active` state, so its color
/// stays constant instead of deepening when the popover window gains/loses key
/// focus (which is what made a click "darken" the dashboard).
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}

/// The 뭉치 mascot melting into the top of the panel. On open it drops in as a
/// droplet and fuses into a base strip along the panel's top edge, connected by
/// a gooey neck (a Canvas metaball: blur + alpha-threshold). After settling it
/// bobs gently; while ContextOS is optimizing it bobs faster.
struct MeltingMascot: View {
    var active: Bool
    @State private var start = Date()

    // Brand gradient (blue → purple) the metaball silhouette is filled with.
    private let grad = LinearGradient(
        colors: [Color(red: 0.29, green: 0.56, blue: 0.98),
                 Color(red: 0.64, green: 0.52, blue: 0.96)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // Damped-bounce constants. The droplet first touches down at `impactTime`,
    // then jiggles with a decaying wobble.
    private let decay: CGFloat = 2.6
    private let omega: CGFloat = 4.2
    private var impactTime: CGFloat { .pi / (2 * omega) }   // when cos() first hits 0
    private let settleTime: CGFloat = 2.6

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSince(start)
                let c = blobCenter(t, geo.size)
                ZStack {
                    grad.mask(metaball(t))
                    // Eyes track the blob and fade in as it settles.
                    let eyeOpacity = min(1, max(0, (meltProgress(t) - 0.6) / 0.4))
                    Group {
                        eye.position(x: c.x - 5.2, y: c.y - 1.5)
                        eye.position(x: c.x + 5.2, y: c.y - 1.5)
                    }
                    .opacity(eyeOpacity)
                }
            }
        }
        .onAppear { start = Date() }
        // Replay the melt-in each time the popover is opened (the hosted view is
        // reused, so onAppear alone won't fire again).
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverOpened)) { _ in
            start = Date()
        }
    }

    private var eye: some View {
        Circle().fill(Color(white: 0.12)).frame(width: 4.5, height: 4.5)
    }

    private func metaball(_ t: TimeInterval) -> some View {
        Canvas { ctx, size in
            ctx.addFilter(.alphaThreshold(min: 0.5))
            // A larger blur stretches the gooey neck over a longer gap, so the
            // "soaking in" reads clearly.
            ctx.addFilter(.blur(radius: 10))
            ctx.drawLayer { layer in
                // The surface the droplet soaks into, fused to the panel top.
                let baseH: CGFloat = 22
                let base = CGRect(x: 0, y: size.height - baseH, width: size.width, height: baseH + 14)
                layer.fill(Path(roundedRect: base, cornerRadius: 13), with: .color(.white))
                // The droplet body — an ellipse so it can stretch while falling
                // and squash-wobble on impact.
                let c = blobCenter(t, size)
                let (rx, ry) = blobRadii(t)
                layer.fill(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2)),
                           with: .color(.white))
            }
        }
    }

    // 0 → ~1 with a slow, visible damped bounce (two settling hops).
    private func meltProgress(_ t: TimeInterval) -> CGFloat {
        let x = max(0, CGFloat(t))
        if x >= settleTime { return 1 }
        return 1 - exp(-decay * x) * cos(omega * x)
    }

    private func blobCenter(_ t: TimeInterval, _ size: CGSize) -> CGPoint {
        let p = meltProgress(t)
        let startY: CGFloat = 3          // starts high, right under the arrow
        let restY = size.height - 26
        var y = startY + (restY - startY) * min(p, 1.18)
        if t >= Double(settleTime) {     // gentle idle bob (livelier while active)
            y += sin((t - Double(settleTime)) * (active ? 6.0 : 2.0)) * (active ? 2.6 : 1.4)
        }
        return CGPoint(x: size.width / 2, y: y)
    }

    // Bigger droplet that elongates as it falls and jelly-wobbles on impact.
    private func blobRadii(_ t: TimeInterval) -> (CGFloat, CGFloat) {
        let r = 11 + 4 * min(meltProgress(t), 1)      // grows 11 → 15
        let x = CGFloat(max(0, t))
        if x < impactTime {
            let f = x / impactTime                    // 0 → 1 during the fall
            return (r * (1 - 0.16 * f), r * (1 + 0.36 * f))   // teardrop stretch
        }
        let dt = x - impactTime
        let wobble = exp(-3.2 * dt) * sin(2 * .pi * 2.4 * dt)  // decaying jelly
        return (r * (1 + 0.36 * wobble), r * (1 - 0.36 * wobble))
    }
}
