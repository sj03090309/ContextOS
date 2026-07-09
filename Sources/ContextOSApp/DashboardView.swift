import SwiftUI
import ContextOSCore

/// The menu-bar monitor, styled as a native macOS "clean vibrancy" panel:
/// a translucent surface that adapts to the system light/dark appearance,
/// with one hero number (cumulative savings) up top, a segmented summary,
/// and a compact list of detected AI tools.
struct DashboardView: View {
    @EnvironmentObject var model: DashboardModel
    // Drives a soft fade-and-scale as the popover opens.
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            hero
            segments
            agents
            footer
        }
        .padding(14)
        .frame(width: 300)
        // Translucent menu-bar material; follows the system appearance.
        .background(.regularMaterial)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.96, anchor: .top)
        .onAppear {
            shown = false
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { shown = true }
        }
        .onDisappear { shown = false }
    }

    // ContextOS + live connection state.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: model.flashing)
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
