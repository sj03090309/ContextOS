import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetUsageSnapshot
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .init(date: Date(), snapshot: .init()) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(entry(at: Date()))
    }
    private func entry(at date: Date) -> UsageEntry {
        let snapshot = WidgetSnapshotStore.container().flatMap { WidgetSnapshotStore.read(from: $0, channel: Bundle.main.bundleIdentifier == "com.contextos.review.widgets" ? .review : .production) }
            ?? WidgetUsageSnapshot(generatedAt: date)
        return .init(date: date, snapshot: snapshot)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date(), first = entry(at: Date())
        // Pre-render stale and midnight states even if the OS defers a reload.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: first.snapshot.timeZoneID) ?? .current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let stale = max(now.addingTimeInterval(5 * 60), first.snapshot.generatedAt.addingTimeInterval(30 * 60 + 1))
        let timeStale = first.snapshot.timing.map { max(now.addingTimeInterval(5 * 60), $0.generatedAt.addingTimeInterval(30 * 60 + 1)) }
        let activityStale = first.snapshot.timing?.activity.map { max(now.addingTimeInterval(1), $0.generatedAt.addingTimeInterval(91)) }
        let dates = Set([now, stale, midnight] + (activityStale.map { [$0] } ?? []) + (timeStale.map { [$0] } ?? [])).sorted()
        completion(Timeline(entries: dates.map { UsageEntry(date: $0, snapshot: first.snapshot) },
                            policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct WidgetBody: View {
    @Environment(\.widgetFamily) var family
    var entry: UsageEntry
    var body: some View {
        UsageWidgetView(snapshot: entry.snapshot,
            size: family == .systemSmall ? .small : family == .systemMedium ? .medium : .large,
            now: entry.date)
            .containerBackground(for: .widget) { UsageWidgetBackground() }
            .widgetURL(WidgetSnapshotStore.detailURL())
    }
}

@main
struct ContextOSUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.kind, provider: UsageTimelineProvider()) { entry in
            WidgetBody(entry: entry)
        }
        .configurationDisplayName(Bundle.main.bundleIdentifier == "com.contextos.review.widgets" ? "ContextOS 테스트 · 샘플" : "ContextOS · AI 사용량")
        .description("관측된 로컬 토큰, 모델 순위와 주간 추이. 갱신 시점은 macOS가 결정합니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
