import Foundation
import Testing
import ContextOSUsage
@testable import ContextOSApp

@Suite("Widget shared snapshot and reload", .serialized)
@MainActor
struct WidgetSnapshotPublisherTests {
    private let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)

    private func container() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snapshot(at date: Date, tokens: Int64 = 100) -> WidgetUsageSnapshot {
        var value = WidgetUsageSnapshot(generatedAt: date,
            days: [.init(date: Calendar.current.startOfDay(for: date), tokens: tokens)],
            models: [.init("Codex · test", tokens)], agents: [.init("Codex", tokens)],
            providers: [.init(name: "Codex", state: .ready, latestEvent: date)])
        value.smallMetric = .tokens
        value.showMascot = true
        value.timing = .init(generatedAt: date)
        return value
    }

    @Test("Manual refresh saves fresh counters before requesting a timeline inside both cooldowns")
    func manualRefresh() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        var reloads = 0
        try publisher.publish(snapshot(at: now), to: directory, at: now) { reloads += 1 }
        let fresh = snapshot(at: now.addingTimeInterval(1), tokens: 200)
        try publisher.publish(fresh, to: directory, force: true, at: now.addingTimeInterval(1)) {
            #expect(WidgetSnapshotStore.read(from: directory) == fresh)
            reloads += 1
        }
        #expect(reloads == 2)
    }

    @Test("Frequent counters keep minute writes and a fifteen-minute ordinary reload cadence")
    func ordinaryCounters() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        var reloads = 0
        try publisher.publish(snapshot(at: now), to: directory, at: now) { reloads += 1 }
        for index in 1...30 {
            let date = now.addingTimeInterval(Double(index) * 30)
            // Keep the same observation day even if this test runs near midnight.
            var fresh = snapshot(at: date, tokens: Int64(100 + index))
            fresh.days[0].date = Calendar.current.startOfDay(for: now)
            let wrote = try publisher.publish(fresh, to: directory, at: date) { reloads += 1 }
            #expect(wrote == index.isMultiple(of: 2))
        }
        #expect(reloads == 2)
        #expect(WidgetSnapshotStore.read(from: directory)?.today == 130)
    }

    @Test("Completed cold collection replaces the initial partial timeline immediately")
    func collectionCompletes() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        var initial = snapshot(at: now)
        initial.providers[0].state = .partial
        initial.providers[0].isCollecting = true
        var reloads = 0
        try publisher.publish(initial, to: directory, at: now) { reloads += 1 }
        let complete = snapshot(at: now.addingTimeInterval(1), tokens: 5_000)
        try publisher.publish(complete, to: directory, at: now.addingTimeInterval(1)) { reloads += 1 }
        #expect(reloads == 2)
        #expect(WidgetSnapshotStore.read(from: directory) == complete)
    }

    @Test("Metric, mascot and timer-state changes are reflected without waiting for counters")
    func preferencesAndTimer() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        var value = snapshot(at: now)
        var reloads = 0
        try publisher.publish(value, to: directory, at: now) { reloads += 1 }
        value.smallMetric = .workTimer
        try publisher.publish(value, to: directory, at: now.addingTimeInterval(1)) { reloads += 1 }
        value.showMascot = false
        try publisher.publish(value, to: directory, at: now.addingTimeInterval(2)) { reloads += 1 }
        value.timing?.manualState = .running
        try publisher.publish(value, to: directory, at: now.addingTimeInterval(3)) { reloads += 1 }
        #expect(reloads == 4)
        #expect(WidgetSnapshotStore.read(from: directory) == value)
    }

    @Test("Day and time-zone boundaries bypass the last write and reload cooldown")
    func calendarBoundaries() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        let midnight = Calendar.current.startOfDay(for: now)
        var reloads = 0
        try publisher.publish(snapshot(at: midnight.addingTimeInterval(-1)), to: directory,
                              at: midnight.addingTimeInterval(-1)) { reloads += 1 }
        var today = snapshot(at: midnight.addingTimeInterval(1), tokens: 1)
        try publisher.publish(today, to: directory, at: midnight.addingTimeInterval(1)) { reloads += 1 }
        today.timeZoneID = today.timeZoneID == "UTC" ? "Asia/Seoul" : "UTC"
        try publisher.publish(today, to: directory, at: midnight.addingTimeInterval(2)) { reloads += 1 }
        #expect(reloads == 3)
        #expect(WidgetSnapshotStore.read(from: directory) == today)
    }

    @Test("Settings save immediately and request the final selection once more when the app loses focus")
    func preferenceInteractionCompletes() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        var value = snapshot(at: now)
        var reloads = 0
        publisher.finishPreferenceChanges(at: now) { reloads += 1 }
        #expect(reloads == 0)
        try publisher.publish(value, to: directory, at: now) { reloads += 1 }
        for metric in [SmallWidgetMetric.workTimer, .activity, .editorForeground] {
            value.smallMetric = metric
            try publisher.publish(value, to: directory, preferenceChange: true,
                                  at: now.addingTimeInterval(1)) {
                #expect(WidgetSnapshotStore.read(from: directory) == value)
                reloads += 1
            }
        }
        value.showMascot = false
        try publisher.publish(value, to: directory, preferenceChange: true,
                              at: now.addingTimeInterval(2)) { reloads += 1 }
        #expect(reloads == 5)
        publisher.finishPreferenceChanges(at: now.addingTimeInterval(3)) {
            #expect(WidgetSnapshotStore.read(from: directory) == value)
            reloads += 1
        }
        publisher.finishPreferenceChanges(at: now.addingTimeInterval(4)) { reloads += 1 }
        #expect(reloads == 6)
    }

    @Test("An unsuccessful setting save never schedules a background reload of stale data")
    func failedPreferenceSave() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        var reloads = 0
        #expect(throws: (any Error).self) {
            try publisher.publish(snapshot(at: now), to: directory.appendingPathComponent("missing"),
                                  preferenceChange: true, at: now) { reloads += 1 }
        }
        publisher.finishPreferenceChanges(at: now) { reloads += 1 }
        #expect(reloads == 0)
    }

    @Test("A failed save never requests a reload or delays the first successful retry")
    func failedWriteRetries() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        let value = snapshot(at: now)
        var reloads = 0
        #expect(throws: (any Error).self) {
            try publisher.publish(value, to: directory.appendingPathComponent("missing"), at: now) { reloads += 1 }
        }
        #expect(reloads == 0)
        try publisher.publish(value, to: directory, at: now.addingTimeInterval(1)) { reloads += 1 }
        #expect(reloads == 1)
        #expect(WidgetSnapshotStore.read(from: directory) == value)
    }

    @Test("Empty startup and synthetic data cannot overwrite the last production aggregate")
    func preservesProductionSnapshot() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        let real = snapshot(at: now)
        var reloads = 0
        try publisher.publish(real, to: directory, at: now) { reloads += 1 }
        let empty = try publisher.publish(.init(), to: directory, force: true, at: now) { reloads += 1 }
        #expect(!empty)
        var sample = real; sample.isSample = true
        #expect(throws: CocoaError.self) {
            try publisher.publish(sample, to: directory, force: true, at: now) { reloads += 1 }
        }
        #expect(reloads == 1)
        #expect(WidgetSnapshotStore.read(from: directory) == real)
    }

    @Test("A wall-clock rollback cannot freeze publication until the old clock catches up")
    func clockRollback() throws {
        let directory = try container(); defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = WidgetSnapshotPublisher()
        let value = snapshot(at: now)
        var reloads = 0
        try publisher.publish(value, to: directory, at: now) { reloads += 1 }
        let written = try publisher.publish(value, to: directory, at: now.addingTimeInterval(-1)) { reloads += 1 }
        #expect(written)
        #expect(reloads == 2)
    }
}
