import SwiftUI
import ContextOSUsage
import ContextOSUsageUI

/// Explicit launch-only review mode. It never creates DashboardModel or reads
/// the user's logs, project registry, usage DB or credentials.
struct UsageReviewRoot: View {
    @State private var snapshot = UsagePreviewData.snapshot()
    @State private var budget = "1000000"
    var body: some View {
        TabView {
            ConcurrentUsageView(snapshot: snapshot, appPresence: ["Codex": true], bridgeStatus: "서명/App Group 승인 전 · 미연결",
                budget: $budget, refresh: { snapshot = UsagePreviewData.snapshot() },
                saveBudget: { snapshot.widget.dailyBudget = Int64(budget) })
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
    }
    private func widget(_ size: UsageWidgetView.Size, width: CGFloat, height: CGFloat, scheme: ColorScheme) -> some View {
        UsageWidgetView(snapshot: snapshot.widget, size: size)
            .padding(14).frame(width: width, height: height)
            .background { UsageWidgetBackground().clipShape(RoundedRectangle(cornerRadius: 20)) }
            .environment(\.colorScheme, scheme)

    }
}
