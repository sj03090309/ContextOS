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
        }.frame(width: 800, height: 780)
            .onAppear { publishSample() }
    }
    /// The isolated review app shares fixtures only. Real log collectors remain
    /// confined to the normal host app; review mode never creates DashboardModel.
    private func publishSample() {
        guard let container = WidgetSnapshotStore.container() else {
            bridgeStatus = "공유 그룹 미연결"; return
        }
        do {
            try WidgetSnapshotStore.write(snapshot.widget, to: container)
            bridgeStatus = "합성 집계 공유됨 · 실제 사용량 아님"
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
        } catch { bridgeStatus = "합성 집계 공유 실패" }
    }
    private func widget(_ size: UsageWidgetView.Size, width: CGFloat, height: CGFloat, scheme: ColorScheme) -> some View {
        UsageWidgetView(snapshot: snapshot.widget, size: size)
            .padding(14).frame(width: width, height: height)
            .background { UsageWidgetBackground().clipShape(RoundedRectangle(cornerRadius: 20)) }
            .environment(\.colorScheme, scheme)

    }
}
