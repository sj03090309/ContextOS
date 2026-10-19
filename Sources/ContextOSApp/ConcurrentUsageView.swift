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
                          showDetails: ui.page == .usage ? nil : { ui.page = .usage })
    }
}

/// A presentation of the existing observed snapshot, with no collector or timer.
struct UsageOverviewCard: View {
    let snapshot: ConcurrentUsageSnapshot
    @Binding var expanded: Bool
    var showDetails: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var data: WidgetUsageSnapshot { snapshot.widget }
    private var working: Int { snapshot.sessions.filter { $0.state == .working }.count }
    private var waiting: Int { snapshot.sessions.filter { $0.state == .waiting }.count }
    private var hasObservedSource: Bool {
        data.providers.contains { $0.state == .ready || $0.state == .partial || $0.state == .noRecords }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("오늘 관측 토큰", systemImage: "sparkle")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("로컬 기록").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                Text(UsageNumbers.compact(data.today))
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .tracking(-0.8).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(PanelMotion.feedback(reduced: reduced), value: data.today)
                    .accessibilityLabel("오늘 관측 토큰")
                    .accessibilityValue(data.today.map(String.init) ?? "확인 가능한 집계 없음")
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(data.providers.isEmpty ? "집계 준비 중" : data.health)
                        .foregroundStyle(data.health == "일부 수집 불가" ? Brand.caution : Color.secondary)
                    Text(data.comparison).foregroundStyle(.secondary)
                }.font(.system(size: 9.5))
            }
            HStack(spacing: 7) {
                sessionCount("작업 중", value: working, symbol: "circle.inset.filled", active: working > 0)
                sessionCount("응답 대기", value: waiting, symbol: "ellipsis", active: false)
            }
            Divider().opacity(0.6)
            Button {
                withAnimation(PanelMotion.response(reduced: reduced)) { expanded.toggle() }
            } label: {
                HStack {
                    Text("오늘 모델별 사용량").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }.contentShape(Rectangle()).padding(.vertical, 3)
            }
            .buttonStyle(PanelPressStyle())
            .accessibilityValue(expanded ? "펼쳐짐" : "접힘")
            .accessibilityHint("확인 가능한 오늘의 상위 모델 기록")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if data.models.isEmpty {
                        PanelEmptyState(symbol: "tray", title: "아직 확인할 모델 기록이 없어요",
                                        detail: "관측 가능한 로컬 기록이 생기면 여기에 표시돼요.")
                    }
                    ForEach(data.models) { rank in
                        VStack(spacing: 5) {
                            HStack {
                                Text(rank.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(UsageNumbers.compact(rank.tokens)).monospacedDigit()
                            }.font(.system(size: 10.5))
                            GeometryReader { geo in
                                Capsule().fill(Brand.color(forAgent: rank.name.hasPrefix("Codex") ? "Codex" : rank.name.hasPrefix("Claude Code") ? "Claude Code" : "").opacity(0.65))
                                    .frame(width: geo.size.width * CGFloat(min(1, max(0, Double(rank.tokens) / Double(max(1, data.models.first?.tokens ?? 1))))))
                            }.frame(height: 3).accessibilityHidden(true)
                        }
                    }
                }.transition(.opacity)
            }
            if let showDetails {
                Button(action: showDetails) {
                    HStack {
                        Text("AI 사용량 자세히")
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10))
                    }.font(.system(size: 10.5, weight: .medium)).contentShape(Rectangle())
                }.buttonStyle(PanelPressStyle()).foregroundStyle(.secondary)
            }
            if data.isSample {
                Text("검증용 예시 · 실제 사용량이 아닙니다").font(.system(size: 10)).foregroundStyle(Brand.caution)
            }
        }.padding(16)
            .background(Brand.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(Brand.accent.opacity(0.12), lineWidth: 1))
    }
    private func sessionCount(_ title: String, value: Int, symbol: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 8, weight: .medium)).accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 2)
            Text(hasObservedSource ? "\(value)" : "—").monospacedDigit().fontWeight(.semibold)
        }.font(.system(size: 10.5))
            .foregroundStyle(active ? Brand.positive : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
            .help("관측된 로컬 세션의 상태입니다. 앱 실행 여부나 전체 클라우드 작업 수가 아닙니다.")
    }
}

struct PopoverUsageDetail: View {
    @EnvironmentObject var model: DashboardModel
    @State private var showScope = false
    private var data: WidgetUsageSnapshot { model.concurrentUsage.widget }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConcurrentUsageSummary()
                PanelSectionHeading(title: "연결된 기록", detail: "관측 상태")
                ForEach(data.providers.filter { $0.state != .unsupported }) { provider in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Circle().fill(provider.state == .ready ? Brand.positive : Brand.caution).frame(width: 5, height: 5)
                            Text(provider.name).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(provider.state.label).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                        let sessions = model.concurrentUsage.sessions.filter { $0.agent == provider.name }
                        ForEach(sessions) { session in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.model).lineLimit(1)
                                    Text(session.state.label).foregroundStyle(.secondary).font(.system(size: 10))
                                }
                                Spacer()
                                Text(UsageNumbers.compact(session.todayTokens)).monospacedDigit()
                            }.font(.system(size: 11))
                        }
                        if sessions.isEmpty {
                            Text("관측된 세션이 없어요").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.dashboardCard(radius: 16, padding: 14)
                }
                if data.providers.isEmpty {
                    PanelEmptyState(symbol: "hourglass", title: "로컬 기록을 확인하고 있어요",
                                    detail: "집계가 준비되면 확인 가능한 범위가 표시돼요.")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("로컬 기록만 포함하며, dot·클라우드 전체 사용량은 아닙니다.")
                    DisclosureGroup("집계 범위와 상태", isExpanded: $showScope) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("— 확인 가능한 집계 없음 · 0은 명시된 사용량 0. 앱 실행 여부는 작업·사용량의 증거가 아닙니다.")
                            Text("Codex · Claude Code의 로컬 기록만 포함합니다. 하위 에이전트·fork 기록은 제외될 수 있어요.")
                            Text("수집 미지원: " + data.providers.filter { $0.state == .unsupported }.map(\.name).joined(separator: ", "))
                            Text("마지막 집계 \(data.generatedAt.formatted(date: .omitted, time: .shortened))")
                        }.padding(.top, 6)
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 2)
            }.padding(.horizontal, 16).padding(.bottom, 18)
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
