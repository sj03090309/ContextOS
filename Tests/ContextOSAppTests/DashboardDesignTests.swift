import AppKit
import SwiftUI
import Testing
import ContextOSUsage
import ContextOSCore
@testable import ContextOSApp

@Suite("Dashboard design", .serialized)
@MainActor
struct DashboardDesignTests {
    @Test("content fits compact and full screen budgets without moving the anchor")
    func screenBudgets() {
        for visibleHeight: CGFloat in [300, 480, 650, 861, 1100] {
            let height = DashboardLayout.height(visibleHeight: visibleHeight)
            #expect(height + 56 <= visibleHeight)
            #expect(height <= 760)
            #expect(height >= 180)
        }
    }

    @Test("rapid page changes preserve project disclosures and privacy")
    func navigationStateSurvives() {
        let ui = DashboardUIState()
        ui.expanded = ["one-project"]
        ui.usageExpanded = true
        ui.tab = .activity
        for index in 0..<90 { ui.page = DashboardUIState.Page.allCases[index % 3] }
        #expect(ui.expanded == ["one-project"])
        #expect(ui.usageExpanded)
        #expect(ui.tab == .activity)
        #expect(ui.hidePrivateDetails)
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

    @Test("static native SwiftUI snapshots cover pages, missing and zero usage and long names")
    func renderReviewSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["CONTEXTOS_DESIGN_QA_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = DashboardModel(startServices: false)
        let time = WorkTimeController(restoreConnections: false)
        let ui = DashboardUIState()
        let suite = "ContextOS.Design.Render." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("off", forKey: "contextos.mascot.motion")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        model.concurrentUsage = UsagePreviewData.snapshot()
        model.totalSaved = 12000
        model.todaySaved = 200
        ui.usageExpanded = true
        for scheme in [ColorScheme.dark, .light] {
            for page in DashboardUIState.Page.allCases {
                for height: CGFloat in [440, 760] {
                    ui.page = page; ui.panelHeight = height
                    let view = DashboardView(workTime: time)
                        .environmentObject(model).environmentObject(ui)
                        .environment(\.colorScheme, scheme)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                        .overlay(alignment: .top) {
                            MeltingMascot(state: model.mascot, settings: settings)
                                .frame(height: PopoverContentController.mascotHeight)
                        }
                        .overlay(alignment: .bottomLeading) {
                            Text("디자인 검증 · 예시 데이터")
                                .font(.system(size: 8)).padding(3).background(.yellow).foregroundStyle(.black)
                                .allowsHitTesting(false)
                        }
                    let png = try renderNative(view, height: height, scheme: scheme)
                    let theme = scheme == .dark ? "dark" : "light"
                    try png.write(to: directory.appendingPathComponent("page-\(page)-\(theme)-\(Int(height)).png"))
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
                snapshot.widget.models = [.init(String(repeating: "long-model-", count: 12), .max), .init("second", 1)]
            }
            let view = UsageOverviewCard(snapshot: snapshot, expanded: .constant(true))
                .padding(16).frame(width: 340, height: 400, alignment: .top).background(Brand.canvas)
                .environment(\.colorScheme, .dark).transaction { $0.animation = nil; $0.disablesAnimations = true }
            let png = try renderNative(view, height: 400, scheme: .dark)
            try png.write(to: directory.appendingPathComponent("state-\(state).png"))
        }
        ui.showSettings = true; ui.page = .overview; ui.panelHeight = 440
        let settingsView = DashboardView(workTime: time).environmentObject(model).environmentObject(ui)
            .environment(\.colorScheme, .dark).transaction { $0.animation = nil; $0.disablesAnimations = true }
        try renderNative(settingsView, height: 440, scheme: .dark).write(to: directory.appendingPathComponent("settings-compact.png"))
    }

    /// ScrollView uses native drawing on macOS; ImageRenderer alone leaves its
    /// viewport blank. Attach to an offscreen window and cache the native view.
    private func renderNative<V: View>(_ view: V, height: CGFloat, scheme: ColorScheme) throws -> Data {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 340, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 340, height: height)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 340)
        #expect(bitmap.pixelsHigh >= Int(height))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        window.close()
        return png
    }
}
