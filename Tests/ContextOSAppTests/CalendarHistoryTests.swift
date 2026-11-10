import AppKit
import SwiftUI
import Testing
import ContextOSCore
import ContextOSUsage
@testable import ContextOSApp

@Suite("Saved calendar history", .serialized)
@MainActor
struct CalendarHistoryTests {
    private struct Fixture {
        var directory: URL
        var database: URL
        var originalLogs: URL
        var today: String
        var earlier: String
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let database = directory.appendingPathComponent("saved-usage.sqlite")
        // These paths deliberately never exist. Restoring saved history must
        // not rediscover original transcripts or require them to remain on disk.
        let originalLogs = directory.appendingPathComponent("original-logs-never-created")
        let project = directory.appendingPathComponent("project-never-created").path
        let now = Date()
        let earlierDate = try #require(Calendar.current.date(byAdding: .day, value: -40, to: now))
        let today = TimeKeys.localDay(now.timeIntervalSince1970)
        let earlier = TimeKeys.localDay(earlierDate.timeIntervalSince1970)
        let store = try UsageStore(path: database.path)
        let rows = [("Claude Code", "claude.jsonl", 200, 1000), ("Codex", "codex.jsonl", 300, 700)].map {
            agent, filename, fresh, old in
            SessionCacheRow(path: originalLogs.appendingPathComponent(filename).path, agent: agent,
                            mtime: now.timeIntervalSince1970, size: 100, lastProject: project,
                            projects: [project: .init(tokens: fresh + old, start: earlierDate.timeIntervalSince1970,
                                                       end: now.timeIntervalSince1970,
                                                       days: [today: fresh, earlier: old])])
        }
        try store.upsertSessionCache(rows)
        try store.record(.init(timestamp: now.timeIntervalSince1970, project: project, query: "fixture query",
                               selectedTokens: 100, fullTokens: 900, contextScore: 80, fileCount: 2))
        return Fixture(directory: directory, database: database, originalLogs: originalLogs, today: today, earlier: earlier)
    }

    @Test("Cold restoration shows saved calendar dates while collection is off and source logs are absent")
    func coldSavedHistoryWithConsentOff() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.directory) }
        let suite = "ContextOS.CalendarHistory." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.agentLogsEnabled)
        let model = DashboardModel(startServices: false, settings: settings)
        #expect(!model.agentLogCollectionEnabled)

        let result = await DashboardModel.loadSavings(includeHistory: true, includeWeek: true,
                                                       storePath: value.database.path)
        let history = try #require(result.history)
        #expect(history.byDay == [value.today: 500, value.earlier: 1700])
        #expect(history.byAgentDay["Claude Code"] == [value.today: 200, value.earlier: 1000])
        #expect(history.byAgentDay["Codex"] == [value.today: 300, value.earlier: 700])
        #expect(history.totalTokens == 2200)
        #expect(result.queryCount == 1 && result.totalSaved == 800 && result.todaySaved == 800)
        #expect(result.week?.tokens == 500)
        #expect(!FileManager.default.fileExists(atPath: value.originalLogs.path))
        #expect(!settings.agentLogsEnabled && !model.agentLogCollectionEnabled)
        // Reopening a different store proves this was a persisted, cold load.
        let reopened = try UsageStore(path: value.database.path)
        #expect(reopened.sessionCache().count == 2)
        #expect(reopened.recentEvents().count == 1)
        #expect(reopened.savingsByDay(since: 0)[value.today] == 800)
    }

    @Test("Fast savings refresh can skip historical cache materialization")
    func savingsWithoutHistory() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.directory) }
        let result = await DashboardModel.loadSavings(includeHistory: false, includeWeek: true,
                                                       storePath: value.database.path)
        #expect(result.history == nil && result.week == nil)
        #expect(result.totalSaved == 800 && result.queryCount == 1)
        #expect(!FileManager.default.fileExists(atPath: value.originalLogs.path))
    }

    @Test("Stopping new collection preserves both saved calendar maps while clearing live usage")
    func disablingPreservesCalendar() throws {
        let suite = "ContextOS.CalendarPreservation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(startServices: false, settings: AppSettings(defaults: defaults))
        model.setAgentLogCollectionEnabled(true)
        let dates = ["2026-08-17": 1700, "2026-09-04": 500]
        let agents = ["Claude Code": ["2026-08-17": 1000, "2026-09-04": 200],
                      "Codex": ["2026-08-17": 700, "2026-09-04": 300]]
        model.tokensByDay = dates
        model.agentDayTokens = agents
        model.aiTokens = 2200
        model.concurrentUsage = .init(widget: .init(days: [.init(date: Date(), tokens: 2200)]),
                                      sessions: [.init(id: "fixture", agent: "Codex", project: "/fixture",
                                                       model: "fixture", state: .working, lastEvent: Date(),
                                                       todayTokens: 500, totalTokens: 2200)])
        model.setAgentLogCollectionEnabled(false)
        #expect(!model.agentLogCollectionEnabled)
        #expect(model.tokensByDay == dates && model.agentDayTokens == agents)
        #expect(model.aiTokens == 0 && model.concurrentUsage.sessions.isEmpty)
        #expect(model.concurrentUsage.widget.today == nil)
        #expect(model.concurrentUsage.widget.health == "로그 집계 꺼짐")
    }

    @Test("Maximum provider counters retain a finite 50/50 share and render the saved-history calendar")
    func maximumProviderSplitRenders() throws {
        #expect(CalendarCard.providerFraction(Int.max, other: Int.max) == 0.5)
        #expect(CalendarCard.providerFraction(200, other: 800) == 0.2)
        #expect(CalendarCard.providerFraction(100, other: 0) == 1)
        #expect(CalendarCard.providerFraction(0, other: 100) == 0)
        #expect(CalendarCard.providerFraction(0, other: 0) == 0)

        let suite = "ContextOS.CalendarRendering." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(startServices: false, settings: AppSettings(defaults: defaults))
        let day = TimeKeys.localDay(Date().timeIntervalSince1970)
        model.tokensByDay = [day: .max]
        model.agentDayTokens = ["Claude Code": [day: .max], "Codex": [day: .max]]
        let ui = DashboardUIState()
        ui.selectedDay = day
        for scheme in [ColorScheme.light, .dark] {
            let view = CalendarCard().padding(16).frame(width: 340, height: 390)
                .background(Brand.canvas).environment(\.colorScheme, scheme)
                .environmentObject(model).environmentObject(ui)
            let png = try renderNative(view, height: 390, scheme: scheme)
            #expect(!png.isEmpty)
            if let path = ProcessInfo.processInfo.environment["CONTEXTOS_DESIGN_QA_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent(scheme == .dark ? "calendar-dark.png" : "calendar-light.png"))
            }
        }
        #expect(model.tokensByDay[day] == Int.max)
        #expect(model.agentDayTokens["Claude Code"]?[day] == Int.max)
        #expect(model.agentDayTokens["Codex"]?[day] == Int.max)
    }

    private func renderNative<V: View>(_ view: V, height: CGFloat, scheme: ColorScheme) throws -> Data {
        _ = NSApplication.shared
        let width: CGFloat = 340
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(width) && bitmap.pixelsHigh >= Int(height))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
