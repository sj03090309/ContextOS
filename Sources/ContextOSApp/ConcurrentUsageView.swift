import AppKit
import SwiftUI
import ContextOSUsage
import ContextOSUsageUI

extension Notification.Name { static let openUsageDashboard = Notification.Name("ContextOS.openUsageDashboard") }

struct ConcurrentUsageSummary: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var ui: DashboardUIState
    var body: some View {
        UsageOverviewCard(snapshot: model.concurrentUsage, expanded: $ui.usageExpanded,
                          compact: ui.page == .overview,
                          showDetails: ui.page == .usage ? nil : { ui.page = .usage })
    }
}

struct UsageOverviewCard: View {
    let snapshot: ConcurrentUsageSnapshot
    @Binding var expanded: Bool
    var compact = false
    var showDetails: (() -> Void)? = nil
    private var data: WidgetUsageSnapshot { snapshot.widget }
    private var working: Int { snapshot.sessions.filter { $0.state == .working }.count }
    private var waiting: Int { snapshot.sessions.filter { $0.state == .waiting }.count }
    private var hasSource: Bool { data.providers.contains { $0.state == .ready || $0.state == .partial || $0.state == .noRecords } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("오늘 관측 토큰").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(data.providers.isEmpty ? "집계 준비 중" : data.health)
                    .font(.system(size: 9)).foregroundStyle(data.health == "일부 수집 불가" ? Brand.caution : Color.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(UsageNumbers.compact(data.today))
                    .font(.system(size: 31, weight: .semibold, design: .rounded)).monospacedDigit()
                    .accessibilityLabel("오늘 관측 토큰")
                    .accessibilityValue(data.today.map(String.init) ?? "확인 가능한 집계 없음")
                Spacer()
                Text(hasSource ? "작업 \(working) · 대기 \(waiting)" : "작업 — · 대기 —")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("관측된 로컬 세션의 상태입니다. 전체 클라우드 작업 수가 아닙니다.")
            }
            if !compact {
                Divider().opacity(0.5)
                TodayModelsList(models: snapshot.todayModels, expanded: $expanded)
            }
            if let showDetails {
                Button(action: showDetails) {
                    HStack { Text("모델·세션 보기"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)) }
                        .font(.system(size: 10)).foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(PanelPressStyle())
            }
            if data.isSample { Text("검증용 예시 · 실제 사용량이 아닙니다").font(.system(size: 9)).foregroundStyle(Brand.caution) }
        }.padding(13)
            .background(Brand.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Brand.accent.opacity(0.09), lineWidth: 1))
    }
}

