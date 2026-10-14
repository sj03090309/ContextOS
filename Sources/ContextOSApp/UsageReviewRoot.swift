import SwiftUI
import ContextOSUsage
import ContextOSUsageUI
import WidgetKit

/// Explicit launch-only review mode. It never creates DashboardModel or reads
/// the user's logs, project registry, usage DB or credentials.
struct UsageReviewRoot: View {
    @State private var snapshot = UsagePreviewData.snapshot()
    @State private var budget = "1000000"
    @State private var bridgeStatus = "공유 그룹 미연결"
    @StateObject private var workTime = WorkTimeController.shared
    @State private var lastShare = Date.distantPast
    @State private var lastReload = Date.distantPast
    var body: some View {
        TabView {
            ConcurrentUsageView(snapshot: snapshot, appPresence: ["Codex": true], bridgeStatus: bridgeStatus,
                budget: $budget, refresh: { snapshot = UsagePreviewData.snapshot(); publishSample() },
                saveBudget: { snapshot.widget.dailyBudget = Int64(budget); publishSample() })
                .tabItem { Text("대시보드 · 예시") }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("WidgetKit 공용 뷰 레이아웃 검증 · 실제 위젯 설치 아님").font(.headline)
                    ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                        HStack(alignment: .top, spacing: 16) {
                            widget(.small, width: 158, height: 158, scheme: scheme)
                            VStack(spacing: 16) {
                                widget(.medium, width: 338, height: 158, scheme: scheme)
                                widget(.large, width: 338, height: 354, scheme: scheme)
                            }
                        }
                    }
                }.padding(24)
            }.tabItem { Text("위젯 3크기 · 예시") }
            WorkTimePanel(model: workTime).tabItem { Text("시간 측정") }
        }.frame(width: 800, height: 780)
            .onAppear { publishSample() }
            .onChange(of: workTime.snapshot) { _, _ in publishSample(force: false) }
            .onChange(of: workTime.smallMetric) { _, _ in publishSample() }
            .onChange(of: workTime.snapshot.manualState) { _, _ in publishSample() }
            .onChange(of: workTime.snapshot.foregroundState) { _, _ in publishSample() }
            .onChange(of: workTime.snapshot.activity?.phase) { _, _ in publishSample() }
    }
    /// The isolated review app shares fixtures only. Real log collectors remain
    /// confined to the normal host app; review mode never creates DashboardModel.
    private func publishSample(force: Bool = true) {
        guard force || Date().timeIntervalSince(lastShare) >= 60 else { return }
        guard let container = WidgetSnapshotStore.container() else {
            bridgeStatus = "공유 그룹 미연결"; return
        }
        do {
            var payload = snapshot.widget
            payload.timing = workTime.snapshot
            payload.smallMetric = workTime.smallMetric
            try WidgetSnapshotStore.write(payload, to: container)
            lastShare = Date()
            bridgeStatus = "합성 집계 공유됨 · 실제 사용량 아님"
            if Date().timeIntervalSince(lastReload) >= 15 * 60 {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
                lastReload = Date()
            }
        } catch { bridgeStatus = "합성 집계 공유 실패" }
    }
    private func widget(_ size: UsageWidgetView.Size, width: CGFloat, height: CGFloat, scheme: ColorScheme) -> some View {
        var payload = snapshot.widget
        payload.timing = workTime.snapshot; payload.smallMetric = workTime.smallMetric
        return UsageWidgetView(snapshot: payload, size: size)
            .padding(14).frame(width: width, height: height)
            .background { UsageWidgetBackground().clipShape(RoundedRectangle(cornerRadius: 20)) }
            .environment(\.colorScheme, scheme)

    }
}
