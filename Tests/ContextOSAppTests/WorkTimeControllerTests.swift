import AppKit
import Testing
import ContextOSUsage
@testable import ContextOSApp

@Suite("Work-time observation boundaries", .serialized)
@MainActor
struct WorkTimeControllerTests {
    @Test("Locking an awake display stops the timer and foreground opt-in without losing verified time")
    func screenLockStopsObservation() {
        let workspace = NotificationCenter(), distributed = NotificationCenter(), application = NotificationCenter()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: workspace,
                                            distributedNotifications: distributed, applicationNotifications: application)
        controller.startManual()
        let before = controller.snapshot.manualNanoseconds
        #expect(controller.manualRunning)
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(!controller.manualRunning && !controller.foregroundEnabled)
        #expect(controller.boundaryReason == "화면 잠금")
        #expect(controller.snapshot.manualState == .partial)
        #expect(controller.snapshot.manualNanoseconds == before)
        #expect(controller.editorLabel == nil)

        // Unlocking is a boundary, not permission to invent resumed intervals.
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        controller.capture()
        #expect(!controller.manualRunning)
        #expect(controller.snapshot.manualNanoseconds == before)
    }

    @Test("Boundaries can be removed and registered again for an explicit new timer")
    func restartAfterLock() {
        let distributed = NotificationCenter()
        let controller = WorkTimeController(restoreConnections: false, workspaceNotifications: NotificationCenter(),
                                            distributedNotifications: distributed, applicationNotifications: NotificationCenter())
        controller.startManual()
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(!controller.manualRunning)
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
