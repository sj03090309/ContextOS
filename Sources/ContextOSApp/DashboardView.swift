import SwiftUI
import ContextOSCore

/// The menu-bar monitor: shows what ContextOS is saving automatically.
struct DashboardView: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            savingsCard
            usageCard
            agentsCard
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Theme.blue)
            Text("ContextOS").font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(model.connected ? Theme.green : Theme.textTertiary).frame(width: 6, height: 6)
                Text(model.connected ? "Claude Code 연결됨" : "연결 안 됨")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // 토큰 얼마나 줄였는지
    private var savingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("아낀 토큰").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 16) {
                stat("오늘", TokenEstimator.abbrev(model.todaySaved), Theme.green)
                stat("누적", TokenEstimator.abbrev(model.totalSaved), Theme.green)
                stat("최적화 횟수", "\(model.queryCount)", Theme.textPrimary)
            }
            if model.totalSaved == 0 {
                Text("Claude Code에서 작업하면 자동으로 쌓입니다.")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    // AI 토큰 사용량
    private var usageCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 토큰 사용량").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text("Claude Code · \(model.aiProjects)개 프로젝트").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Text(TokenEstimator.abbrev(model.aiTokens))
                .font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(Theme.purple)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    // 어떤 AI 도구가 연결/설치되어 있는지
    private var agentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("내 컴퓨터의 AI 도구").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            if model.agents.isEmpty {
                Text("찾은 AI 도구가 없어요.").font(.caption).foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(model.agents) { agent in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.green).frame(width: 6, height: 6)
                        Text(agent.name).font(.system(size: 12))
                        if let d = agent.detail {
                            Text(d).font(.caption2).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        if agent.name == "Claude Code" {
                            Text(model.connected ? "ContextOS 연결됨" : "미연결")
                                .font(.caption2)
                                .foregroundStyle(model.connected ? Theme.green : Theme.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 18, weight: .bold).monospacedDigit()).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text("최적화는 Claude Code에서 자동 실행").font(.caption2).foregroundStyle(Theme.textTertiary)
            Spacer()
            Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.controlSize(.small)
            Button("종료") { NSApplication.shared.terminate(nil) }.controlSize(.small)
        }
    }
}
