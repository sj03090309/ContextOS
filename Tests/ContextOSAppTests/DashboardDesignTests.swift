import AppKit
import SwiftUI
import Testing
import ContextOSUsage
import ContextOSUsageUI
import ContextOSCore
@testable import ContextOSApp

@Suite("Dashboard design", .serialized)
@MainActor
struct DashboardDesignTests {
    @Test("Log aggregation waits for a persistent choice and revocation clears observed UI only")
    func logConsentAndRevocation() throws {
        let suite = "ContextOS.ConsentTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppSettings(defaults: defaults).agentLogsEnabled)
        defaults.set(1, forKey: AgentLogCollectionPolicy.preferenceKey)
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.agentLogsEnabled)
        let model = DashboardModel(startServices: false, settings: settings)
        #expect(!model.agentLogCollectionEnabled)
        #expect(model.concurrentUsage.widget.health == "로그 집계 꺼짐")
        settings.agentLogsEnabled = true
        #expect(AppSettings(defaults: defaults).agentLogsEnabled)
        model.setAgentLogCollectionEnabled(true)
        model.aiTokens = 123
        model.agents = [.init(name: "Codex", present: true, detail: "previous session detail",
                              connection: .configured(path: "/fixture/config.toml"), usage: .reported(tokens: 123))]
        model.connected = true
        model.tokensByDay = ["2026-11-03": 123]
        model.todaySaved = 42
        model.queryCount = 7
        model.concurrentUsage = .init(widget: .init(days: [.init(date: Date(), tokens: 123)]),
                                      sessions: [.init(id: "fixture", agent: "Codex", project: "/fixture", model: "test",
                                                       state: .working, lastEvent: Date(), todayTokens: 123, totalTokens: 123)])
        settings.agentLogsEnabled = false
        model.setAgentLogCollectionEnabled(false)
        #expect(!AppSettings(defaults: defaults).agentLogsEnabled)
        #expect(model.aiTokens == 0 && model.tokensByDay == ["2026-11-03": 123])
        #expect(model.concurrentUsage.sessions.isEmpty && model.concurrentUsage.widget.today == nil)
        #expect(model.concurrentUsage.widget.health == "로그 집계 꺼짐")
        #expect(model.todaySaved == 42 && model.queryCount == 7)
        #expect(model.connected && model.agents.first?.connection.isConfigured == true)
        #expect(model.agents.first?.usage == .paused && model.agents.first?.detail == nil)
    }

    @Test("content fits compact and full screen budgets without moving the anchor")
    func screenBudgets() {
        for visibleHeight: CGFloat in [300, 480, 650, 861, 1100] {
            let height = DashboardLayout.height(visibleHeight: visibleHeight)
            #expect(height + 56 <= visibleHeight)
            #expect(height <= 520)
            #expect(height >= 180)
        }
    }

    @Test("rapid page changes preserve project disclosures and privacy")
    func navigationStateSurvives() {
        let ui = DashboardUIState()
        ui.expanded = ["one-project"]
        ui.usageExpanded = true
        ui.tab = .activity
        ui.page = .time
        #expect(ui.navigatingForward)
        ui.page = .overview
        #expect(!ui.navigatingForward)
        ui.page = .overview
        #expect(!ui.navigatingForward)
        let primary = DashboardUIState.Page.primary
        for index in 0..<90 { ui.page = primary[index % primary.count] }
        #expect(ui.expanded == ["one-project"])
        #expect(ui.usageExpanded)
        #expect(ui.tab == .activity)
        #expect(ui.hidePrivateDetails)
    }

    @Test("Maximum recorded counters render project shares, split bars and monthly totals safely")
    func maximumCounterRendering() throws {
        _ = NSApplication.shared
        let model = DashboardModel(startServices: false)
        let ui = DashboardUIState()
        model.projectUsage = ["one", "two"].map {
            ProjectAIUsage(name: $0, path: "/fixture/" + $0, total: .max,
                           byAgent: [.init(agent: "Codex", tokens: .max), .init(agent: "Claude Code", tokens: .max)])
        }
        ui.expanded = Set(model.projectUsage.map(\.id))
        let prefix = String(TimeKeys.localDay(Date().timeIntervalSince1970).prefix(7))
        model.tokensByDay = Dictionary(uniqueKeysWithValues: (1...28).map {
            (prefix + String(format: "-%02d", $0), Int.max)
        })
        let view = VStack { CalendarCard(); ProjectsList() }
            .padding(16).frame(width: 340, height: 880).background(Brand.canvas)
            .environmentObject(model).environmentObject(ui)
        #expect(try !renderNative(view, height: 880, scheme: .dark).isEmpty)
    }

    @Test("fresh settings are still at rest, existing motion choices survive")
    func motionPreference() throws {
        let suite = "ContextOS.DesignTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: defaults).mascotMotion == .whileWorking)
        defaults.set("always", forKey: "contextos.mascot.motion")
        #expect(AppSettings(defaults: defaults).mascotMotion == .always)
        #expect(PanelMotion.response(reduced: true) == nil)
        #expect(PanelMotion.feedback(reduced: true) == nil)
        #expect(PanelMotion.navigation(reduced: true) == nil)
    }

    @Test("Mascot presets and custom RGB colors persist across settings instances")
    func mascotColorPreference() throws {
        let suite = "ContextOS.MascotColorTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.mascotTint == MascotColor.mint.hex)
        #expect(settings.setMascotTint(MascotColor.white.hex))
        #expect(AppSettings(defaults: defaults).mascotTint == "FFFFFF")
        #expect(settings.setMascotTint(MascotColor.lavender.hex))
        #expect(AppSettings(defaults: defaults).mascotTint == MascotColor.lavender.hex)
        #expect(settings.setMascotTint(" #426bde "))
        #expect(!settings.setMascotTint("#426bdeff"))
        #expect(!settings.setMascotTint("+426bd"))
        #expect(AppSettings(defaults: defaults).mascotTint == "426BDE")
        defaults.set("broken", forKey: "contextos.mascot.tint")
        #expect(AppSettings(defaults: defaults).mascotTint == MascotColor.mint.hex)
    }

    @Test("The mascot holds its work pose and settles from its current position")
    func mascotWorkPose() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let state = MascotState()
        state.setWorking(true, now: start)
        let halfway = start.addingTimeInterval(MascotState.workTransitionDuration / 2)
        let pose = state.workProgress(at: halfway)
        #expect(pose > 0 && pose < 1)
        #expect(state.isWorkTransitioning(at: halfway))

        state.setWorking(true, now: halfway)
        #expect(state.workChangedAt == start)
        #expect(state.workProgress(at: start.addingTimeInterval(1)) == 1)
        #expect(!state.isWorkTransitioning(at: start.addingTimeInterval(1)))
        #expect(!state.showsOptimizationCompletion(at: halfway))

        state.setWorking(false, now: halfway)
        #expect(state.workProgress(at: halfway) == pose)
        #expect(state.workProgress(at: halfway.addingTimeInterval(1)) == 0)
    }

    @Test("Only an optimization completion produces one nod and a temporary caption")
    func mascotOptimizationCue() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let state = MascotState()
        state.completeOptimization(at: start)
        let dipped = start.addingTimeInterval(0.17)
        let recovering = start.addingTimeInterval(0.30)
        let afterNod = start.addingTimeInterval(1)
        let afterCaption = start.addingTimeInterval(3)

        #expect(!state.isWorking)
        #expect(state.nodProgress(at: start) == 0)
        #expect(state.nodProgress(at: dipped) > 0.98)
        #expect(state.nodProgress(at: recovering) < state.nodProgress(at: dipped))
        #expect(!state.isNodding(at: afterNod))
        #expect(state.nodProgress(at: afterNod) == 0)
        #expect(state.showsOptimizationCompletion(at: afterNod))
        #expect(!state.showsOptimizationCompletion(at: afterCaption))

        state.setWorking(true, now: afterNod)
        state.completeOptimization(at: afterCaption)
        #expect(state.isWorking)
        #expect(state.workProgress(at: afterCaption) == 1)
        #expect(state.isNodding(at: afterCaption))
        #expect(state.showsOptimizationCompletion(at: afterCaption))
    }

    @Test("The mascot skips quiet frames and always lands on the final gesture frame")
    func mascotFrameSchedule() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(MascotState.nodDuration)
        let nod = MascotTimelineSchedule(gestureEnd: end, breathPeriod: nil)
        let frames = Array(nod.entries(from: start, mode: .normal))
        #expect(frames.first == start && frames.last == end)
        #expect(frames.count > 2)
        #expect(Array(nod.entries(from: start, mode: .lowFrequency)) == [start, end])
        #expect(Array(nod.entries(from: end, mode: .normal)) == [end])

        let working = MascotTimelineSchedule(gestureEnd: .distantPast, breathPeriod: MascotState.focusBreathPeriod)
        let quiet = start.addingTimeInterval(3)
        #expect(Array(working.entries(from: quiet, mode: .normal).prefix(2)) ==
                [quiet, start.addingTimeInterval(MascotState.focusBreathPeriod)])
        let sampleEnd = start.addingTimeInterval(72)
        let workingFrames = Array(working.entries(from: start, mode: .normal).prefix(while: { $0 < sampleEnd }))
        #expect(workingFrames.count < 550)
        #expect(zip(workingFrames, workingFrames.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(Array(PanelClockSchedule(paused: true).entries(from: start, mode: .normal)) == [start])
    }

    @Test("privacy rendering preserves projects, questions and numeric history")
    func privacyPreservesData() throws {
        let model = DashboardModel(startServices: false)
        let ui = DashboardUIState()
        let projects = [ProjectAIUsage(name: "PRIVATE-PROJECT", path: "/private/PRIVATE-PATH", total: 12345,
                                       byAgent: [.init(agent: "Codex", tokens: 12345)])]
        let events = [UsageEvent(project: "/private/PRIVATE-PATH", query: "PRIVATE-QUESTION",
                                selectedTokens: 200, fullTokens: 1000, contextScore: 80, fileCount: 2)]
        model.projectUsage = projects; model.recent = events
        if let path = ProcessInfo.processInfo.environment["CONTEXTOS_DESIGN_QA_DIR"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            for hidden in [true, false] {
                ui.hidePrivateDetails = hidden
                let view = VStack(spacing: 16) { ProjectsList(); ActivityList(); Spacer() }
                    .padding(16).frame(width: 340, height: 440)
                    .background(Brand.canvas).environment(\.colorScheme, .dark)
                    .environmentObject(model).environmentObject(ui)
                try renderNative(view, height: 440, scheme: .dark)
                    .write(to: URL(fileURLWithPath: path).appendingPathComponent(hidden ? "privacy-hidden.png" : "privacy-visible-test-data.png"))
            }
        }
        #expect(model.projectUsage == projects)
        #expect(model.recent == events)
        #expect(model.projectUsage.first?.total == 12345)
    }

    @Test("many models and repeated unknown sessions keep the preview bounded")
    func manyModelsAndSessions() throws {
        let now = Date()
        var sessions: [ObservedSession] = []
        var models: [TodayModelUsage] = []
        for n in 0..<20 {
            let name = n == 19 ? String(repeating: "long-model-", count: 25) : "model-\(n)"
            models.append(.init(provider: "Codex", model: name, tokens: 30))
            for index in 0..<3 {
                sessions.append(.init(id: "known-\(n)-\(index)", agent: "Codex", project: "PRIVATE-PROJECT", model: name,
                                      state: .idle, lastEvent: now, todayTokens: 10, totalTokens: 100))
            }
        }
        models.append(.init(provider: "Codex", model: "unknown", tokens: 200))
        for n in 0..<20 {
            sessions.append(.init(id: "unknown-\(n)", agent: "Codex", project: "PRIVATE-PROJECT", model: n % 2 == 0 ? "unknown" : "모델 미상",
                                  state: .unknown, lastEvent: now, todayTokens: 10, totalTokens: 100))
        }
        let model = DashboardModel(startServices: false)
        model.concurrentUsage = .init(widget: .init(days: [.init(date: now, tokens: 800)],
                                                    providers: [.init(name: "Codex", state: .partial)], isSample: true),
                                      sessions: sessions, todayModels: models)
        #expect(model.usageSessionGroups["Codex"]?.count == 21)
        #expect(model.usageSessionGroups["Codex"]?.first?.sessions.count == 20)
        let preview = ModelUsagePreview(models)
        #expect(preview.visible.count == 3 && preview.hiddenCount == 18 && preview.hiddenTokens == 540)
        #expect(preview.totalTokens == 800)
        if let path = ProcessInfo.processInfo.environment["CONTEXTOS_DESIGN_QA_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let time = WorkTimeController(restoreConnections: false)
            let ui = DashboardUIState(); ui.page = .usage; ui.panelHeight = 400
            for expanded in [false, true] {
                ui.usageExpanded = expanded
                let view = DashboardView(workTime: time).environmentObject(model).environmentObject(ui)
                    .environment(\.colorScheme, .dark).transaction { $0.animation = nil; $0.disablesAnimations = true }
                try renderNative(view, height: 400, scheme: .dark)
                    .write(to: directory.appendingPathComponent(expanded ? "many-models-expanded.png" : "many-models-preview.png"))
            }
            let provider = ProviderSessionsCard(provider: .init(name: "Codex", state: .partial),
                                                groups: model.usageSessionGroups["Codex"] ?? [], initiallyExpanded: true)
                .padding(16).frame(width: 340, height: 400, alignment: .top).background(Brand.canvas).environment(\.colorScheme, .dark)
            try renderNative(provider, height: 400, scheme: .dark).write(to: directory.appendingPathComponent("many-session-groups.png"))
        }
        #expect(model.concurrentUsage.sessions == sessions)
    }

    @Test("static native SwiftUI snapshots cover pages, missing and zero usage and long names")
    func renderReviewSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["CONTEXTOS_DESIGN_QA_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let time = WorkTimeController(restoreConnections: false)
        let ui = DashboardUIState()
        let suite = "ContextOS.Design.Render." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("off", forKey: "contextos.mascot.motion")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.agentLogsEnabled = true
        let model = DashboardModel(startServices: false, settings: settings)
        model.concurrentUsage = UsagePreviewData.snapshot()
        model.agents = [
            .init(name: "Codex", present: true, connection: .configured(path: "/fixture/config.toml")),
            .init(name: "Claude Code", present: true, connection: .notConfigured(path: "/fixture/settings.json"))
        ]
        let fixtureTime = Date().timeIntervalSince1970
        model.recent = [
            .init(timestamp: fixtureTime - 600, project: "/fixture", query: "First fixture",
                  selectedTokens: 200, fullTokens: 7400, contextScore: 90, fileCount: 4),
            .init(timestamp: fixtureTime - 3600, project: "/fixture", query: "Second fixture",
                  selectedTokens: 300, fullTokens: 5100, contextScore: 86, fileCount: 3),
            .init(timestamp: fixtureTime - 86_400, project: "/fixture", query: "Third fixture",
                  selectedTokens: 400, fullTokens: 3100, contextScore: 81, fileCount: 3)
        ]
        model.totalSaved = 43_200
        model.todaySaved = 12_000
        model.queryCount = 2
        model.lastUpdated = Date(timeIntervalSince1970: fixtureTime)
        ui.usageExpanded = true
        for scheme in [ColorScheme.dark, .light] {
            for page in DashboardUIState.Page.allCases {
                for height: CGFloat in [400, 520] {
                    ui.page = page; ui.panelHeight = height
                    let view = DashboardView(workTime: time)
                        .environmentObject(model).environmentObject(ui)
                        .environment(\.colorScheme, scheme)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                        .overlay(alignment: .topLeading) {
                            MeltingMascot(state: model.mascot, settings: settings, ui: ui)
                                .frame(width: DashboardLayout.mascotWidth, height: DashboardLayout.mascotHeight)
                                .padding(.leading, DashboardLayout.mascotLeading)
                                .padding(.top, DashboardLayout.mascotTop)
                        }
                        .overlay(alignment: .bottomLeading) {
                            Text("디자인 검증 · 예시 데이터")
                                .font(.system(size: 8)).padding(3).background(.yellow).foregroundStyle(.black)
                                .allowsHitTesting(false)
                        }
                    let png = try renderNative(view, height: height, scheme: scheme)
                    let theme = scheme == .dark ? "dark" : "light"
                    try png.write(to: directory.appendingPathComponent("page-\(page)-\(theme)-\(Int(height)).png"))
                    if page == .overview, height == 400, scheme == .dark {
                        model.mascot.completeOptimization()
                        defer { model.mascot.completeOptimization(at: .distantPast) }
                        try renderNative(view, height: height, scheme: scheme)
                            .write(to: directory.appendingPathComponent("completion-banner-dark.png"))
                    }
                }
            }
        }
        for state in ["loading", "missing", "zero", "long"] {
            var snapshot = ConcurrentUsageSnapshot()
            if state != "loading" {
                snapshot.widget.providers = [.init(name: "Codex", state: state == "missing" ? .unavailable : .ready)]
                snapshot.widget.days = [.init(date: Date(), tokens: state == "missing" ? nil : 0)]
            }
            if state == "long" {
                snapshot.todayModels = [.init(provider: "Codex", model: String(repeating: "long-model-", count: 12), tokens: .max), .init(provider: "Codex", model: "second", tokens: 1)]
            }
            let view = UsageOverviewCard(snapshot: snapshot, expanded: .constant(true))
                .padding(16).frame(width: 340, height: 400, alignment: .top).background(Brand.canvas)
                .environment(\.colorScheme, .dark).transaction { $0.animation = nil; $0.disablesAnimations = true }
            let png = try renderNative(view, height: 400, scheme: .dark)
            try png.write(to: directory.appendingPathComponent("state-\(state).png"))
        }
        ui.page = .overview; ui.panelHeight = 440
        for state in ["setup", "settings", "connections"] {
            model.setAgentLogCollectionEnabled(state != "setup")
            if state == "setup" { model.recent = [] }
            if state != "setup" { model.concurrentUsage = UsagePreviewData.snapshot() }
            model.agents = state == "setup" ? [] : [
                .init(name: "Codex", present: true, connection: .configured(path: "/fixture/config.toml")),
                .init(name: "Claude Code", present: true, connection: .notConfigured(path: "/fixture/settings.json"))
            ]
            ui.showSettings = state == "settings"
            ui.showConnections = state == "connections"
            for scheme in [ColorScheme.dark, .light] {
                let view = DashboardView(workTime: time).environmentObject(model).environmentObject(ui)
                    .environment(\.colorScheme, scheme)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                let theme = scheme == .dark ? "dark" : "light"
                try renderNative(view, height: 440, scheme: scheme)
                    .write(to: directory.appendingPathComponent("\(state)-\(theme).png"))
            }
        }
    }

    @Test("Changing the selected metric changes every widget size, with legacy token snapshots preserved")
    func widgetMetricSelection() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = UsagePreviewData.snapshot(now: now).widget
        snapshot.timing = .init(generatedAt: now,
            manualNanoseconds: 5_432_000_000_000, foregroundNanoseconds: 1_234_000_000_000,
            manualState: .paused, foregroundState: .paused, isSample: true,
            activity: .init(now: now, estimatedNanoseconds: 9_032_000_000_000, phase: .paused))
        for size in UsageWidgetView.Size.allCases {
            for scheme in [ColorScheme.dark, .light] {
                var images: [Data] = []
                for metric in SmallWidgetMetric.allCases {
                    snapshot.smallMetric = metric
                    let png = try widgetPNG(snapshot, size: size, scheme: scheme, now: now)
                    images.append(png)
                    if let path = ProcessInfo.processInfo.environment["CONTEXTOS_DESIGN_QA_DIR"] {
                        let theme = scheme == .dark ? "dark" : "light"
                        try png.write(to: URL(fileURLWithPath: path)
                            .appendingPathComponent("widget-\(metric.rawValue)-\(size.rawValue)-\(theme).png"))
                    }
                }
                for first in images.indices {
                    for second in images.indices where second > first {
                        #expect(try widgetDifference(images[first], images[second]) > 0.0005,
                                "Every selection must visibly change the \(size.rawValue) widget")
                    }
                }
                snapshot.smallMetric = nil
                let legacy = try widgetPNG(snapshot, size: size, scheme: scheme, now: now)
                if let path = ProcessInfo.processInfo.environment["CONTEXTOS_DESIGN_QA_DIR"] {
                    let theme = scheme == .dark ? "dark" : "light"
                    try legacy.write(to: URL(fileURLWithPath: path)
                        .appendingPathComponent("widget-legacy-\(size.rawValue)-\(theme).png"))
                }
                #expect(try widgetDifference(legacy, images[0]) < 0.00001,
                        "Legacy token rendering: \(size.rawValue), \(scheme)")
            }
        }
    }

    private func widgetPNG(_ snapshot: WidgetUsageSnapshot, size: UsageWidgetView.Size,
                           scheme: ColorScheme, now: Date) throws -> Data {
        let width: CGFloat = size == .small ? 158 : 338
        let height: CGFloat = size == .large ? 354 : 158
        let view = UsageWidgetView(snapshot: snapshot, size: size, now: now)
            .padding(14).frame(width: width, height: height)
            .background { UsageWidgetBackground() }.environment(\.colorScheme, scheme)
        // ImageRenderer invokes a Metal path that aborts on the Intel CI
        // virtual GPU. Use the same native AppKit bitmap path as the dashboard
        // so every size/theme still receives an actual pixel comparison.
        return try renderNative(view, height: height, scheme: scheme, width: width)
    }

    private func widgetDifference(_ first: Data, _ second: Data) throws -> Double {
        let a = try #require(NSBitmapImageRep(data: first))
        let b = try #require(NSBitmapImageRep(data: second))
        #expect(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh && a.bytesPerRow == b.bytesPerRow)
        let count = a.bytesPerRow * a.pixelsHigh
        let pixelsA = try #require(a.bitmapData), pixelsB = try #require(b.bitmapData)
        var difference = 0
        for index in 0..<count { difference += abs(Int(pixelsA[index]) - Int(pixelsB[index])) }
        // Native text rasterization may differ by one antialiasing color step;
        // compare actual pixels with a small tolerance, rather than PNG bytes.
        return Double(difference) / Double(count) / 255
    }

    /// ScrollView uses native drawing on macOS; ImageRenderer alone leaves its
    /// viewport blank. Attach to an offscreen window and cache the native view.
    private func renderNative<V: View>(_ view: V, height: CGFloat, scheme: ColorScheme, width: CGFloat = 340) throws -> Data {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        #expect(bitmap.pixelsWide >= Int(width))
        #expect(bitmap.pixelsHigh >= Int(height))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        window.close()
        return png
    }
}
