import Foundation
import ContextOSUsage

/// Coalesces ordinary counters while publishing user actions and observation
/// boundaries immediately. State advances only after the shared file is saved.
@MainActor
final class WidgetSnapshotPublisher {
    private var lastPublished: WidgetUsageSnapshot?
    private var lastWrite = Date.distantPast
    private var lastReload = Date.distantPast
    private var pendingPreferenceReload = false

    @discardableResult
    func publish(_ snapshot: WidgetUsageSnapshot, to container: URL, force: Bool = false,
                 preferenceChange: Bool = false,
                 at now: Date = Date(), reload: () -> Void) throws -> Bool {
        // An empty startup placeholder must never replace a real aggregate.
        guard !snapshot.providers.isEmpty else { return false }
        let boundary = lastPublished.map { previous in
            previous.timeZoneID != snapshot.timeZoneID
                || previous.days.last?.date != snapshot.days.last?.date
                || previous.stale(at: now) != snapshot.stale(at: now)
                || Self.collectionStatus(previous) != Self.collectionStatus(snapshot)
                || previous.smallMetric != snapshot.smallMetric
                || previous.showMascot != snapshot.showMascot
                || previous.timing?.manualState != snapshot.timing?.manualState
                || previous.timing?.foregroundState != snapshot.timing?.foregroundState
                || previous.timing?.activity?.phase != snapshot.timing?.activity?.phase
        } ?? true
        let writeElapsed = now.timeIntervalSince(lastWrite)
        guard force || preferenceChange || boundary || writeElapsed >= 60 || writeElapsed < 0 else { return false }

        try WidgetSnapshotStore.write(snapshot, to: container)
        lastPublished = snapshot
        lastWrite = now
        if preferenceChange { pendingPreferenceReload = true }
        let reloadElapsed = now.timeIntervalSince(lastReload)
        if force || preferenceChange || boundary || reloadElapsed >= 15 * 60 || reloadElapsed < 0 {
            reload()
            lastReload = now
        }
        return true
    }

    /// WidgetKit may defer requests while the settings app is in front. Ask
    /// once more when the user leaves, after the final preference is on disk.
    /// Ordinary counters and subsequent focus changes never queue this retry.
    func finishPreferenceChanges(at now: Date = Date(), reload: () -> Void) {
        guard pendingPreferenceReload else { return }
        pendingPreferenceReload = false
        reload()
        lastReload = now
    }

    private static func collectionStatus(_ snapshot: WidgetUsageSnapshot) -> [UsageProvider] {
        // A new log timestamp alone is an ordinary counter update, not a
        // connection or collection-state transition.
        snapshot.providers.map { provider in
            var status = provider
            status.latestEvent = nil
            return status
        }
    }
}
