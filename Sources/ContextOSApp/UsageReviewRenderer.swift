import AppKit
import SwiftUI
import ContextOSUsage
import ContextOSUsageUI

@MainActor
enum UsageReviewRenderer {
    static func cases(now: Date = Date()) -> [(String, WidgetUsageSnapshot)] {
        let sample = UsagePreviewData.snapshot(now: now).widget
        var empty = sample
        empty.days = empty.days.map { .init(date: $0.date, tokens: nil) }
        empty.agents = []; empty.models = []; empty.projects = []; empty.dailyBudget = nil
        empty.providers = [.init(name: "Codex", state: .noRecords)]
        var unsupported = empty; unsupported.providers = [.init(name: "Other AI", state: .unsupported)]
        var zero = empty; zero.days[6].tokens = 0; zero.days[5].tokens = 0
        var stale = sample; stale.generatedAt = now.addingTimeInterval(-3700)
        var disconnected = sample; disconnected.providers = [.init(name: "Codex", state: .unavailable)]
        var large = sample
        large.days[6].tokens = Int64.max
        large.models = [.init(String(repeating: "very-long-model-name-", count: 5), .max), .init("Second model", 4_500_000_000), .init("Third model", 1_300_000)]
        large.agents = [.init(String(repeating: "very-long-ai-name-", count: 5), .max), .init("Second AI", 4_500_000_000), .init("Third AI", 1_300_000)]
        var timer = sample
        timer.smallMetric = .workTimer
        timer.timing = .init(generatedAt: now, manualNanoseconds: 5_432_000_000_000, manualState: .paused, isSample: true)
        var unobserved = sample; unobserved.smallMetric = .editorForeground
        unobserved.timing = .init(generatedAt: now, isSample: true)
        var automatic = sample; automatic.smallMetric = .activity
        automatic.timing = .init(generatedAt: now, isSample: true, activity: .init(now: now, estimatedNanoseconds: 9_032_000_000_000, phase: .active))
        var automaticPaused = automatic
        automaticPaused.timing?.activity?.phase = .paused; automaticPaused.timing?.activity?.partial = true
        var automaticEmpty = automatic; automaticEmpty.timing?.activity = nil
        return [("activity", automatic), ("activity-paused", automaticPaused), ("activity-unobserved", automaticEmpty), ("normal", sample), ("empty", empty), ("zero", zero), ("unsupported", unsupported), ("stale", stale), ("disconnected", disconnected), ("large-long-names", large), ("timer", timer), ("time-unobserved", unobserved)]
    }
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, snapshot) in cases() {
            for scheme in [ColorScheme.light, .dark] {
                for size in UsageWidgetView.Size.allCases {
                    let width: CGFloat = size == .small ? 158 : 338
                    let height: CGFloat = size == .large ? 354 : 158
                    let view = UsageWidgetView(snapshot: snapshot, size: size)
                        .padding(14).frame(width: width, height: height)
                        .background { UsageWidgetBackground() }
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let cg = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                    let appearance = scheme == .dark ? "dark" : "light"
                    try png.write(to: directory.appendingPathComponent("\(name)-\(size.rawValue)-\(appearance).png"))
                }
            }
        }
    }
}