struct TodayModelsList: View {
    let models: [TodayModelUsage]
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        let preview = ModelUsagePreview(models, expanded: expanded)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("오늘 모델별").font(.system(size: 10, weight: .medium))
                Spacer()
                Text("\(models.count)항목").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if models.isEmpty {
                Text("확인 가능한 오늘 모델 기록이 없어요").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if expanded && models.count > 3 {
                ScrollView { LazyVStack(spacing: 8) { ForEach(preview.visible) { row($0) } } }
                    .frame(height: min(160, CGFloat(models.count) * 23))
            } else {
                ForEach(preview.visible) { row($0) }
            }
            if models.count > 3 {
                Button {
                    withAnimation(PanelMotion.response(reduced: reduced)) { expanded.toggle() }
                } label: {
                    HStack {
                        Text(expanded ? "접기" : "추가 \(preview.hiddenCount)항목 · \(UsageNumbers.compact(preview.hiddenTokens)) 토큰")
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.font(.system(size: 9.5)).foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(PanelPressStyle()).accessibilityValue(expanded ? "전체 표시" : "3항목 표시")
            }
        }
    }
    private func row(_ model: TodayModelUsage) -> some View {
        HStack(spacing: 8) {
            Text(model.key.provider + " · " + model.key.model).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(UsageNumbers.compact(model.tokens)).monospacedDigit().fixedSize()
        }.font(.system(size: 10.5)).help(model.key.provider + " · " + model.key.model)
    }
}

struct ProviderSessionsCard: View {
    let provider: UsageProvider
    let groups: [ModelSessionGroup]
    @State private var expanded = false
    @State private var showAll = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    init(provider: UsageProvider, groups: [ModelSessionGroup], initiallyExpanded: Bool = false) {
        self.provider = provider; self.groups = groups
        _expanded = State(initialValue: initiallyExpanded)
    }
    private var count: Int { groups.reduce(0) { $0 + $1.sessions.count } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(PanelMotion.response(reduced: reduced)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(provider.state == .ready ? Brand.positive : Color.secondary).frame(width: 4, height: 4)
                    Text(provider.name).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("세션 \(count)개").font(.system(size: 10)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 8)).rotationEffect(.degrees(expanded ? 180 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(PanelPressStyle()).accessibilityValue(expanded ? "펼쳐짐" : "접힘")
            if expanded {
                Text(provider.state.label).font(.system(size: 9)).foregroundStyle(.secondary)
                ForEach(provider.issues ?? [], id: \.rawValue) { issue in
                    Text(issue.label).font(.system(size: 9)).foregroundStyle(issue.isFailure ? Brand.caution : Color.secondary)
                }
                if groups.isEmpty { Text("관측된 세션이 없어요").font(.system(size: 10)).foregroundStyle(.secondary) }
                ForEach(showAll ? groups : Array(groups.prefix(3))) { ModelSessionsDisclosure(group: $0) }
                if groups.count > 3 {
                    Button(showAll ? "모델 접기" : "추가 \(groups.count - 3)개 모델 상태 보기") { showAll.toggle() }
                        .font(.system(size: 9.5)).buttonStyle(PanelPressStyle())
                }
            }
        }.dashboardCard(radius: 13, padding: 11)
    }
}

struct ModelSessionsDisclosure: View {
    let group: ModelSessionGroup
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("세션별 오늘 토큰 · 모델 전환분 포함").font(.system(size: 9)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                            HStack {
                                Text("세션 \(index + 1) · " + session.state.label).lineLimit(1)
                                Spacer()
                                Text(UsageNumbers.compact(session.todayTokens)).monospacedDigit()
                            }.font(.system(size: 9.5))
                        }
                    }
                }.frame(height: min(120, CGFloat(group.sessions.count) * 21))
            }.padding(.top, 5)
        } label: {
            HStack {
                Text(group.key.model).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 5)
                Text("\(group.sessions.count)개").monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 10.5))
        }
    }
}

struct PopoverUsageDetail: View {
    @EnvironmentObject var model: DashboardModel
    @State private var showScope = false
    private var data: WidgetUsageSnapshot { model.concurrentUsage.widget }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ConcurrentUsageSummary()
                ForEach(data.providers.filter { $0.state != .unsupported }) { provider in
                    ProviderSessionsCard(provider: provider, groups: model.usageSessionGroups[provider.name] ?? [])
                }
                DisclosureGroup("집계 범위", isExpanded: $showScope) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("로컬 기록만 포함하며 dot·클라우드 전체 사용량은 아닙니다.")
                        Text("모델별 토큰은 오늘의 실제 토큰 이벤트 기준입니다. 세션 상태의 모델명은 마지막 관측 모델이며, 모델 전환분은 세션 상세 합계에 포함돼요.")
                        Text("— 확인 가능한 집계 없음 · 0은 명시된 사용량 0.")
                        ForEach(data.providers) { provider in
                            ForEach(provider.issues ?? [], id: \.rawValue) { issue in
                                Text(provider.name + " · " + issue.label)
                            }
                        }
                        Text("마지막 집계 \(data.generatedAt.formatted(date: .omitted, time: .shortened)) · \(data.timeZoneID)")
                    }.font(.system(size: 9.5)).foregroundStyle(.secondary).padding(.top, 5)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Text("로컬 관측 범위 · dot 전체 사용량 아님").font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
    }
}

struct UsageDetailRoot: View {
    @ObservedObject var model: DashboardModel
    @StateObject private var workTime = WorkTimeController.shared
    var body: some View {
        TabView {
        ConcurrentUsageView(snapshot: model.concurrentUsage, appPresence: model.usageAppPresence,
            bridgeStatus: model.widgetBridgeStatus,
            refresh: { model.refresh() })
            .tabItem { Text("AI 사용량") }
        WorkTimePanel(model: workTime).tabItem { Text("시간 측정") }
        }
            .onAppear { model.panelDidOpen() }
            .onDisappear { model.panelDidClose() }
            .onChange(of: workTime.snapshot) { _, _ in model.shareMeasuredTime() }
            .onChange(of: workTime.showWidgetMascot) { _, _ in model.shareMeasuredTime(force: true) }
            .onChange(of: workTime.smallMetric) { _, _ in model.shareMeasuredTime(force: true) }
    }
}

