import AppKit
import Combine
import ContextOSUsage

/// Opt-in AppKit metadata observation. Never reads a title, document, keystroke
/// or path. Values are this process's observation epoch, not "coding time".
@MainActor
final class WorkTimeController: ObservableObject {
    static let shared = WorkTimeController()
    @Published private(set) var snapshot = WidgetTimeSnapshot()
    @Published private(set) var manualRunning = false
    @Published private(set) var foregroundEnabled = false
    @Published private(set) var editorLabel: String?
    @Published private(set) var boundaryReason: String?
    @Published var smallMetric: SmallWidgetMetric = SmallWidgetMetric(rawValue: UserDefaults.standard.string(forKey: "contextos.smallWidgetMetric") ?? "") ?? .tokens {
        didSet { UserDefaults.standard.set(smallMetric.rawValue, forKey: "contextos.smallWidgetMetric") }
    }
    @Published private(set) var revision: UInt64 = 0
    private(set) var lastPublishTick: UInt64 = 0
    private var drawSamples: [Double] = []
    private var ledger = MeasuredTimeLedger()
    private var foregroundActive = false
    private var uiVisible = false
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var boundaries: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var lastWall = Date()
    private var interrupted = false
    private let workspace = NSWorkspace.shared

    private static let editors = ["com.apple.dt.Xcode": "Xcode", "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders", "com.todesktop.230313mzl4w4u92": "Cursor"]

    func setUIVisible(_ visible: Bool) { uiVisible = visible; capture(); schedule() }

    func startManual() {
        guard !manualRunning else { return }
        prepareEpochPoint(); interrupted = false; boundaryReason = nil
        ledger.begin(.manualTimer, id: "manual", at: DispatchTime.now().uptimeNanoseconds)
        manualRunning = true; ensureBoundaries(); capture(); schedule()
    }
    func pauseManual() {
        guard manualRunning else { return }
        capture()
        ledger.end(.manualTimer, id: "manual", at: DispatchTime.now().uptimeNanoseconds)
        manualRunning = false; publish(); schedule(); releaseUnusedBoundaries()
    }
    func setForegroundEnabled(_ enabled: Bool) {
        guard enabled != foregroundEnabled else { return }
        capture(); foregroundEnabled = enabled; interrupted = false; boundaryReason = nil
        if enabled {
            prepareEpochPoint(); ensureBoundaries()
            activationObserver = workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.reconcileForeground() }
                }
            reconcileForeground()
        } else {
            if foregroundActive { ledger.end(.editorForeground, id: "foreground", at: DispatchTime.now().uptimeNanoseconds) }
            foregroundActive = false; editorLabel = nil
            if let activationObserver { workspace.notificationCenter.removeObserver(activationObserver) }
            activationObserver = nil; publish(); schedule(); releaseUnusedBoundaries()
        }
    }
    private func reconcileForeground() {
        capture()
        guard foregroundEnabled else { return }
        let label = workspace.frontmostApplication?.bundleIdentifier.flatMap { Self.editors[$0] }
        if label != editorLabel {
            if foregroundActive { ledger.end(.editorForeground, id: "foreground", at: DispatchTime.now().uptimeNanoseconds) }
            foregroundActive = false; editorLabel = label
            if label != nil {
                prepareEpochPoint()
                ledger.begin(.editorForeground, id: "foreground", at: DispatchTime.now().uptimeNanoseconds)
                foregroundActive = true
            }
        }
        publish(); schedule()
    }
    private func prepareEpochPoint() {
        if ledger.activeCount == 0 { lastTick = DispatchTime.now().uptimeNanoseconds; lastWall = Date() }
    }
    func capture() {
        let tick = DispatchTime.now().uptimeNanoseconds, wall = Date()
        if ledger.activeCount > 0 {
            guard tick >= lastTick,
                  abs(wall.timeIntervalSince(lastWall) - Double(tick - lastTick) / 1_000_000_000) < 2 else {
                interrupt("시계 또는 관측 공백"); return
            }
            if manualRunning {
                ledger.end(.manualTimer, id: "manual", at: tick)
                ledger.begin(.manualTimer, id: "manual", at: tick)
            }
            if foregroundActive {
                ledger.end(.editorForeground, id: "foreground", at: tick)
                ledger.begin(.editorForeground, id: "foreground", at: tick)
            }
        }
        lastTick = tick; lastWall = wall; publish()
    }
    private func publish() {
        lastPublishTick = DispatchTime.now().uptimeNanoseconds
        let manual = ledger.value(for: .manualTimer), foreground = ledger.value(for: .editorForeground)
        snapshot = WidgetTimeSnapshot(manualNanoseconds: manual.nanoseconds, foregroundNanoseconds: foreground.nanoseconds,
            manualState: manual.partial ? .partial : manualRunning ? .running : interrupted ? .interrupted : manual.nanoseconds == nil ? .notObserved : .paused,
            foregroundState: foreground.partial ? .partial : foregroundActive ? .running : foregroundEnabled ? .waitingForEditor : interrupted ? .interrupted : foreground.nanoseconds == nil ? .notObserved : .paused)
        revision &+= 1
    }
    func recordDraw(from tick: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard tick > 0, now >= tick else { return }
        drawSamples.append(Double(now - tick) / 1_000_000)
        if drawSamples.count > 32 { drawSamples.removeFirst() }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--time-ui-probe-dir"), args.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        var values: [String: Any] = ["scope":"capture-to-AppKit-draw callback; not physical display latency",
            "draw_ms":drawSamples,"manual_state":snapshot.manualState.rawValue,
            "foreground_state":snapshot.foregroundState.rawValue]
        if let manual = snapshot.manualNanoseconds { values["manual_ns"] = manual }
        if let foreground = snapshot.foregroundNanoseconds { values["foreground_ns"] = foreground }
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("time-ui-probe.json"), options: .atomic)
        }
    }
    private func interrupt(_ reason: String) {
        ledger.interrupt(); manualRunning = false; foregroundActive = false; foregroundEnabled = false
        editorLabel = nil; interrupted = true; boundaryReason = reason
        if let activationObserver { workspace.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil; timer?.invalidate(); timer = nil
        publish(); releaseUnusedBoundaries()
    }
    func reset() {
        interrupt("초기화"); ledger = MeasuredTimeLedger(); interrupted = false; boundaryReason = nil
        lastTick = DispatchTime.now().uptimeNanoseconds; lastWall = Date(); publish()
    }
    private func ensureBoundaries() {
        guard boundaries.isEmpty else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace.notificationCenter, name, "절전 또는 세션 비활성")
        }
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observe(.default, name, "일자 또는 시간대 변경")
        }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt(reason) }
        }
        boundaries.append((center, token))
    }
    private func releaseUnusedBoundaries() {
        guard !manualRunning && !foregroundEnabled else { return }
        for (center, token) in boundaries { center.removeObserver(token) }
        boundaries.removeAll()
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard manualRunning || foregroundActive else { return }
        let interval: TimeInterval = uiVisible ? 1 : 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        timer?.tolerance = uiVisible ? 0.1 : 6
    }
}
