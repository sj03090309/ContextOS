import SwiftUI
import Charts
import AppKit
import ContextOSCore

/// A per-project card (mirrors the reference dashboard's provider cards).
struct ProjectCard: View {
    let project: ProjectInfo
    let isActive: Bool
    @EnvironmentObject var model: DashboardModel

    private var tint: Color {
        let palette = [Theme.blue, Theme.orange, Theme.green, Theme.purple, Theme.red]
        return palette[abs(project.path.hashValue) % palette.count]
    }

    private var subtitle: String {
        if project.hasAgentHistory {
            return "로컬 기록 기준 · ContextOS 절약 \(TokenEstimator.humanReadable(project.savedTokens))"
        }
        return project.isIndexed
            ? "쿼리 \(project.queryCount)회 · 파일 \(project.files)개"
            : "미인덱싱 · 선택 후 쿼리하면 인덱싱"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(tint).font(.system(size: 12))
                Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if isActive {
                    Circle().fill(Theme.green).frame(width: 6, height: 6)
                }
                Menu {
                    Button("이 프로젝트 열기") { model.selectProject(project.path) }
                    Button("목록에서 제거", role: .destructive) { model.removeProject(project.path) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.textTertiary).font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 16)
            }

            if project.hasAgentHistory {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(TokenDisplay.koreanCount(project.aiTokens))
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .foregroundStyle(tint)
                    Text("토큰").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                agentBreakdown
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(TokenEstimator.humanReadable(project.savedTokens))
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .foregroundStyle(project.savedTokens > 0 ? Theme.green : Theme.textTertiary)
                    Text("절약").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                sparkline
            }

            Text(subtitle).font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(isActive ? tint.opacity(0.7) : Theme.stroke, lineWidth: isActive ? 1.5 : 1))
        .contentShape(Rectangle())
    }

    private var agentBreakdown: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(project.agentUsages.prefix(4)) { usage in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.agentColor(usage.provider))
                            .frame(width: max(3, geo.size.width * CGFloat(usage.tokens) / CGFloat(max(project.aiTokens, 1))))
                    }
                }
            }
            .frame(height: 5)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(project.agentUsages.prefix(3)) { usage in
                    HStack(spacing: 5) {
                        Circle().fill(Theme.agentColor(usage.provider)).frame(width: 5, height: 5)
                        Text(usage.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(TokenDisplay.koreanCount(usage.tokens))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        if project.daily.contains(where: { $0.saved > 0 }) {
            Chart(project.daily) { p in
                LineMark(x: .value("일", p.day), y: .value("절약", p.saved))
                    .foregroundStyle(tint).interpolationMethod(.catmullRom)
                AreaMark(x: .value("일", p.day), y: .value("절약", p.saved))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.01)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 32)
        } else {
            Rectangle().fill(Theme.stroke).frame(height: 1).frame(maxHeight: 32, alignment: .center)
        }
    }
}

/// The dashed "add a project" tile.
struct AddProjectCard: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        Button(action: model.addProject) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.blue)
                Text("프로젝트 추가").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 120)
            .background(Theme.card.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

/// First-run onboarding: add a project + optional Claude Code connection command.
struct OnboardingCard: View {
    @EnvironmentObject var model: DashboardModel
    @State private var copied = false

    /// One command that auto-discovers, indexes, and detects agents.
    private var setupCommand: String {
        "\(ContextOSPaths.cliBinaryPath()) setup"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ContextOS 시작하기").font(.system(size: 18, weight: .bold))
                Text("로컬 프로젝트를 추가하면 AI 토큰 사용량과 절약량을 볼 수 있습니다. 모두 로컬에서 처리되며 외부로 전송되지 않습니다.")
                    .font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }

            step(1, "터미널에 붙여넣기", "아래 명령어 한 줄이면 로컬 프로젝트를 자동으로 찾아 인덱싱하고, 설치된 AI 에이전트도 감지합니다.") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(setupCommand)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(setupCommand, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }.buttonStyle(.bordered).tint(copied ? Theme.green : .gray)
                    }
                }
            }

            step(2, "또는 직접 추가", "폴더를 하나씩 고르고 싶다면 버튼으로 추가하세요.") {
                Button(action: model.addProject) {
                    Label("프로젝트 추가", systemImage: "folder.badge.plus")
                }.buttonStyle(.borderedProminent).tint(Theme.blue)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
    }

    private func step<Content: View>(_ n: Int, _ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 13, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Theme.blue.opacity(0.2), in: Circle()).foregroundStyle(Theme.blue)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                content().padding(.top, 2)
            }
        }
    }
}

/// Resolves paths to ContextOS's own executables (bundled in the .app, or the
/// dev build) for onboarding instructions.
enum ContextOSPaths {
    static func mcpBinaryPath() -> String { resolve("contextos-mcp") }
    static func cliBinaryPath() -> String { resolve("contextos") }

    private static func resolve(_ name: String) -> String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name).path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        let devBuild = FileManager.default.currentDirectoryPath + "/.build/release/" + name
        if FileManager.default.fileExists(atPath: devBuild) { return devBuild }
        return "/path/to/" + name
    }
}