struct ConcurrentUsageView: View {
    var snapshot: ConcurrentUsageSnapshot
    var appPresence: [String: Bool] = [:]
    var bridgeStatus: String
    var refresh: () -> Void
    private var data: WidgetUsageSnapshot { snapshot.widget }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AI 사용 현황").font(.system(size: 25, weight: .semibold))
                    Text(data.isSample ? "검증용 예시 · 실제 사용량이 아닙니다" : "Codex · Claude Code의 관측 가능한 로컬 기록")
                        .font(.system(size: 12)).foregroundStyle(data.isSample ? .orange : .secondary)
                }
                Spacer()
                Button(action: refresh) { Label("새로고침", systemImage: "arrow.clockwise") }
            }
            if data.providers.isEmpty {
                Label("로컬 집계를 준비하고 있습니다. 잠시 후 새로고침해 주세요.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("수집 범위: 로컬 세션 기록만 포함합니다. dot·클라우드의 전체 사용량이 아니며, 제공되지 않은 사용량은 확인할 수 없습니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(UsageNumbers.compact(data.today)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                VStack(alignment: .leading) {
                    Text("오늘 관측 토큰 합계").font(.headline)
                    Text(data.comparison).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(data.timeZoneID).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(data.providers.filter { $0.state != .unsupported }) { provider in providerSection(provider) }
                    let unsupported = data.providers.filter { $0.state == .unsupported }.map(\.name)
                    if !unsupported.isEmpty {
                        Text("수집 미지원: " + unsupported.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 22) {
                        ranks("오늘 모델 순위", data.models)
                        ranks("7일 프로젝트 순위", data.projects)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("마지막 집계 \(data.generatedAt.formatted(date: .abbreviated, time: .standard)) · \(data.health)")
                Text("— 확인 가능한 집계 없음 · 0은 명시된 사용량 0 · 앱 실행 여부는 작업·사용량의 증거가 아닙니다.")
                Text("도구별 토큰 정의가 달라 합계는 관측 토큰 수입니다. 하위 에이전트·fork 기록은 제외될 수 있습니다.")
                Text("위젯: \(bridgeStatus) · macOS가 갱신 시점을 결정합니다.")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 720, idealWidth: 780, minHeight: 640, idealHeight: 760)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private func providerSection(_ provider: UsageProvider) -> some View {
        let sessions = snapshot.sessions.filter { $0.agent == provider.name }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider.name == "Codex" ? "Codex · 로컬 기록" : provider.name).font(.system(size: 15, weight: .semibold))
                Text(provider.state.label).font(.caption).foregroundStyle(provider.state == .ready ? .green : .secondary)
                Spacer()
                Text(appPresence[provider.name].map { $0 ? "데스크톱 앱 실행 중" : "데스크톱 앱 미실행" } ?? "앱/CLI 실행 여부 미확인")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(UsageNumbers.compact(data.agents.first { $0.name == provider.name }?.tokens)).monospacedDigit()
            }
            if sessions.isEmpty { Text("관측된 세션 없음").font(.caption).foregroundStyle(.secondary) }
            ForEach(sessions) { session in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(session.state == .working ? Color.green : session.state == .waiting ? .orange : .secondary)
                        .frame(width: 6, height: 6).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.project).lineLimit(1)
                        Text("\(session.model) · 세션 \(session.id.prefix(8))").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        if session.agent == "Codex" { Text(session.origin.label).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(session.state.label).font(.system(size: 11))
                        if let last = session.lastEvent { Text(last, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }.frame(width: 100, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("오늘 \(UsageNumbers.compact(session.todayTokens))")
                        Text("기록 합계 \(UsageNumbers.compact(session.totalTokens))").foregroundStyle(.secondary)
                    }.font(.system(size: 10)).monospacedDigit().frame(width: 100, alignment: .trailing)
                }.padding(.vertical, 3)
            }
        }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
    private func ranks(_ title: String, _ values: [UsageRank]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if values.isEmpty { Text("기록 없음").foregroundStyle(.secondary) }
            ForEach(values) { rank in
                HStack { Text(rank.name).lineLimit(1); Spacer(); Text(UsageNumbers.compact(rank.tokens)).monospacedDigit() }
            }
        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class UsageWindowController {
    private var window: NSWindow?
    func show<V: View>(_ view: V, title: String) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("contextos-usage-detail")
        window.contentViewController = NSHostingController(rootView: view)
        window.minSize = NSSize(width: 720, height: 640)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
