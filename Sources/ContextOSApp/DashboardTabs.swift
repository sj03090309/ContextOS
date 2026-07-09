import SwiftUI
import Charts
import ContextOSCore

// MARK: - Live tab (run a query, see the optimized context)

struct LiveTab: View {
    @EnvironmentObject var model: DashboardModel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 14) {
            if !model.hasProjects {
                OnboardingCard()
            } else {
                HStack {
                    Text(model.showOnlyAIProjects ? "AI 사용 이력 프로젝트" : "전체 프로젝트")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Toggle("AI 사용만", isOn: $model.showOnlyAIProjects)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }

                if model.visibleProjects.isEmpty {
                    Card { Text("AI 에이전트 사용 이력이 있는 프로젝트가 없습니다. 토글을 끄면 전체 프로젝트를 볼 수 있습니다.")
                        .font(.callout).foregroundStyle(Theme.textSecondary).padding(.vertical, 8) }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.visibleProjects) { project in
                            ProjectCard(project: project, isActive: project.path == model.projectPath)
                                .onTapGesture { model.selectProject(project.path) }
                        }
                        AddProjectCard()
                    }
                }
                if !model.proactiveFiles.isEmpty {
                    proactiveCard
                }
                if !model.projectPath.isEmpty {
                    querySection
                }
            }
        }
    }

    // "You're editing these files — context is ready" (no query needed).
    private var proactiveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.orange).font(.caption)
                    Text("지금 작업 중이신가요?").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(model.proactiveFiles.count)개 파일").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                Text("편집 중인 파일 기준으로 관련 컨텍스트를 미리 준비해뒀어요. 아무것도 입력 안 해도 됩니다.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text(model.proactiveFiles.prefix(4).joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(2)
                Button(action: model.copyProactive) {
                    Label(model.proactiveCopied ? "복사됐어요! AI에 붙여넣으세요" : "지금 컨텍스트 복사",
                          systemImage: model.proactiveCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                        .fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(model.proactiveCopied ? Theme.green : Theme.orange)
            }
        }
    }

    private var querySection: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(Theme.blue).font(.caption)
                Text(model.projectName).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.top, 4)

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("무엇을 작업하나요? 예: 로그인 기능", text: $model.query)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                            .onSubmit(model.runQuery)
                        Button(action: model.runQuery) {
                            if model.isWorking { ProgressView().controlSize(.small) }
                            else { Text("최적화").fontWeight(.semibold) }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.blue)
                        .disabled(model.query.isEmpty || model.isWorking)
                    }
                    HStack(spacing: 6) {
                        Text("분량").font(.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(BudgetPreset.allCases) { p in
                            Button { model.budgetPreset = p } label: {
                                Text(p.rawValue)
                                    .font(.system(size: 11, weight: model.budgetPreset == p ? .semibold : .regular))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(model.budgetPreset == p ? Theme.blue : Theme.background, in: Capsule())
                                    .foregroundStyle(model.budgetPreset == p ? .white : Theme.textSecondary)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
            }

            if !model.suggestions.isEmpty { suggestionChips }
            if !model.lint.isEmpty {
                noticeCard(model.lint.map { ($0.severity == .warning, $0.message, $0.suggestion) }, tint: Theme.orange)
            }

            if let sel = model.selection {
                if let r = sel.refinement, r.changed { refinementNote(r) }
                resultCard(sel)
                detailDisclosure(sel)
                if !model.advisories.isEmpty {
                    noticeCard(model.advisories.map { ($0.severity == .warning, $0.message, nil) }, tint: Theme.blue)
                }
            } else {
                emptyGuide
            }

            if let error = model.errorMessage {
                Card { Text(error).font(.caption).foregroundStyle(Theme.red) }
            }
        }
    }

    // The actionable outcome: plain summary + one-tap copy for any AI chat.
    private func resultCard(_ sel: ContextSelection) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green)
                    Text(plainSummary(sel)).font(.callout).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: model.copyBundle) {
                    Label(model.copied ? "복사됐어요! AI에 붙여넣으세요" : "AI에게 복사하기",
                          systemImage: model.copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                        .fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(model.copied ? Theme.green : Theme.blue).controlSize(.large)
                Text("복사한 뒤 ChatGPT·Claude 같은 AI 채팅에 그대로 붙여넣으면 됩니다.")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // Shows how the raw query was actively refined (dictionary/typo/index).
    private func refinementNote(_ r: RefinedQuery) -> some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.purple).font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text("이렇게 이해했어요").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(r.explanation).font(.caption).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func plainSummary(_ sel: ContextSelection) -> String {
        if let s = model.savings, s.saved > 0 {
            return "관련 파일 \(sel.included.count)개만 골랐어요 — 프로젝트 전체를 다 넣는 것보다 \(s.percent)% 적은 분량이에요."
        }
        return "관련 파일 \(sel.included.count)개를 골랐어요."
    }

    // Secondary, collapsed-by-default technical detail.
    private func detailDisclosure(_ sel: ContextSelection) -> some View {
        Card {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        StatTile(label: "점수", value: "\(sel.contextScore)", tint: Theme.scoreColor(sel.contextScore))
                        StatTile(label: "분량", value: TokenEstimator.humanReadable(sel.estimatedTokens), tint: Theme.blue)
                        StatTile(label: "파일", value: "\(sel.included.count)")
                    }
                    ForEach(sel.included, id: \.path) { f in
                        HStack {
                            Circle().fill(Theme.blue).frame(width: 5, height: 5)
                            Text(f.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(TokenEstimator.humanReadable(f.estimatedTokens))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("자세히 보기 (점수·파일 목록)").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // Beginner guidance when there's no result yet.
    private var emptyGuide: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("이렇게 쓰세요").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                guideRow(1, "무엇을 작업할지 입력", "예: 로그인, 결제, 회원가입")
                guideRow(2, "‘최적화’ 누르기", "필요한 코드만 골라줍니다")
                guideRow(3, "‘AI에게 복사’", "ChatGPT·Claude에 붙여넣기")

                if !model.exampleQueries.isEmpty {
                    Divider().overlay(Theme.stroke)
                    Text("이 프로젝트에서 자주 나오는 것 — 눌러보세요").font(.caption2).foregroundStyle(Theme.textTertiary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.exampleQueries, id: \.self) { q in
                                Button { model.runExample(q) } label: {
                                    Text(q).font(.system(size: 11, design: .monospaced))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Theme.blue.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Theme.blue)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func guideRow(_ n: Int, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Theme.blue.opacity(0.2), in: Circle()).foregroundStyle(Theme.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(sub).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }

    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Theme.purple)
                Text("자동완성 — 실제 심볼을 넣으면 점수가 올라갑니다").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.suggestions, id: \.self) { name in
                        Button { model.applySuggestion(name) } label: {
                            Text(name)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.purple.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.purple)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func noticeCard(_ items: [(Bool, String, String?)], tint: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: item.0 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(item.0 ? Theme.orange : tint).font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.1).font(.caption)
                            if let sug = item.2 { Text(sug).font(.caption2).foregroundStyle(Theme.textSecondary) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Usage tab (analytics + trend chart + per-project)

struct UsageTab: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Card { StatTile(label: "쿼리 수", value: "\(model.usage?.queryCount ?? 0)") }
                Card { StatTile(label: "누적 절약", value: TokenEstimator.humanReadable(model.usage?.totalSaved ?? 0), tint: Theme.green) }
                Card { StatTile(label: "평균 컨텍스트", value: TokenEstimator.humanReadable(model.usage?.avgSelectedTokens ?? 0), tint: Theme.blue) }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("최근 7일 절약 추세").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    if model.daily.allSatisfy({ $0.saved == 0 }) {
                        Text("아직 데이터가 없습니다. 라이브 탭에서 쿼리를 실행해 보세요.")
                            .font(.caption).foregroundStyle(Theme.textTertiary).padding(.vertical, 20)
                    } else {
                        Chart(model.daily) { p in
                            AreaMark(x: .value("일", p.day), y: .value("절약", p.saved))
                                .foregroundStyle(LinearGradient(colors: [Theme.green.opacity(0.4), Theme.green.opacity(0.02)],
                                                                startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("일", p.day), y: .value("절약", p.saved))
                                .foregroundStyle(Theme.green).interpolationMethod(.catmullRom)
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(height: 90)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("프로젝트별 절약").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    if model.usage?.perProject.isEmpty ?? true {
                        Text("기록 없음").font(.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(Array((model.usage?.perProject ?? []).enumerated()), id: \.offset) { _, p in
                            HStack {
                                Text(URL(fileURLWithPath: p.project).lastPathComponent).font(.system(size: 12))
                                Spacer()
                                Text("\(p.count)회").font(.caption2).foregroundStyle(Theme.textTertiary)
                                Text(TokenEstimator.humanReadable(p.saved))
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.green)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Project tab (index stats + language breakdown)

struct ProjectTab: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Card { StatTile(label: "파일", value: "\(model.summary?.files ?? 0)") }
                Card { StatTile(label: "심볼", value: "\(model.summary?.symbols ?? 0)", tint: Theme.purple) }
                Card { StatTile(label: "Import", value: "\(model.summary?.imports ?? 0)", tint: Theme.blue) }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("언어 분포").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    let langs = (model.summary?.byLanguage ?? [:]).sorted { $0.value > $1.value }
                    let maxCount = langs.map(\.value).max() ?? 1
                    if langs.isEmpty {
                        Text("인덱스 없음").font(.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(langs, id: \.key) { lang, count in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(lang.displayName).font(.system(size: 12))
                                    Spacer()
                                    Text("\(count)").font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary)
                                }
                                GeometryReader { geo in
                                    Capsule().fill(Theme.blue.opacity(0.7))
                                        .frame(width: geo.size.width * CGFloat(count) / CGFloat(maxCount), height: 5)
                                }.frame(height: 5)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Insights container (ancillary features, one step in)

struct InsightsView: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(InsightTab.allCases) { t in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { model.insightTab = t }
                    } label: {
                        Text(t.rawValue)
                            .font(.system(size: 12, weight: model.insightTab == t ? .semibold : .regular))
                            .foregroundStyle(model.insightTab == t ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(model.insightTab == t ? Theme.cardHover : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            switch model.insightTab {
            case .usage: UsageTab().environmentObject(model)
            case .agents: AgentsTab().environmentObject(model)
            case .project: ProjectTab().environmentObject(model)
            case .deps: DepsTab().environmentObject(model)
            }
        }
    }
}

// MARK: - Agents tab (locally-detected AI coding agents)

struct AgentsTab: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 14) {
            if !model.aiProjects.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "chart.bar.fill").foregroundStyle(Theme.purple).font(.caption)
                            Text("프로젝트별 AI 토큰 사용량").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("총 \(TokenEstimator.abbrev(model.totalAITokens))")
                                .font(.caption.monospaced()).foregroundStyle(Theme.purple)
                        }
                        let maxTok = model.aiProjects.map(\.aiTokens).max() ?? 1
                        ForEach(model.aiProjects) { p in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(p.name).font(.system(size: 12))
                                    Spacer()
                                    Text("\(TokenEstimator.abbrev(p.aiTokens)) · 세션 \(p.aiSessions)개")
                                        .font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary)
                                }
                                GeometryReader { geo in
                                    Capsule().fill(Theme.purple.opacity(0.7))
                                        .frame(width: max(3, geo.size.width * CGFloat(p.aiTokens) / CGFloat(maxTok)), height: 5)
                                }.frame(height: 5)
                            }
                        }
                    }
                }
            }

            Card {
                HStack {
                    Image(systemName: "cpu").foregroundStyle(Theme.purple)
                    Text("이 컴퓨터에서 감지된 AI 에이전트").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(model.agents.count)개").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }

            if model.agents.isEmpty {
                Card { Text("감지된 AI 에이전트가 없습니다.").font(.callout).foregroundStyle(Theme.textSecondary).padding(.vertical, 10) }
            } else {
                ForEach(model.agents) { agent in
                    Card {
                        HStack(spacing: 10) {
                            Circle().fill(Theme.green).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name).font(.system(size: 13, weight: .semibold))
                                Text(agent.detail ?? "감지됨").font(.caption2).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text("설치됨").font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.green)
                        }
                    }
                }
            }

            Card {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.textTertiary).font(.caption)
                    Text("로컬 설정 파일로 설치 여부만 감지합니다. 각 에이전트의 실제 토큰 사용량은 도구마다 형식이 달라 표시하지 않습니다. ContextOS의 절약량은 사용량 탭에서 확인하세요.")
                        .font(.caption2).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Deps tab (import graph)

struct DepsTab: View {
    @EnvironmentObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Card { StatTile(label: "노드", value: "\(model.depsNodes)") }
                Card { StatTile(label: "엣지", value: "\(model.depsEdges)", tint: Theme.orange) }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("의존성 트리").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    if model.depsTree.isEmpty {
                        Text("의존성 없음").font(.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        ScrollView {
                            Text(model.depsTree)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 240)
                    }
                }
            }
        }
    }
}
