import SwiftUI
import AppKit
import ServiceManagement
import ContextOSCore

/// The ContextOS brand palette — the ink + cream of the app icon (뭉치 in cream
/// on a charcoal tile), used consistently across the dashboard.
enum Brand {
    static let cream = Color(red: 0.937, green: 0.906, blue: 0.839)      // #EFE7D6
    static let ink = Color(red: 0.090, green: 0.090, blue: 0.106)        // #17171B

    /// An appearance-adaptive color: `dark` in dark mode, `light` in light mode.
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Monochrome accent that reads on both appearances: cream on dark, ink on
    /// light — literally the two icon colors, so contrast is always high.
    static let accent = adaptive(
        dark: NSColor(calibratedRed: 0.937, green: 0.906, blue: 0.839, alpha: 1),   // cream
        light: NSColor(calibratedRed: 0.090, green: 0.090, blue: 0.106, alpha: 1))  // ink

    /// The mascot inverts with the appearance like the accent does — a static
    /// cream blob would vanish on the light popover material. Dark: cream blob
    /// with ink eyes (the icon). Light: ink blob with cream eyes (its negative).
    static let blobTop = adaptive(
        dark: NSColor(calibratedRed: 0.953, green: 0.925, blue: 0.867, alpha: 1),   // #F3ECDD
        light: NSColor(calibratedRed: 0.180, green: 0.180, blue: 0.212, alpha: 1))  // #2E2E36
    static let blobBottom = adaptive(
        dark: NSColor(calibratedRed: 0.894, green: 0.851, blue: 0.765, alpha: 1),   // #E4D9C3
        light: NSColor(calibratedRed: 0.090, green: 0.090, blue: 0.106, alpha: 1))  // #17171B
    static let mascotEye = adaptive(
        dark: NSColor(calibratedWhite: 0.12, alpha: 1),
        light: NSColor(calibratedRed: 0.937, green: 0.906, blue: 0.839, alpha: 1))  // cream
}

/// The menu-bar monitor, styled as a native macOS "clean vibrancy" panel:
/// a translucent surface that adapts to the system light/dark appearance,
/// with one hero number (cumulative savings) up top, a segmented summary,
/// and a compact list of detected AI tools.
struct DashboardView: View {
    @EnvironmentObject var model: DashboardModel

