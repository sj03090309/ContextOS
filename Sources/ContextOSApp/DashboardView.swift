import SwiftUI
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
                .frame(height: 46)
                .padding(.horizontal, -14) // span the full panel width
                .padding(.top, -14)
            header
            hero
            segments
            agents
            footer
        }
        .padding(14)
        .frame(width: 300)
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

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSince(start)
                let c = blobCenter(t, geo.size)
                ZStack {
                    grad.mask(metaball(t))
                    // Eyes track the blob and fade in as it settles.
                    let eyeOpacity = min(1, max(0, (meltProgress(t) - 0.55) / 0.45))
                    Group {
                        eye.position(x: c.x - 4.3, y: c.y - 1)
                        eye.position(x: c.x + 4.3, y: c.y - 1)
                    }
                    .opacity(eyeOpacity)
                }
            }
        }
        .onAppear { start = Date() }
    }

    private var eye: some View {
        Circle().fill(Color(white: 0.12)).frame(width: 4, height: 4)
    }

    private func metaball(_ t: TimeInterval) -> some View {
        Canvas { ctx, size in
            ctx.addFilter(.alphaThreshold(min: 0.5))
            ctx.addFilter(.blur(radius: 7))
            ctx.drawLayer { layer in
                // Base strip fused to the panel's top edge.
                let baseH: CGFloat = 20
                let base = CGRect(x: 0, y: size.height - baseH, width: size.width, height: baseH + 12)
                layer.fill(Path(roundedRect: base, cornerRadius: 12), with: .color(.white))
                // The droplet body.
                let c = blobCenter(t, size)
                let r = blobRadius(t)
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(.white))
            }
        }
    }

    // 0 → ~1 with a small damped overshoot, so the droplet squishes as it lands.
    private func meltProgress(_ t: TimeInterval) -> CGFloat {
        let x = max(0, CGFloat(t))
        if x >= 1.4 { return 1 }
        return 1 - exp(-5 * x) * cos(7 * x)
    }

    private func blobCenter(_ t: TimeInterval, _ size: CGSize) -> CGPoint {
        let p = meltProgress(t)
        let startY: CGFloat = 9
        let restY = size.height - 20
        var y = startY + (restY - startY) * min(p, 1.15)
        if t > 1.4 { // gentle idle bob (faster while active)
            y += sin((t - 1.4) * (active ? 6.0 : 2.0)) * (active ? 2.2 : 1.2)
        }
        return CGPoint(x: size.width / 2, y: y)
    }

    private func blobRadius(_ t: TimeInterval) -> CGFloat {
        9 + 3 * min(meltProgress(t), 1)
    }
}
