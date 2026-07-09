import SwiftUI
import Charts
import ContextOSCore

/// The full ContextOS dashboard window.
struct DashboardWindow: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    heroCard
                    modeBar
                    modeContent
                }
                .padding(16)
            }
            footer
        }
        .frame(width: 400, height: 660)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("ContextOS").font(.system(size: 15, weight: .semibold))
                statusPill("로컬", color: Theme.green)
                Spacer()
                Text(model.timeString).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            HStack(spacing: 6) {
                Text("대시보드").font(.system(size: 13, weight: .medium))
                Text("/").foregroundStyle(Theme.textTertiary)
                Text("\(model.projects.count) 프로젝트").foregroundStyle(Theme.textSecondary).font(.system(size: 13))
                Spacer()
                Button(action: model.refreshAll) {
                    Label("새로고침", systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            Divider().overlay(Theme.stroke)
        }
        .background(Theme.panel)
    }

    // MARK: - Hero

    private var heroCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Theme.blue.opacity(0.9), Theme.purple.opacity(0.8)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                        .overlay(Image(systemName: "square.stack.3d.up.fill").font(.system(size: 22)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 사용 프로젝트 \(model.aiProjects.count)개").font(.system(size: 15, weight: .semibold))
                        Text("로컬 전용 · AI 토큰 사용량 & 절약").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    heroMetric("AI 토큰", TokenEstimator.abbrev(model.totalAITokens), Theme.purple)
                    heroMetric("오늘 절약", TokenEstimator.humanReadable(model.todaySaved), Theme.green)
                    heroMetric("누적 절약", TokenEstimator.humanReadable(model.usage?.totalSaved ?? 0), Theme.green)
                    heroMetric("평균 점수", "\(model.usage?.avgContextScore ?? 0)", Theme.blue)
                }
            }
        }
    }

    private func heroMetric(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tabs

    /// The prominent top-level split: 최적화 (core) vs 인사이트 (extras).
    private var modeBar: some View {
        HStack(spacing: 6) {
            ForEach(DashMode.allCases) { m in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.mode = m }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.icon).font(.system(size: 12))
                        Text(m.rawValue).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(model.mode == m ? .white : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(model.mode == m ? Theme.blue : Theme.card, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke, lineWidth: model.mode == m ? 0 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch model.mode {
        case .optimize: LiveTab().environmentObject(model)
        case .insights: InsightsView().environmentObject(model)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.stroke)
            HStack {
                Circle().fill(Theme.green).frame(width: 7, height: 7)
                Text(model.projectPath.isEmpty ? "로컬 연결됨 · ContextOS" : "로컬 · 자동 갱신 켜짐")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(action: model.refreshAll) { Label("새로고침", systemImage: "arrow.clockwise").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("종료", systemImage: "power").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.red)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.panel)
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

/// A compact labeled stat, used across the tabs.
struct StatTile: View {
    var label: String
    var value: String
    var tint: Color = Theme.textPrimary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