    // Which "screen" the segmented control shows — keeps the panel short by
    // showing one system at a time instead of stacking every section.
    private enum Tab: Hashable { case files, activity, ai }
    @State private var tab: Tab = .files
    @State private var expanded: Set<String> = []   // expanded project cards

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeltingMascot(active: model.flashing, working: model.working)
                .frame(height: 62)
                .padding(.horizontal, -14) // span the full panel width
                .padding(.top, -14)
            header
            hero
            segments
            trend
            Picker("", selection: $tab) {
                Text("프로젝트").tag(Tab.files)
                Text("활동").tag(Tab.activity)
                Text("AI 연결").tag(Tab.ai)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Fixed-height, scrollable tab area. Expanding a project card (or
            // switching tabs) previously changed the SwiftUI content height,
            // which made NSPopover resize the whole window — an abrupt,
            // unanimated jump. With a constant height the window never moves;
            // expansion animates smoothly inside and long lists just scroll.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .files: projects
                    case .activity: activity
                    case .ai: agents
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            footer
        }
        .padding(14)
        .frame(width: 300)
        // Brand accent: picker selection, borderless buttons, folder icons.
        .tint(Brand.accent)
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

    // Tokens saved per day over the last week; today's bar is accented.
    private var trend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("최근 7일 추이")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            let maxSaved = max(1, model.daily.map(\.saved).max() ?? 1)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(model.daily) { d in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            Color.clear.frame(height: 40)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(d.isToday ? Brand.accent : Color.secondary.opacity(0.35))
                                .frame(height: max(3, 40 * CGFloat(d.saved) / CGFloat(maxSaved)))
                        }
                        Text(d.label)
                            .font(.system(size: 9, weight: d.isToday ? .semibold : .regular))
                            .foregroundStyle(d.isToday ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(d.day) · \(TokenEstimator.korean(d.saved)) 아낌")
                }
            }
        }
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

    // One card per project: total tokens + a stacked bar split by AI; expand to
    // see each AI's exact token total.
    private var projects: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.projectUsage.isEmpty {
                Text("아직 AI 사용 기록이 없어요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(model.projectUsage) { p in
                    projectCard(p)
                }
            }
        }
    }

    private func projectCard(_ p: ProjectAIUsage) -> some View {
        let isOpen = expanded.contains(p.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOpen { expanded.remove(p.id) } else { expanded.insert(p.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 13, weight: .semibold))
                        Text(p.path).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Text(TokenEstimator.korean(p.total))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            stackedBar(p)

            if isOpen {
                let maxAgent = max(1, p.byAgent.map(\.tokens).max() ?? 1)
                VStack(spacing: 6) {
                    ForEach(p.byAgent) { a in
                        agentRow(a, fraction: CGFloat(a.tokens) / CGFloat(maxAgent))
                    }
                }
                .padding(.top, 2)

                // Quick actions — only for projects that still exist on disk.
                if FileManager.default.fileExists(atPath: p.path) {
                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: p.path)])
                        } label: {
                            Label("Finder", systemImage: "folder")
                        }
                        Button {
                            Self.openTerminal(at: p.path)
                        } label: {
                            Label("터미널", systemImage: "terminal")
                        }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Open Terminal.app at the given directory.
    private static func openTerminal(at path: String) {
        let url = URL(fileURLWithPath: path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config)
    }

    // Recent optimization events, newest first: what was optimized where, how
    // many tokens it saved, and how long ago.
    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.recent.isEmpty {
                Text("아직 활동 기록이 없어요.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(model.recent, id: \.timestamp) { e in
                    activityRow(e)
                }
            }
        }
    }

    private func activityRow(_ e: UsageEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10)).foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.query.isEmpty ? "컨텍스트 최적화" : e.query)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Text("\((e.project as NSString).lastPathComponent) · 파일 \(e.fileCount)개 · \(Self.timeAgo(e.timestamp))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text("-\(TokenEstimator.korean(e.savedTokens))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.green)
        }
        .padding(.vertical, 2)
    }

    /// Compact Korean relative time, e.g. "3분 전".
    private static func timeAgo(_ ts: Double) -> String {
        let s = Int(Date().timeIntervalSince1970 - ts)
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86_400 { return "\(s / 3600)시간 전" }
        return "\(s / 86_400)일 전"
    }

    // A single horizontal bar split into per-AI segments (widths ∝ tokens).
    private func stackedBar(_ p: ProjectAIUsage) -> some View {
        GeometryReader { geo in
            let total = CGFloat(max(1, p.total))
            HStack(spacing: 1.5) {
                ForEach(p.byAgent) { a in
                    Capsule().fill(Self.agentColor(a.agent))
                        .frame(width: max(3, geo.size.width * CGFloat(a.tokens) / total))
                }
            }
        }
        .frame(height: 6)
    }

    // One AI's row inside an expanded card: dot + name + bar + exact tokens.
    private func agentRow(_ a: AgentTokens, fraction: CGFloat) -> some View {
        let color = Self.agentColor(a.agent)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(Self.agentShort(a.agent)).font(.system(size: 12))
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(color).frame(width: max(3, geo.size.width * min(1, fraction)))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 5)
            Text(TokenEstimator.korean(a.tokens))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private static func agentShort(_ agent: String) -> String {
        agent == "Claude Code" ? "Claude" : agent
    }

    private static func agentColor(_ agent: String) -> Color {
        switch agent {
        // Claude Code — the primary agent — wears the brand accent; the rest
        // keep distinct hues so the per-agent split stays readable.
        case "Claude Code": return Brand.accent
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
                LaunchAtLoginToggle()
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

/// "로그인 시 시작" — registers the app as a login item via SMAppService.
/// Registration only works from a real .app bundle; a `swift run` build fails
/// silently and the toggle snaps back to the actual state.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("로그인 시 시작", isOn: $enabled)
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .onChange(of: enabled) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
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
    /// MCP just optimized — a sharp, energetic burst.
    var active: Bool
    /// A Claude Code session is alive (Claude is thinking/working) — a gentle
    /// but noticeably livelier bob than the resting idle state.
    var working: Bool = false
    @State private var start = Date()

    // Brand gradient (icon colors, appearance-adaptive) filling the metaball.
    private let grad = LinearGradient(
        colors: [Brand.blobTop, Brand.blobBottom],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // Damped-bounce constants. The droplet first touches down at `impactTime`,
    // then jiggles with a decaying wobble.
    private let decay: CGFloat = 2.6
    private let omega: CGFloat = 4.2
    private var impactTime: CGFloat { .pi / (2 * omega) }   // when cos() first hits 0
    private let settleTime: CGFloat = 2.6

    // "File gobble" while optimizing: little file cards fly into 뭉치 and get
    // eaten, one every `fileCycle`, staggered across `fileCount` lanes.
    private let fileCycle: Double = 0.85
    private let fileCount = 3

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSince(start)
                let c = blobCenter(t, geo.size)
                let files = fileStates(t, center: c)
                ZStack {
                    // Files being consumed (drawn behind the blob so they vanish
                    // *into* it), only while actively optimizing.
                    ForEach(files.indices, id: \.self) { i in
                        let f = files[i]
                        fileCard
                            .scaleEffect(f.scale)
                            .opacity(f.opacity)
                            .position(f.pos)
                    }
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
        Circle().fill(Brand.mascotEye).frame(width: 4.5, height: 4.5)
    }

    // A tiny document ("file/context being eaten") — an ink card with cream
    // text lines and a soft glow, so it reads against both the dark panel it
    // flies over and the cream blob it vanishes into.
    private var fileCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.6)
                .fill(Brand.ink)
                .overlay(RoundedRectangle(cornerRadius: 1.6).strokeBorder(Brand.cream.opacity(0.5), lineWidth: 0.5))
            VStack(spacing: 1.4) {
                Capsule().fill(Brand.cream.opacity(0.85)).frame(height: 1)
                Capsule().fill(Brand.cream.opacity(0.85)).frame(height: 1)
            }
            .padding(.horizontal, 1.8)
            .padding(.vertical, 2.2)
        }
        .frame(width: 8, height: 10)
        .shadow(color: Brand.cream.opacity(0.25), radius: 1.5)
    }

    // Per-file position/scale/opacity as it flies in from a side and is absorbed.
    private func fileStates(_ t: TimeInterval, center c: CGPoint)
        -> [(pos: CGPoint, scale: CGFloat, opacity: CGFloat)] {
        guard active, t >= Double(settleTime) else { return [] }
        var out: [(pos: CGPoint, scale: CGFloat, opacity: CGFloat)] = []
        for i in 0..<fileCount {
            let phase = ((t / fileCycle) + Double(i) / Double(fileCount))
                .truncatingRemainder(dividingBy: 1)
            let dir: CGFloat = (i % 2 == 0) ? 1 : -1        // alternate sides
            let startDist: CGFloat = 52
            let x = c.x + dir * startDist * CGFloat(1 - phase)
            let y = c.y - 2 - sin(CGFloat(phase) * .pi) * 4 // gentle arc
            let opacity: CGFloat = phase < 0.12 ? CGFloat(phase / 0.12)
                : (phase > 0.82 ? max(0, CGFloat((1 - phase) / 0.18)) : 1)
            let scale: CGFloat = phase > 0.82 ? max(0.1, CGFloat((1 - phase) / 0.18)) : 1
            out.append((CGPoint(x: x, y: y), scale, opacity))
        }
        return out
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
        if t >= Double(settleTime) {
            // Three tiers: idle breathing, a livelier "working" bob while a
            // Claude session is alive, and a fast energetic bounce on optimize.
            let speed: Double = active ? 6.0 : (working ? 3.6 : 2.0)
            let amp: Double = active ? 2.6 : (working ? 1.9 : 1.4)
            y += sin((t - Double(settleTime)) * speed) * amp
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
        // While gobbling, chomp: widen + flatten in sharp pulses timed to the
        // files being eaten, instead of the plain settling wobble.
        if active, x >= CGFloat(settleTime) {
            let f = 2 * Double.pi * Double(fileCount) / fileCycle
            let chomp = CGFloat(pow((cos(t * f) + 1) / 2, 4))
            return (r * (1 + 0.30 * chomp), r * (1 - 0.26 * chomp))
        }
        let dt = x - impactTime
        let wobble = exp(-3.2 * dt) * sin(2 * .pi * 2.4 * dt)  // decaying jelly
        return (r * (1 + 0.36 * wobble), r * (1 - 0.36 * wobble))
    }
}
