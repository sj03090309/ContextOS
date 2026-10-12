import AppKit
import SwiftUI
import ContextOSUsage
import ContextOSUsageUI

extension Notification.Name { static let openUsageDashboard = Notification.Name("ContextOS.openUsageDashboard") }

struct ConcurrentUsageSummary: View {
    @EnvironmentObject var model: DashboardModel
    var body: some View {
        Button { NotificationCenter.default.post(name: .openUsageDashboard, object: nil) } label: {
            HStack {
                Image(systemName: "rectangle.stack").foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 동시 세션").font(.system(size: 11, weight: .semibold))
                    Text("\(model.concurrentUsage.sessions.filter { $0.state == .working || $0.state == .waiting }.count)개 작업·대기 · 상세 보기")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(UsageNumbers.compact(model.concurrentUsage.widget.today)).font(.system(size: 16, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.right").font(.system(size: 9))
            }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

struct UsageDetailRoot: View {
    @ObservedObject var model: DashboardModel
    @State private var budget = ""
    var body: some View {
        ConcurrentUsageView(snapshot: model.concurrentUsage, appPresence: model.usageAppPresence,
            bridgeStatus: model.widgetBridgeStatus, budget: $budget,
            refresh: { model.refresh() }, saveBudget: { model.setDailyBudget(budget) })
            .onAppear { budget = model.dailyTokenBudget.map(String.init) ?? ""; model.panelDidOpen() }
            .onDisappear { model.panelDidClose() }
    }
}

struct ConcurrentUsageView: View {
    var snapshot: ConcurrentUsageSnapshot
    var appPresence: [String: Bool] = [:]
    var bridgeStatus: String
    @Binding var budget: String
    var refresh: () -> Void
    var saveBudget: () -> Void
    private var data: WidgetUsageSnapshot { snapshot.widget }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AI 사용 현황").font(.system(size: 25, weight: .semibold))
                    Text(data.isSample ? "검증용 예시 · 실제 사용량이 아닙니다" : "Codex · Claude Code 로컬 주 세션 기록")
                        .font(.system(size: 12)).foregroundStyle(data.isSample ? .orange : .secondary)
                }
                Spacer()
                Button(action: refresh) { Label("새로고침", systemImage: "arrow.clockwise") }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(UsageNumbers.compact(data.today)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                VStack(alignment: .leading) {
                    Text("오늘 관측 토큰 합계").font(.headline)
                    Text(data.comparison).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(data.timeZoneID).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("내 일일 토큰 예산").font(.caption)
                TextField("미설정", text: $budget).frame(width: 110)
                Button("저장", action: saveBudget)
                if data.nearBudget { Text("예산 80% 이상").foregroundStyle(.orange).font(.caption) }
                Spacer()
                Text("구독 잔여량과 무관").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(data.providers) { provider in providerSection(provider) }
                    HStack(alignment: .top, spacing: 22) {
                        ranks("오늘 모델 순위", data.models)
                        ranks("7일 프로젝트 순위", data.projects)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("마지막 집계 \(data.generatedAt.formatted(date: .abbreviated, time: .standard)) · \(data.health)")
                Text("— 기록 없음 · 0은 명시된 사용량 0 · 앱 실행 여부는 작업·사용량의 증거가 아닙니다.")
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
                Text(provider.name).font(.system(size: 15, weight: .semibold))
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
        window.contentView = NSHostingView(rootView: view)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
