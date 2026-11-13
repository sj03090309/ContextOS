import AppKit
import CoreGraphics
import Darwin
import Combine
import ContextOSUsage
import ContextOSCore

/// Automatic development-activity estimation from AppKit/idle metadata.
/// Never reads titles, documents, keystrokes or paths.
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
    private var lastActivityStore = Date.distantPast
    private var lastActivityPhase = EstimatedActivitySnapshot.Phase.notObserved
    private var receiverLease = ObservationReceiverLease()
    private var nativeSequence: Int64 = 0
    private let nativeSource = "macos-foreground-ide"
    enum SuspensionReason: Hashable { case systemSleep, displaySleep, screenLock, inactiveSession }
    private var suspensionReasons: Set<SuspensionReason> = []
    private var terminating = false
    private var automaticActivityRequested: Bool { foregroundEnabled && !terminating }
    private var observationSuspended: Bool { !suspensionReasons.isEmpty || terminating }
    private var isProductionApp: Bool { Bundle.main.bundleIdentifier == "com.contextos.app" }
    private static func currentSystemSuspensions() -> Set<SuspensionReason> {
        var reasons: Set<SuspensionReason> = []
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { reasons.insert(.screenLock) }
        if session?[kCGSessionOnConsoleKey as String] as? Bool == false { reasons.insert(.inactiveSession) }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { reasons.insert(.displaySleep) }
        return reasons
    }
    var activityStatus: String {
        if !automaticActivityRequested { return "자동 관측 꺼짐 · 미관측" }
        if observationSuspended { return "잠금·절전 중 · 자동 재개 대기" }
        if let activityStoreStatus { return activityStoreStatus }
        if estimatedActivity.phase != .notObserved { return estimatedActivity.label }
        return "지원 IDE 활동 대기 · 미관측"
    }
    /// Short report status; collection diagnostics stay in settings and help.
    var developmentTimeStatus: String {
        if !automaticActivityRequested { return "자동 기록 꺼짐" }
        if observationSuspended { return "기록 일시정지" }
        if activityStoreStatus != nil { return "기록 저장 확인 필요" }
        switch estimatedActivity.phase {
        case .active: return "기록 중"
        case .paused: return "작업 대기 중"
        case .notObserved: return "IDE에서 작업을 시작해 보세요"
        }
    }
    private var activityFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextOS/Activity/activity-day-v1.json")
    }
    private func activityPoint(_ body: (inout EstimatedActivityLedger, UInt64, Date) -> Void) {
        let wall = now(), tick = uptimeNanoseconds()
        body(&activityLedger, tick, wall)
        publishActivity()
    }
    private func publishActivity() {
        estimatedActivity = activityLedger.snapshot
        publish() // One snapshot shared by dashboard, widget writer and editor clients.
        if bridgeEnabled { bridgeServer?.publish(estimatedActivity) }
        let wall = now()
        let elapsed = wall.timeIntervalSince(lastActivityStore)
        if automaticActivityRequested && receiverLease.isReady && (elapsed >= 60 || elapsed < 0 || lastActivityPhase != estimatedActivity.phase) {
            do { try EstimatedActivityStore.write(estimatedActivity, to: activityFile); lastActivityStore = wall; activityStoreStatus = nil }
            catch { activityStoreStatus = "오늘 집계 저장 실패 · 메모리 값만 표시" }
        }
        lastActivityPhase = estimatedActivity.phase
        schedule()
    }
    /// Only elapsed time since input is sampled; no event tap or input contents.
    @discardableResult func refreshActivity() -> Bool {
        guard automaticActivityRequested, !observationSuspended,
              !isProductionApp || receiverLease.isReady else { return false }
        let focused = foregroundEnabled && ForegroundEditors.label(for: frontmostBundleIdentifier()) != nil
        let idle = focused ? secondsSinceLastInput() : 0
        nativeSequence += 1
        let sequence = nativeSequence, source = nativeSource
        activityPoint { ledger, tick, wall in
            ledger.receive(id: source, sequence: sequence,
                           signal: .nativeObservation(focused: focused, idleSeconds: idle),
                           tick: tick, wall: wall, timeZone: .current)
        }
        return true
    }
    private func suspendAutomaticActivity() {
        activityPoint { ledger, tick, wall in ledger.interrupt(tick: tick, wall: wall, timeZone: .current) }
    }
    private var bridgeLedgers: [String: ObservationBridgeLedger] = [:]
    private var closedEditCount: UInt64?
    private var bridgeServer: ObservationBridgeServer?
    private let workspaceNotifications: NotificationCenter
    private let distributedNotifications: NotificationCenter
    private let applicationNotifications: NotificationCenter
    private let frontmostBundleIdentifier: () -> String?
    private let secondsSinceLastInput: () -> TimeInterval
    private let preferences: UserDefaults
    private let uptimeNanoseconds: () -> UInt64
    private let now: () -> Date
    private var persistsPreferences: Bool { isProductionApp || preferences !== UserDefaults.standard }
    init(restoreConnections: Bool = true, workspaceNotifications: NotificationCenter? = nil,
         distributedNotifications: NotificationCenter? = nil,
         applicationNotifications: NotificationCenter = .default,
         frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         secondsSinceLastInput: @escaping () -> TimeInterval = {
             CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
         }, preferences: UserDefaults = .standard,
         uptimeNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         now: @escaping () -> Date = Date.init,
         initialSuspensions: Set<SuspensionReason>? = nil) {
        self.workspaceNotifications = workspaceNotifications ?? NSWorkspace.shared.notificationCenter
        self.distributedNotifications = distributedNotifications ?? DistributedNotificationCenter.default()
        self.applicationNotifications = applicationNotifications
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.secondsSinceLastInput = secondsSinceLastInput
        self.preferences = preferences
        self.uptimeNanoseconds = uptimeNanoseconds
        self.now = now
        lastTick = uptimeNanoseconds(); lastWall = now()
        activityLedger = EstimatedActivityLedger(now: now(), timeZone: .current)
        estimatedActivity = activityLedger.snapshot
        if let initialSuspensions { suspensionReasons = initialSuspensions }
        else if restoreConnections && isProductionApp { suspensionReasons = Self.currentSystemSuspensions() }
        guard restoreConnections, isProductionApp || preferences !== UserDefaults.standard else { return }
        // Development observation defaults on; an explicit off choice survives.
        // Extension signals remain a separate, optional preference.
        let restoreBridge = preferences.bool(forKey: "contextos.automaticActivityReceiverEnabled")
        let restoreForeground = preferences.object(forKey: "contextos.foregroundIDEObservationEnabled") as? Bool ?? true
        if restoreBridge { setBridgeEnabled(true) }
        if restoreForeground { setForegroundEnabled(true) }
    }
    func updateAIExecution(_ value: AIExecutionSummary) { aiExecution = value }
    func clearAIExecution() { aiExecution = nil }
    func setBridgeEnabled(_ enabled: Bool) {
        guard !enabled || Bundle.main.bundleIdentifier == "com.contextos.app" else {
            bridgeStatus = "테스트 앱 · 자동 활동 연결은 운영 앱에서 켜세요"; return
        }
        guard enabled != bridgeEnabled else { return }
        bridgeEnabled = enabled
        preferences.set(enabled, forKey: "contextos.automaticActivityReceiverEnabled")
        if enabled { bridgeStatus = "VS Code 확장 신호 대기" }
        if !enabled {
            let sources = Array(bridgeLedgers.keys)
            activityPoint { ledger, tick, wall in
                for source in sources { ledger.disconnect(id: source, tick: tick, wall: wall, timeZone: .current) }
            }
            closedEditCount = bridgeEditCount; bridgeLedgers.removeAll()
            bridgeFocused = nil; bridgeStatus = "확장 연결 꺼짐"
        }
        reconcileActivityReceiver()
    }
    /// The master preference owns observation; an IDE never needs an extension.
    private func reconcileActivityReceiver() {
        guard isProductionApp else { refreshActivity(); return }
        guard automaticActivityRequested != (bridgeServer != nil) else { refreshActivity(); return }
        let ownedPersistence = receiverLease.isReady
        let generation = receiverLease.begin()
        if automaticActivityRequested {
            ensureBoundaries()
            bridgeStatus = "로컬 수신 준비 중"
            let server = ObservationBridgeServer { [weak self] event in
                Task { @MainActor in
                    guard let self, self.automaticActivityRequested, self.receiverLease.accepts(generation) else { return }
                    switch event {
                    case .ready:
                        do {
                            let directory = self.activityFile.deletingLastPathComponent()
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            var status = stat()
                            guard lstat(directory.path, &status) == 0, status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFDIR, status.st_mode & 0o077 == 0 else { throw BridgeError.unsafeLocation }
                            let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextOS Observation Candidate/activity-day-v1.json")
                            try EstimatedActivityStore.importLegacyIfAbsent(from: legacy, to: self.activityFile, now: self.now(), timeZone: .current)
                            if let stored = try EstimatedActivityStore.read(from: self.activityFile) {
                                self.activityLedger.restore(stored, now: self.now(), timeZone: .current,
                                                            preservingCurrentAggregate: true)
                            }
                            self.receiverLease.ready(generation)
                            self.bridgeStatus = self.bridgeEnabled ? "VS Code 확장 신호 대기" : "확장 연결 꺼짐"
                            self.publishActivity()
                            self.refreshActivity()
                        } catch {
                            self.receiverLease.invalidate()
                            self.activityStoreStatus = "활동 저장 준비 실패 · 기존 기록 보존"
                            self.bridgeStatus = "활동 저장 준비 실패 · 기존 기록 보존"
                            self.suspendAutomaticActivity()
                            self.bridgeServer?.stop(); self.bridgeServer = nil; self.releaseUnusedBoundaries()
                        }
                    case .packet(let packet):
                        guard self.bridgeEnabled, !self.observationSuspended, self.receiverLease.isReady else { return }
                        // Additional callbacks request a fresh native sample. They
                        // cannot extend human-input eligibility during unattended AI edits.
                        if packet.version == 2 { self.refreshActivity() }
                        var counter = self.bridgeLedgers[packet.nonce] ?? ObservationBridgeLedger()
                        counter.consume(packet); self.bridgeLedgers[packet.nonce] = counter
                        let counts = self.bridgeLedgers.values.compactMap(\.editCount) + (self.closedEditCount.map { [$0] } ?? [])
                        self.bridgeEditCount = counts.isEmpty ? nil : counts.reduce(0) { sum, value in let (n,o) = sum.addingReportingOverflow(value); return o ? .max : n }
                        self.bridgeFocused = self.bridgeLedgers.values.contains { $0.focused == true }
                        self.bridgeStatus = packet.version == 1 ? "구형 확장 · 자동 활동 미지원" : "연결됨 · 자동 활동 추정"
                    case .disconnected(let nonce):
                        guard self.bridgeEnabled else { return }
                        if let nonce, let closed = self.bridgeLedgers.removeValue(forKey: nonce)?.editCount {
                            let (n,o) = (self.closedEditCount ?? 0).addingReportingOverflow(closed); self.closedEditCount = o ? .max : n
                        }
                        self.bridgeFocused = nil; self.bridgeStatus = "일부 연결 끊김 · 마지막 집계 유지"
                    case .failed:
                        self.receiverLease.invalidate()
                        self.activityStoreStatus = "수신 시작 실패 · 기존 경로 보존"
                        self.bridgeStatus = "수신 시작 실패 · 기존 경로 보존"
                        self.suspendAutomaticActivity()
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
            bridgeServer?.stopSynchronously(); bridgeServer = nil; closedEditCount = bridgeEditCount; bridgeLedgers.removeAll()
            bridgeFocused = nil; bridgeStatus = "확장 연결 꺼짐"; releaseUnusedBoundaries()
        }
    }
    private(set) var lastPublishTick: UInt64 = 0
    private var drawSamples: [Double] = []
    private var ledger = MeasuredTimeLedger()
    private(set) var editorNanoseconds: [String: UInt64] = [:]
    private var foregroundPartial = false
    private var uiVisible = false
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var boundaries: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var lastWall = Date()
    private var interrupted = false

    func setUIVisible(_ visible: Bool) { uiVisible = visible; capture(); schedule() }

    func startManual() {
        guard !manualRunning, !observationSuspended else { return }
        prepareEpochPoint(); interrupted = false; boundaryReason = nil
        ledger.begin(.manualTimer, id: "manual", at: uptimeNanoseconds())
        manualRunning = true; ensureBoundaries(); capture(); schedule()
    }
    func pauseManual() {
        guard manualRunning else { return }
        capture()
        ledger.end(.manualTimer, id: "manual", at: uptimeNanoseconds())
        manualRunning = false; publish(); schedule(); releaseUnusedBoundaries()
    }
    func setForegroundEnabled(_ enabled: Bool) {
        guard enabled != foregroundEnabled else { return }
        let tick = uptimeNanoseconds()
        _ = advanceMeasurements(to: tick, wall: now())
        foregroundEnabled = enabled; interrupted = false; boundaryReason = nil
        if persistsPreferences { preferences.set(enabled, forKey: "contextos.foregroundIDEObservationEnabled") }
        if enabled {
            if isProductionApp { suspensionReasons.formUnion(Self.currentSystemSuspensions()) }
            ensureBoundaries()
            activationObserver = workspaceNotifications.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let hasApplication = app != nil
                    let bundleID = app?.bundleIdentifier
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.reconcileForeground(bundleID: hasApplication ? bundleID : self.frontmostBundleIdentifier())
                    }
                }
        } else {
            if let activationObserver { workspaceNotifications.removeObserver(activationObserver) }
            activationObserver = nil
        }
        updateForeground(bundleID: enabled && !observationSuspended ? frontmostBundleIdentifier() : nil)
        if !enabled {
            activityPoint { ledger, tick, wall in ledger.disconnect(id: nil, tick: tick, wall: wall, timeZone: .current) }
        }
        reconcileActivityReceiver()
        publish(); schedule(); releaseUnusedBoundaries()
    }
    private func reconcileForeground(bundleID: String?) {
        guard foregroundEnabled, !observationSuspended else { return }
        let tick = uptimeNanoseconds()
        guard advanceMeasurements(to: tick, wall: now()) else { return }
        updateForeground(bundleID: bundleID)
        if !refreshActivity() { publish() }
        schedule()
    }
    private func updateForeground(bundleID: String?) {
        let label = ForegroundEditors.label(for: bundleID)
        if label != editorLabel { editorLabel = label }
    }
    private func prepareEpochPoint() {
        if !manualRunning && editorLabel == nil { lastTick = uptimeNanoseconds(); lastWall = now() }
    }
    func capture() {
        guard !observationSuspended else { return }
        let tick = uptimeNanoseconds(), wall = now()
        if advanceMeasurements(to: tick, wall: wall) {
            if !refreshActivity() { publish() }
        }
    }
    private func advanceMeasurements(to tick: UInt64, wall: Date) -> Bool {
        if manualRunning || editorLabel != nil {
            guard tick >= lastTick,
                  abs(wall.timeIntervalSince(lastWall) - Double(tick - lastTick) / 1_000_000_000) < 2 else {
                interrupt("시계 또는 관측 공백"); return false
            }
            if manualRunning {
                ledger.end(.manualTimer, id: "manual", at: tick)
                ledger.begin(.manualTimer, id: "manual", at: tick)
            }
            if let editorLabel {
                // Each elapsed slice belongs to the one IDE foreground since the last checkpoint.
                editorNanoseconds[editorLabel, default: 0] += tick - lastTick
            }
        }
        lastTick = tick; lastWall = wall
        return true
    }
    private func publish() {
        lastPublishTick = uptimeNanoseconds()
        let manual = ledger.value(for: .manualTimer)
        let foregroundTotal = editorNanoseconds.isEmpty ? nil : editorNanoseconds.values.reduce(0, +)
        snapshot = WidgetTimeSnapshot(generatedAt: now(), manualNanoseconds: manual.nanoseconds, foregroundNanoseconds: foregroundTotal,
            manualState: manual.partial ? .partial : manualRunning ? .running : interrupted ? .interrupted : manual.nanoseconds == nil ? .notObserved : .paused,
            foregroundState: observationSuspended && foregroundEnabled ? .interrupted : foregroundPartial ? .partial : editorLabel != nil ? .running : foregroundEnabled ? .waitingForEditor : interrupted ? .interrupted : foregroundTotal == nil ? .notObserved : .paused,
            activity: estimatedActivity)
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
    private func interrupt(_ reason: String, reconcileReceiver: Bool = true) {
        if editorLabel != nil { foregroundPartial = true }
        ledger.interrupt(); manualRunning = false; editorLabel = nil
        lastTick = uptimeNanoseconds(); lastWall = now()
        suspendAutomaticActivity()
        interrupted = true; boundaryReason = reason
        timer?.invalidate(); timer = nil
        if !observationSuspended && foregroundEnabled {
            updateForeground(bundleID: frontmostBundleIdentifier())
        }
        if reconcileReceiver { reconcileActivityReceiver() }
        publish(); schedule(); releaseUnusedBoundaries()
    }
    func reset() {
        setForegroundEnabled(false)
        interrupt("초기화"); setBridgeEnabled(false); bridgeLedgers.removeAll(); closedEditCount = nil; bridgeEditCount = nil
        ledger = MeasuredTimeLedger(); interrupted = false; boundaryReason = nil
        editorNanoseconds.removeAll(); foregroundPartial = false
        lastTick = uptimeNanoseconds(); lastWall = now(); publish()
    }
    private func ensureBoundaries() {
        guard boundaries.isEmpty else { return }
        observeEnvironment(workspaceNotifications, NSWorkspace.willSleepNotification, .systemSleep, suspended: true)
        observeEnvironment(workspaceNotifications, NSWorkspace.didWakeNotification, .systemSleep, suspended: false)
        observeEnvironment(workspaceNotifications, NSWorkspace.screensDidSleepNotification, .displaySleep, suspended: true)
        observeEnvironment(workspaceNotifications, NSWorkspace.screensDidWakeNotification, .displaySleep, suspended: false)
        observeEnvironment(workspaceNotifications, NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, suspended: true)
        observeEnvironment(workspaceNotifications, NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, suspended: false)
        observeEnvironment(distributedNotifications, Notification.Name("com.apple.screenIsLocked"), .screenLock, suspended: true)
        observeEnvironment(distributedNotifications, Notification.Name("com.apple.screenIsUnlocked"), .screenLock, suspended: false)
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged, NSApplication.willTerminateNotification] {
            observe(applicationNotifications, name, "일자 또는 시간대 변경")
        }
    }
    private func observeEnvironment(_ center: NotificationCenter, _ name: Notification.Name,
                                    _ reason: SuspensionReason, suspended: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.terminating else { return }
                let wasSuspended = self.observationSuspended
                if suspended { self.suspensionReasons.insert(reason) }
                else { self.suspensionReasons.remove(reason) }
                if !wasSuspended && self.observationSuspended {
                    self.interrupt(reason == .screenLock ? "화면 잠금" : "절전 또는 세션 비활성")
                } else if wasSuspended && !self.observationSuspended {
                    // Discard the complete suspended interval before sampling again.
                    self.lastTick = self.uptimeNanoseconds(); self.lastWall = self.now()
                    self.suspendAutomaticActivity()
                    self.boundaryReason = nil
                    self.updateForeground(bundleID: self.foregroundEnabled ? self.frontmostBundleIdentifier() : nil)
                    self.reconcileActivityReceiver()
                    self.publish(); self.schedule(); self.releaseUnusedBoundaries()
                }
            }
        }
        boundaries.append((center, token))
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if name == NSApplication.willTerminateNotification {
                    let ownedPersistence = self.receiverLease.isReady
                    self.capture()
                    self.terminating = true
                    self.interrupt("앱 종료", reconcileReceiver: false)
                    if ownedPersistence { try? EstimatedActivityStore.write(self.estimatedActivity, to: self.activityFile) }
                    // Freeze and persist before relinquishing the exclusive receiver.
                    self.receiverLease.invalidate()
                    self.timer?.invalidate(); self.timer = nil
                    self.bridgeServer?.stopSynchronously(); self.bridgeServer = nil
                    return
                }
                self.interrupt(reason)
            }
        }
        boundaries.append((center, token))
    }
    private func releaseUnusedBoundaries() {
        guard !manualRunning && !foregroundEnabled && suspensionReasons.isEmpty else { return }
        for (center, token) in boundaries { center.removeObserver(token) }
        boundaries.removeAll()
    }
    private func schedule() {
        let automaticReady = automaticActivityRequested && (receiverLease.isReady || !isProductionApp)
        guard !observationSuspended && (manualRunning || editorLabel != nil || automaticReady) else {
            timer?.invalidate(); timer = nil; return
        }
        // One checkpoint updates both daily activity and per-run measurements.
        let interval: TimeInterval = uiVisible ? 1 : automaticReady ? 5 : 60
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        timer?.tolerance = interval * 0.1
    }
}
