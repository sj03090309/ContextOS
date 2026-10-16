import AppKit
import Darwin
import Combine
import ContextOSUsage
import ContextOSCore

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
    @Published var showWidgetMascot = UserDefaults.standard.object(forKey: "contextos.showWidgetMascot") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showWidgetMascot, forKey: "contextos.showWidgetMascot") }
    }
    @Published var smallMetric: SmallWidgetMetric = SmallWidgetMetric(rawValue: UserDefaults.standard.string(forKey: "contextos.smallWidgetMetric") ?? "") ?? .tokens {
        didSet { UserDefaults.standard.set(smallMetric.rawValue, forKey: "contextos.smallWidgetMetric") }
    }
    @Published private(set) var aiExecution: AIExecutionSummary?
    @Published private(set) var bridgeEnabled = false
    @Published private(set) var bridgeStatus = "확장 미연결"
    @Published private(set) var bridgeEditCount: UInt64?
    @Published private(set) var bridgeFocused: Bool?
    @Published private(set) var estimatedActivity = EstimatedActivitySnapshot()
    @Published private(set) var activityStoreStatus: String?
    private var activityLedger = EstimatedActivityLedger()
    private var activityTimer: Timer?
    private var lastActivityStore = Date.distantPast
    private var lastActivityPhase = EstimatedActivitySnapshot.Phase.notObserved
    private var receiverLease = ObservationReceiverLease()
    private var activityFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextOS/Activity/activity-day-v1.json")
    }
    private func activityPoint(_ body: (inout EstimatedActivityLedger, UInt64, Date) -> Void) {
        let wall = Date(), tick = DispatchTime.now().uptimeNanoseconds
        body(&activityLedger, tick, wall)
        publishActivity()
    }
    private func publishActivity() {
        estimatedActivity = activityLedger.snapshot
        publish() // One snapshot shared by dashboard, widget writer and editor clients.
        bridgeServer?.publish(estimatedActivity)
        if bridgeEnabled && receiverLease.isReady && (Date().timeIntervalSince(lastActivityStore) >= 60 || lastActivityPhase != estimatedActivity.phase) {
            do { try EstimatedActivityStore.write(estimatedActivity, to: activityFile); lastActivityStore = Date(); activityStoreStatus = nil }
            catch { activityStoreStatus = "오늘 집계 저장 실패 · 메모리 값만 표시" }
        }
        lastActivityPhase = estimatedActivity.phase
        activityTimer?.invalidate(); activityTimer = nil
        if bridgeEnabled && receiverLease.isReady && estimatedActivity.phase == .active {
            activityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.activityPoint { ledger, tick, wall in ledger.advance(tick: tick, wall: wall, timeZone: .current) } }
            }
            activityTimer?.tolerance = 0.1
        }
    }
    private func suspendAutomaticActivity() {
        activityPoint { ledger, tick, wall in ledger.interrupt(tick: tick, wall: wall, timeZone: .current) }
    }
    private var bridgeLedgers: [String: ObservationBridgeLedger] = [:]
    private var closedEditCount: UInt64?
    private var bridgeServer: ObservationBridgeServer?
    init() {
        // Only a prior explicit host opt-in restores receiver startup. Fresh
        // candidates remain off; never infer consent from an installed VSIX.
        if UserDefaults.standard.bool(forKey: "contextos.automaticActivityReceiverEnabled") {
            Task { @MainActor [weak self] in self?.setBridgeEnabled(true) }
        }
    }
    func updateAIExecution(_ value: AIExecutionSummary) { aiExecution = value }
    func setBridgeEnabled(_ enabled: Bool) {
        guard !enabled || Bundle.main.bundleIdentifier == "com.contextos.app" else {
            bridgeStatus = "테스트 앱 · 자동 활동 연결은 운영 앱에서 켜세요"; return
        }
        guard enabled != bridgeEnabled else { return }
        let ownedPersistence = receiverLease.isReady
        let generation = receiverLease.begin()
        bridgeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "contextos.automaticActivityReceiverEnabled")
        if enabled {
            ensureBoundaries()
            bridgeStatus = "로컬 수신 준비 중"
            let server = ObservationBridgeServer { [weak self] event in
                Task { @MainActor in
                    guard let self, self.bridgeEnabled, self.receiverLease.accepts(generation) else { return }
                    switch event {
                    case .ready:
                        do {
                            let directory = self.activityFile.deletingLastPathComponent()
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            var status = stat()
                            guard lstat(directory.path, &status) == 0, status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFDIR, status.st_mode & 0o077 == 0 else { throw BridgeError.unsafeLocation }
                            let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextOS Observation Candidate/activity-day-v1.json")
                            try EstimatedActivityStore.importLegacyIfAbsent(from: legacy, to: self.activityFile, now: Date(), timeZone: .current)
                            if let stored = try EstimatedActivityStore.read(from: self.activityFile) { self.activityLedger.restore(stored, now: Date(), timeZone: .current) }
                            self.receiverLease.ready(generation)
                            self.estimatedActivity = self.activityLedger.snapshot; self.publish()
                            self.bridgeStatus = "로컬 수신 대기 · VS Code 확장 연결 필요"
                        } catch {
                            self.receiverLease.invalidate(); self.bridgeEnabled = false
                            self.bridgeStatus = "활동 저장 준비 실패 · 기존 기록 보존"
                            self.bridgeServer?.stop(); self.bridgeServer = nil; self.releaseUnusedBoundaries()
                        }
                    case .packet(let packet):
                        guard self.receiverLease.isReady else { return }
                        if packet.version == 2 {
                            let signal: EstimatedActivitySignal
                            switch packet.kind {
                            case .focus: signal = .focus(packet.focused == true)
                            case .edits, .activity: signal = .activity(focused: packet.focused == true)
                            case .heartbeat: signal = .heartbeat
                            case .gap: signal = .gap
                            }
                            self.activityPoint { ledger, tick, wall in ledger.receive(id: packet.nonce, sequence: packet.sequence, signal: signal, tick: tick, wall: wall, timeZone: .current) }
                        }
                        var counter = self.bridgeLedgers[packet.nonce] ?? ObservationBridgeLedger()
                        counter.consume(packet); self.bridgeLedgers[packet.nonce] = counter
                        let counts = self.bridgeLedgers.values.compactMap(\.editCount) + (self.closedEditCount.map { [$0] } ?? [])
                        self.bridgeEditCount = counts.isEmpty ? nil : counts.reduce(0) { sum, value in let (n,o) = sum.addingReportingOverflow(value); return o ? .max : n }
                        self.bridgeFocused = self.bridgeLedgers.values.contains { $0.focused == true }
                        self.bridgeStatus = packet.version == 1 ? "구형 확장 · 자동 활동 미지원" : "연결됨 · 자동 활동 추정"
                    case .disconnected(let nonce):
                        if let nonce { self.activityPoint { ledger, tick, wall in ledger.disconnect(id: nonce, tick: tick, wall: wall, timeZone: .current) } }
                        if let nonce, let closed = self.bridgeLedgers.removeValue(forKey: nonce)?.editCount {
                            let (n,o) = (self.closedEditCount ?? 0).addingReportingOverflow(closed); self.closedEditCount = o ? .max : n
                        }
                        self.bridgeFocused = nil; self.bridgeStatus = "일부 연결 끊김 · 마지막 집계 유지"
                    case .failed:
                        self.receiverLease.invalidate()
                        self.bridgeStatus = "수신 시작 실패 · 기존 경로 보존"; self.bridgeEnabled = false
                        self.bridgeServer = nil; self.releaseUnusedBoundaries()
                    }
                }
            }
            bridgeServer = server
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextOS Observation Candidate", isDirectory: true)
            server.start(directory: directory)
        } else {
            activityPoint { ledger, tick, wall in ledger.disconnect(id: nil, tick: tick, wall: wall, timeZone: .current) }
            if ownedPersistence { try? EstimatedActivityStore.write(estimatedActivity, to: activityFile) }
            activityTimer?.invalidate(); activityTimer = nil
            bridgeServer?.stop(); bridgeServer = nil; closedEditCount = bridgeEditCount; bridgeLedgers.removeAll()
            bridgeFocused = nil; bridgeStatus = "수신 꺼짐 · 관측 중지"; releaseUnusedBoundaries()
        }
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
            foregroundState: foreground.partial ? .partial : foregroundActive ? .running : foregroundEnabled ? .waitingForEditor : interrupted ? .interrupted : foreground.nanoseconds == nil ? .notObserved : .paused,
            activity: estimatedActivity)
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
        suspendAutomaticActivity()
        editorLabel = nil; interrupted = true; boundaryReason = reason
        if let activationObserver { workspace.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil; timer?.invalidate(); timer = nil
        publish(); releaseUnusedBoundaries()
    }
    func reset() {
        interrupt("초기화"); setBridgeEnabled(false); bridgeLedgers.removeAll(); closedEditCount = nil; bridgeEditCount = nil
        ledger = MeasuredTimeLedger(); interrupted = false; boundaryReason = nil
        lastTick = DispatchTime.now().uptimeNanoseconds; lastWall = Date(); publish()
    }
    private func ensureBoundaries() {
        guard boundaries.isEmpty else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace.notificationCenter, name, "절전 또는 세션 비활성")
        }
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged, NSApplication.willTerminateNotification] {
            observe(.default, name, "일자 또는 시간대 변경")
        }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if name == NSApplication.willTerminateNotification {
                    if let self, self.bridgeEnabled { try? EstimatedActivityStore.write(self.estimatedActivity, to: self.activityFile) }
                    self?.bridgeServer?.stopSynchronously()
                }
                self?.interrupt(reason)
            }
        }
        boundaries.append((center, token))
    }
    private func releaseUnusedBoundaries() {
        guard !manualRunning && !foregroundEnabled && !bridgeEnabled else { return }
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
