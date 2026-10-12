import Foundation

/// Synthetic fixtures only. Never used as fallback live usage.
public enum UsagePreviewData {
    public static func snapshot(now: Date = Date()) -> ConcurrentUsageSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let counts: [Int64?] = [120_200, 680_700, nil, 320_000, 810_500, 450_000, 920_400]
        let days = counts.enumerated().map { index, count in
            UsageDay(date: calendar.date(byAdding: .day, value: index - 6, to: today)!, tokens: count)
        }
        let widget = WidgetUsageSnapshot(generatedAt: now, days: days,
            models: [.init("Codex · gpt-example-long-model-name", 620_000), .init("Claude Code · claude-example", 300_400)],
            agents: [.init("Codex", 620_000), .init("Claude Code", 300_400)],
            projects: [.init("ContextOS · a1b2", 2_100_000), .init("Demo project · c3d4", 1_201_800)],
            providers: [.init(name: "Codex", state: .ready, latestEvent: now),
                        .init(name: "Claude Code", state: .ready, latestEvent: now),
                        .init(name: "Gemini CLI", state: .unsupported), .init(name: "Cursor", state: .unsupported)],
            dailyBudget: 1_000_000, isSample: true)
        return .init(widget: widget, sessions: [
            .init(id: "sample-codex-a", agent: "Codex", project: "ContextOS · a1b2", model: "gpt-example-long-model-name", state: .working, lastEvent: now, todayTokens: 400_000, totalTokens: 1_200_000),
            .init(id: "sample-codex-b", agent: "Codex", project: "Demo project · c3d4", model: "gpt-example", state: .waiting, lastEvent: now.addingTimeInterval(-60), todayTokens: 220_000, totalTokens: 450_000),
            .init(id: "sample-claude-a", agent: "Claude Code", project: "ContextOS · a1b2", model: "claude-example", state: .idle, lastEvent: now, todayTokens: 300_400, totalTokens: 900_000)
        ])
    }
}
