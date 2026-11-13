import AppKit
import Combine
import Testing
import ContextOSUsage
@testable import ContextOSApp

@Suite("Work-time observation boundaries", .serialized)
@MainActor
struct WorkTimeControllerTests {
    private final class Clock {
        var tick: UInt64 = 1_000_000_000_000
        var wall = Date(timeIntervalSince1970: 1_794_369_600)
        func advance(_ seconds: UInt64) {
            tick += seconds * 1_000_000_000
            wall = wall.addingTimeInterval(Double(seconds))
        }
    }

    @Test("A checkpoint publishes one coherent update for automatic, IDE and manual measurements")
    func singleCheckpointPublication() {
        let clock = Clock()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: NotificationCenter(), applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 },
                                            uptimeNanoseconds: { clock.tick }, now: { clock.wall })
        defer { controller.reset() }
        controller.startManual(); controller.setForegroundEnabled(true)
        var snapshots: [WidgetTimeSnapshot] = []
        let subscription = controller.$snapshot.dropFirst().sink { snapshots.append($0) }
        defer { subscription.cancel() }
        clock.advance(10); controller.capture()
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.manualNanoseconds == 10_000_000_000)
        #expect(snapshots.first?.foregroundNanoseconds == 10_000_000_000)
        #expect(snapshots.first?.activity?.estimatedNanoseconds == 10_000_000_000)
        #expect(snapshots.first?.generatedAt == clock.wall)
        #expect(snapshots.first?.activity?.generatedAt == clock.wall)
    }

    @Test("Turning observation off and back on excludes the entire off interval")
    func reenableWithoutBackfill() {
        let clock = Clock()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: NotificationCenter(), applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 },
                                            uptimeNanoseconds: { clock.tick }, now: { clock.wall })
        defer { controller.reset() }
        controller.setForegroundEnabled(true)
        clock.advance(10); controller.capture()
        controller.setForegroundEnabled(false)
        clock.advance(3600); controller.capture(); controller.refreshActivity()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 10_000_000_000)
        #expect(controller.snapshot.foregroundNanoseconds == 10_000_000_000)
        controller.setForegroundEnabled(true)
        #expect(controller.estimatedActivity.estimatedNanoseconds == 10_000_000_000)
        clock.advance(5); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 15_000_000_000)
        #expect(controller.snapshot.foregroundNanoseconds == 15_000_000_000)
    }

    @Test("Automatic development observation defaults on and preserves an explicit off choice")
    func defaultOnAndExplicitPreference() throws {
        let name = "ContextOS.AutomaticTimeTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        func makeController() -> WorkTimeController {
            WorkTimeController(workspaceNotifications: NotificationCenter(), distributedNotifications: NotificationCenter(),
                               applicationNotifications: NotificationCenter(),
                               frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 },
                               preferences: preferences)
        }
        let fresh = makeController()
        defer { fresh.reset() }
        #expect(fresh.foregroundEnabled)
        #expect(fresh.estimatedActivity.phase == .active)
        fresh.setForegroundEnabled(false)
        #expect(preferences.object(forKey: "contextos.foregroundIDEObservationEnabled") as? Bool == false)
        let disabled = makeController()
        defer { disabled.reset() }
        #expect(!disabled.foregroundEnabled)
        #expect(disabled.estimatedActivity.estimatedNanoseconds == nil)
        fresh.setForegroundEnabled(true)
        let restored = makeController()
        defer { restored.reset() }
        #expect(restored.foregroundEnabled)
    }

    @Test("A clock or missed observation gap restarts from now without switching the preference off")
    func recoversClockGaps() {
        let clock = Clock()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: NotificationCenter(), applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 },
                                            uptimeNanoseconds: { clock.tick }, now: { clock.wall })
        defer { controller.reset() }
        controller.setForegroundEnabled(true)
        clock.advance(10); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 10_000_000_000)
        clock.wall = clock.wall.addingTimeInterval(3600)
        controller.capture()
        #expect(controller.foregroundEnabled)
        #expect(controller.estimatedActivity.estimatedNanoseconds == 10_000_000_000)
        #expect(controller.estimatedActivity.phase == .active)
        clock.advance(5); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 15_000_000_000)
        clock.tick -= 60_000_000_000
        controller.capture()
        #expect(controller.foregroundEnabled)
        #expect(controller.estimatedActivity.estimatedNanoseconds == 15_000_000_000)
        clock.advance(3); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 18_000_000_000)
    }

    @Test("All overlapping suspension reasons must clear; their complete elapsed time is excluded")
    func overlappingSleepAndLock() {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), clock = Clock()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: workspace,
                                            distributedNotifications: distributed, applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 },
                                            uptimeNanoseconds: { clock.tick }, now: { clock.wall })
        defer { controller.reset() }
        controller.setForegroundEnabled(true)
        clock.advance(10); controller.capture()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        clock.advance(3600)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        controller.refreshActivity(); controller.capture()
        #expect(controller.foregroundEnabled)
        #expect(controller.estimatedActivity.phase == .paused)
        #expect(controller.editorLabel == nil)
        #expect(controller.estimatedActivity.estimatedNanoseconds == 10_000_000_000)
        clock.advance(60)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(controller.estimatedActivity.phase == .active)
        #expect(controller.estimatedActivity.estimatedNanoseconds == 10_000_000_000)
        clock.advance(5); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 15_000_000_000)
        // Duplicate recovery notifications must not reset an active interval.
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        clock.advance(5); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 20_000_000_000)
    }

    @Test("An explicit off choice during suspension prevents automatic resumption")
    func offWhileLocked() {
        let distributed = NotificationCenter(), clock = Clock()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: distributed, applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 },
                                            uptimeNanoseconds: { clock.tick }, now: { clock.wall })
        defer { controller.reset() }
        controller.setForegroundEnabled(true)
        clock.advance(5); controller.capture()
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        clock.advance(1800)
        controller.setForegroundEnabled(false)
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        clock.advance(10); controller.refreshActivity(); controller.capture()
        #expect(!controller.foregroundEnabled)
        #expect(controller.estimatedActivity.phase == .paused)
        #expect(controller.estimatedActivity.estimatedNanoseconds == 5_000_000_000)
    }

    @Test("Starting while locked remains paused until both lock and display state recover")
    func initiallyLocked() {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), clock = Clock()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: workspace,
                                            distributedNotifications: distributed, applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 },
                                            uptimeNanoseconds: { clock.tick }, now: { clock.wall },
                                            initialSuspensions: [.screenLock, .displaySleep])
        defer { controller.reset() }
        controller.setForegroundEnabled(true)
        clock.advance(1800); controller.refreshActivity()
        #expect(controller.foregroundEnabled)
        #expect(controller.estimatedActivity.estimatedNanoseconds == nil)
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        #expect(controller.estimatedActivity.estimatedNanoseconds == nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(controller.estimatedActivity.phase == .active)
        #expect(controller.estimatedActivity.estimatedNanoseconds == 0)
        clock.advance(5); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 5_000_000_000)
    }

    @Test("IDE activity works without a VS Code extension and stops on idle, switching or opt-out")
    func nativeDailyActivity() throws {
        let workspace = NotificationCenter()
        var frontmost = "com.apple.Safari"
        var idle: TimeInterval = 0
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: workspace,
                                            distributedNotifications: NotificationCenter(), applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { frontmost }, secondsSinceLastInput: { idle })
        defer { controller.reset() }
        controller.setForegroundEnabled(true)
        #expect(!controller.bridgeEnabled)
        #expect(controller.estimatedActivity.estimatedNanoseconds == nil)
        #expect(controller.activityStatus == "지원 IDE 활동 대기 · 미관측")

        frontmost = "com.jetbrains.intellij"
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(controller.estimatedActivity.phase == .active)
        controller.refreshActivity()
        #expect(try #require(controller.estimatedActivity.estimatedNanoseconds) > 0)
        #expect(controller.snapshot.activity == controller.estimatedActivity)

        idle = 301
        controller.refreshActivity()
        #expect(controller.estimatedActivity.phase == .paused)
        let afterIdle = controller.estimatedActivity.estimatedNanoseconds
        controller.refreshActivity()
        #expect(controller.estimatedActivity.estimatedNanoseconds == afterIdle)

        idle = 0
        controller.refreshActivity()
        #expect(controller.estimatedActivity.phase == .active)
        frontmost = "com.apple.Safari"
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(controller.estimatedActivity.phase == .paused)
        let afterSwitch = controller.estimatedActivity.estimatedNanoseconds
        controller.refreshActivity()
        #expect(controller.estimatedActivity.estimatedNanoseconds == afterSwitch)

        controller.setForegroundEnabled(false)
        frontmost = "com.jetbrains.pycharm"
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        controller.refreshActivity()
        #expect(controller.estimatedActivity.phase == .paused)
        #expect(controller.estimatedActivity.estimatedNanoseconds == afterSwitch)
    }

    @Test("An already idle IDE does not invent an observed zero or activity")
    func nativeIdleAtStart() {
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: NotificationCenter(), applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { "com.jetbrains.pycharm" }, secondsSinceLastInput: { 500 })
        defer { controller.reset() }
        controller.setForegroundEnabled(true)
        controller.refreshActivity()
        #expect(controller.estimatedActivity.estimatedNanoseconds == nil)
        #expect(controller.estimatedActivity.phase == .notObserved)
        #expect(!controller.activityStatus.contains("연결 필요"))
    }

    @Test("Daily activity keeps the IDE choice across a calendar or time-zone boundary")
    func nativeCalendarBoundary() {
        let application = NotificationCenter()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: NotificationCenter(), applicationNotifications: application,
                                            frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 })
        defer { controller.reset() }
        controller.setForegroundEnabled(true)
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            application.post(name: name, object: nil)
            #expect(controller.foregroundEnabled)
            #expect(controller.estimatedActivity.phase == .active)
            #expect(controller.snapshot.activity == controller.estimatedActivity)
        }
    }

    @Test("Termination freezes automatic activity before releasing observation")
    func nativeTermination() {
        let application = NotificationCenter()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: NotificationCenter(), applicationNotifications: application,
                                            frontmostBundleIdentifier: { "com.jetbrains.intellij" }, secondsSinceLastInput: { 0 })
        controller.setForegroundEnabled(true)
        application.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(controller.foregroundEnabled)
        #expect(controller.estimatedActivity.phase == .paused)
        let final = controller.estimatedActivity.estimatedNanoseconds
        controller.refreshActivity()
        #expect(controller.estimatedActivity.estimatedNanoseconds == final)
    }

    @Test("IDE editions are discovered once per product and helpers are excluded")
    func detectsIDEEditions() {
        let installed = ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm.ce-EAP",
                         "com.jetbrains.WebStorm", "com.jetbrains.toolbox", "com.jetbrains.pycharm.helper"]
        #expect(ForegroundEditors.installedNames(isInstalled: installed.contains) == ["IntelliJ IDEA", "PyCharm", "WebStorm"])
        #expect(ForegroundEditors.label(for: "com.jetbrains.intellij-EAP") == "IntelliJ IDEA")
        #expect(ForegroundEditors.label(for: "com.jetbrains.pycharm.ce-EAP") == "PyCharm")
        #expect(ForegroundEditors.label(for: "com.jetbrains.webstorm") == "WebStorm")
        #expect(ForegroundEditors.label(for: "com.jetbrains.toolbox") == nil)
        #expect(ForegroundEditors.label(for: "com.jetbrains.pycharm.helper") == nil)
    }

    @Test("IDE activation counts only one foreground interval and ignores background time")
    func tracksOnlyFrontmostIDE() throws {
        let workspace = NotificationCenter()
        var frontmost = "com.jetbrains.pycharm"
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: workspace,
                                            distributedNotifications: NotificationCenter(), applicationNotifications: NotificationCenter(),
                                            frontmostBundleIdentifier: { frontmost })
        func activate(_ bundleID: String) {
            frontmost = bundleID
            workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        controller.setForegroundEnabled(true)
        #expect(controller.editorLabel == "PyCharm")
        #expect(controller.editorNanoseconds.isEmpty)
        activate("com.jetbrains.pycharm.ce-EAP")
        #expect(controller.editorNanoseconds.keys.sorted() == ["PyCharm"])
        activate("com.jetbrains.intellij.ce")
        #expect(controller.editorLabel == "IntelliJ IDEA")
        #expect(controller.snapshot.foregroundState == .running)
        let pyCharmTime = try #require(controller.editorNanoseconds["PyCharm"])
        #expect(controller.snapshot.foregroundNanoseconds == pyCharmTime)
        #expect(controller.editorNanoseconds["IntelliJ IDEA"] == nil)
        activate("com.apple.Safari")
        let total = try #require(controller.snapshot.foregroundNanoseconds)
        let ideaTime = try #require(controller.editorNanoseconds["IntelliJ IDEA"])
        #expect(ideaTime > 0)
        #expect(controller.editorNanoseconds["PyCharm"] == pyCharmTime)
        #expect(total == pyCharmTime + ideaTime)
        #expect(total <= DispatchTime.now().uptimeNanoseconds - start)
        #expect(controller.editorLabel == nil)
        #expect(controller.snapshot.foregroundState == .waitingForEditor)
        controller.capture()
        #expect(controller.snapshot.foregroundNanoseconds == total)
        #expect(controller.editorNanoseconds == ["PyCharm": pyCharmTime, "IntelliJ IDEA": ideaTime])

        activate("com.microsoft.VSCode")
        #expect(controller.editorLabel == "VS Code")
        controller.setForegroundEnabled(false)
        #expect(controller.snapshot.foregroundState == .paused)
        let pausedTotal = controller.snapshot.foregroundNanoseconds
        let pausedEditors = controller.editorNanoseconds
        #expect(pausedTotal == pausedEditors.values.reduce(0, +))
        activate("com.jetbrains.pycharm")
        #expect(controller.editorLabel == nil)
        #expect(controller.snapshot.foregroundNanoseconds == pausedTotal)
        #expect(controller.editorNanoseconds == pausedEditors)
    }

    @Test("Locking pauses observation without disabling it and unlock resumes without counting the gap")
    func screenLockStopsObservation() {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), application = NotificationCenter()
        let clock = Clock()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: workspace,
                                            distributedNotifications: distributed, applicationNotifications: application,
                                            frontmostBundleIdentifier: { "com.jetbrains.pycharm" }, secondsSinceLastInput: { 0 },
                                            uptimeNanoseconds: { clock.tick }, now: { clock.wall })
        controller.startManual()
        controller.setForegroundEnabled(true)
        clock.advance(10)
        controller.capture()
        let before = controller.snapshot.manualNanoseconds
        let foregroundBefore = controller.snapshot.foregroundNanoseconds
        let activityBefore = controller.estimatedActivity.estimatedNanoseconds
        #expect(controller.manualRunning)
        #expect(controller.editorLabel == "PyCharm")
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(!controller.manualRunning && controller.foregroundEnabled)
        #expect(controller.boundaryReason == "화면 잠금")
        #expect(controller.snapshot.manualState == .partial)
        #expect(controller.snapshot.manualNanoseconds == before)
        #expect(controller.editorLabel == nil)

        clock.advance(3600)
        controller.refreshActivity(); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == activityBefore)
        #expect(controller.activityStatus == "잠금·절전 중 · 자동 재개 대기")
        // Resume starts a fresh interval. The manual timer remains paused.
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        controller.capture()
        #expect(!controller.manualRunning)
        #expect(controller.snapshot.manualNanoseconds == before)
        #expect(controller.snapshot.foregroundNanoseconds == foregroundBefore)
        #expect(controller.editorNanoseconds["PyCharm"] == foregroundBefore)
        #expect(controller.snapshot.foregroundState == .partial)
        #expect(controller.foregroundEnabled)
        #expect(controller.estimatedActivity.estimatedNanoseconds == activityBefore)
        #expect(controller.estimatedActivity.phase == .active)
        clock.advance(5); controller.capture()
        #expect(controller.estimatedActivity.estimatedNanoseconds == 15_000_000_000)
        #expect(controller.snapshot.manualNanoseconds == before)

        controller.reset()
        #expect(controller.editorNanoseconds.isEmpty)
        #expect(controller.snapshot.foregroundNanoseconds == nil)
    }

    @Test("Boundaries can be removed and registered again for an explicit new timer")
    func restartAfterLock() {
        let distributed = NotificationCenter()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: distributed, applicationNotifications: NotificationCenter())
        controller.startManual()
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(!controller.manualRunning)
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        controller.startManual()
        #expect(controller.manualRunning && controller.boundaryReason == nil)
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(!controller.manualRunning)
        #expect(controller.boundaryReason == "화면 잠금")
    }

    @Test("Pausing a timer detaches idle observation and preserves its state on later boundaries")
    func pausedTimerIsNotInterrupted() {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), application = NotificationCenter()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: workspace,
                                            distributedNotifications: distributed, applicationNotifications: application)
        controller.startManual()
        controller.pauseManual()
        let paused = controller.snapshot
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        application.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(controller.boundaryReason == nil)
        #expect(controller.snapshot == paused)
        #expect(controller.snapshot.manualState == .paused)
    }
}
