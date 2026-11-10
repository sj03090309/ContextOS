import SwiftUI
import AppKit
import ContextOSCore
import ContextOSUsage

/// The ContextOS brand palette — the ink + cream of the app icon (뭉치 in cream
/// on a charcoal tile), used consistently across the dashboard.
enum Brand {
    static let cream = Color(red: 0.937, green: 0.906, blue: 0.839)      // #EFE7D6
    static let ink = Color(red: 0.090, green: 0.090, blue: 0.106)        // #17171B
    static let canvas = adaptive(
        dark: NSColor(calibratedRed: 0.114, green: 0.118, blue: 0.137, alpha: 1),
        light: NSColor(calibratedRed: 0.973, green: 0.965, blue: 0.945, alpha: 1))
    static let surface = adaptive(
        dark: NSColor(calibratedRed: 0.153, green: 0.157, blue: 0.180, alpha: 1),
        light: NSColor(calibratedWhite: 1, alpha: 0.85))
    static let caution = adaptive(dark: .systemOrange, light: .systemBrown)

    /// An appearance-adaptive color: `dark` in dark mode, `light` in light mode.
    static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static let creamNS = NSColor(calibratedRed: 0.937, green: 0.906, blue: 0.839, alpha: 1)
    private static let inkNS = NSColor(calibratedRed: 0.090, green: 0.090, blue: 0.106, alpha: 1)

    /// Monochrome accent that reads on both appearances: cream on dark, ink on
    /// light — literally the two icon colors, so contrast is always high.
    static let accent = adaptive(dark: creamNS, light: inkNS)

    /// Whatever sits on an `accent` fill: ink on cream, cream on ink.
    static let onAccent = adaptive(dark: inkNS, light: creamNS)

    /// Claude Code's share in every bar and dot — Anthropic's clay.
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)    // #D97757
    /// Codex's share: a clear blue, a step deeper on the light panel.
    static let codex = adaptive(
        dark: NSColor(calibratedRed: 0.478, green: 0.655, blue: 1.0, alpha: 1),     // #7AA7FF
        light: NSColor(calibratedRed: 0.231, green: 0.482, blue: 0.918, alpha: 1))  // #3B7BEA
    /// "Configured", "saved", "working" — a soft green that stays legible.
    static let positive = adaptive(
        dark: NSColor(calibratedRed: 0.651, green: 0.902, blue: 0.718, alpha: 1),   // #A6E6B7
        light: NSColor(calibratedRed: 0.118, green: 0.557, blue: 0.243, alpha: 1))  // #1E8E3E
    static let positiveDot = Color(red: 0.490, green: 0.863, blue: 0.588)          // #7DDC96
    /// Deleted lines — a muted red that reads on both appearances.
    static let negative = adaptive(
        dark: NSColor(calibratedRed: 1.0, green: 0.541, blue: 0.502, alpha: 1),     // #FF8A80
        light: NSColor(calibratedRed: 0.788, green: 0.196, blue: 0.180, alpha: 1))  // #C9322E

    static func color(forAgent agent: String) -> Color {
        switch agent {
        case "Claude Code": return claude
        case "Codex": return codex
        default: return .secondary
        }
    }
}

/// The lists inside dashboard history.
enum DashboardTab: Hashable, CaseIterable {
    case files, activity

    var label: String {
        switch self {
        case .files: return "프로젝트"
        case .activity: return "최적화 기록"
        }
    }
}

/// What the panel was showing — the tab, the cards that were open, the month
/// and day picked on the calendar.
///
/// Kept outside the views so it outlives them: the panel's views are released
/// while it stays closed (see `AppDelegate.schedulePanelRelease`) and rebuilt
/// on the next open, which should come back exactly as it was left.
@MainActor
final class DashboardUIState: ObservableObject {
    enum SettingsDestination: Hashable { case privacy }

    enum Page: String, CaseIterable {
        case overview = "대시보드", usage = "AI 사용량", time = "개발 시간", history = "기록"

        static let primary: [Self] = [.overview, .usage, .time]
        var label: String { rawValue }
        var position: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        var symbol: String {
            switch self {
            case .overview: "rectangle.grid.1x2"
            case .usage: "chart.bar"
            case .time: "clock"
            case .history: "calendar"
            }
        }
    }
    @Published var page: Page = .overview {
        willSet {
            if newValue != page { navigatingForward = newValue.position > page.position }
        }
    }
    // Updated with the selection, so every navigation entry (tabs, cards and
    // public menu commands) uses the same spatial relationship.
    private(set) var navigatingForward = true
    @Published var usageExpanded = false
    @Published var panelHeight: CGFloat = 520
    @Published var tab: DashboardTab = .files
    @Published var expanded: Set<String> = []   // expanded project cards
    /// Months back from the current one.
    @Published var monthOffset = 0
    @Published var selectedDay: String?
    @Published var showSettings = false
    private(set) var settingsDestination: SettingsDestination?
    @Published var showConnections = false
    // Display only: never mutates the project store, history or usage snapshot.
    // Safe by default when this release preview is shared or screen recorded.
    @Published var hidePrivateDetails = true
    /// Wired by the app's public window command; no independent data source.
    var openWindow: (() -> Void)?

    func openSettings(at destination: SettingsDestination? = nil) {
        settingsDestination = destination
        showConnections = false
        showSettings = true
    }

    /// Public menu and widget routes reveal their destination even when a
    /// settings overlay was left open, including routes to the current page.
    func navigate(to destination: Page) {
        showSettings = false
        settingsDestination = nil
        showConnections = false
        page = destination
    }
}

/// Live activity stays visible above the overview, usage, and development time pages.
struct DashboardView: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject private var ui: DashboardUIState
    @Environment(\.accessibilityReduceMotion) private var reduced
    // The time cards observe their own controller so a ticking duration does
    // not invalidate the calendar and every other dashboard section.
    let workTime: WorkTimeController
    private let surface: DashboardSurface
    @Namespace private var navigation
    @FocusState private var focusedPage: DashboardUIState.Page?

    init(workTime: WorkTimeController = .shared, surface: DashboardSurface = .popover) {
        self.workTime = workTime
        self.surface = surface
    }

    var body: some View {
        VStack(spacing: 0) {
            LiveHeader(live: model.live, mascot: model.mascot,
                       agentLogCollectionEnabled: model.agentLogCollectionEnabled,
                       hidePrivateDetails: ui.hidePrivateDetails, surface: surface)
                .fixedSize(horizontal: false, vertical: true)

            navigationBar
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)

            ZStack(alignment: .top) {
                pageContent
                    .id(ui.page)
                    .transition(PanelMotion.page(reduced: reduced, forward: ui.navigatingForward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(PanelMotion.navigation(reduced: reduced), value: ui.page)

            FooterBar(surface: surface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: DashboardLayout.width, height: ui.panelHeight)
        .tint(Brand.accent)
        // Pin the background to a single, constant vibrancy so its color doesn't
        // deepen when the popover becomes key (e.g. after a click).
        .background(Brand.canvas)
        .disabled(ui.showSettings || ui.showConnections)
        .accessibilityHidden(ui.showSettings || ui.showConnections)
        .overlay {
            if ui.showConnections {
                ConnectionSettingsOverlay()
                    .transition(PanelMotion.page(reduced: reduced, forward: true))
            } else if ui.showSettings {
                SettingsOverlay()
                    .transition(PanelMotion.overlay(reduced: reduced))
            }
        }
        .animation(PanelMotion.response(reduced: reduced), value: ui.showSettings)
        .animation(PanelMotion.navigation(reduced: reduced), value: ui.showConnections)
        .transaction { if reduced { $0.animation = nil; $0.disablesAnimations = true } }
        .onAppear { model.setHistoryVisible(ui.page == .history) }
        .onChange(of: ui.page) { _, page in
            ui.showConnections = false
            model.setHistoryVisible(page == .history)
            loadSelectedHistoryDay()
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextOSPopoverOpened)) { notification in
            guard notification.object as? DashboardSurface == surface else { return }
            loadSelectedHistoryDay()
        }
        .sheet(item: $model.connectionPreview) { preview in
            ConnectionPreviewSheet(preview: preview)
                .environmentObject(model)
        }
    }

    private func loadSelectedHistoryDay() {
        guard ui.page == .history, let selectedDay = ui.selectedDay else { return }
        model.loadDetail(for: selectedDay)
    }

    @ViewBuilder
    private var navigationBar: some View {
        if ui.page == .history {
            ZStack(alignment: .leading) {
                Text(ui.page.label)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                Button { ui.navigate(to: .overview) } label: {
                    Label("대시보드", systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelPressStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("대시보드로 돌아가기")
            }
            .frame(height: 33)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(DashboardUIState.Page.primary, id: \.self) { page in
                        let selected = ui.page == page
                        Button { ui.navigate(to: page) } label: {
                            Label(page.label, systemImage: page.symbol)
                                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Brand.accent : .secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PanelPressStyle())
                        .focused($focusedPage, equals: page)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule().fill(Brand.accent).frame(width: 30, height: 2)
                                    .matchedGeometryEffect(id: "selected-page", in: navigation)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Brand.accent.opacity(focusedPage == page ? 0.75 : 0), lineWidth: 1.5)
                                .allowsHitTesting(false)
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                Divider().opacity(0.65)
            }
            .animation(PanelMotion.navigation(reduced: reduced), value: ui.page)
            .onMoveCommand { direction in
                let pages = DashboardUIState.Page.primary
                guard let current = pages.firstIndex(of: ui.page) else { return }
                let delta = direction == .right ? 1 : direction == .left ? -1 : 0
                guard delta != 0 else { return }
                let next = pages[min(pages.count - 1, max(0, current + delta))]
                ui.navigate(to: next)
                focusedPage = next
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch ui.page {
        case .overview:
            overviewPage
        case .usage:
            PopoverUsageDetail()
        case .time:
            WorkTimePanel(model: workTime, compact: true)
        case .history:
            historyPage
        }
    }

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                todaySummary
                overviewActions
                if !model.agentLogCollectionEnabled { logConsent }
                if !hasConfiguredAgent {
                    Text("AI 도구를 연결하면 필요한 프로젝트 문맥을 전달하고, 절감 기록을 여기서 확인할 수 있어요.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var hasConfiguredAgent: Bool {
        model.agents.contains { $0.connection.isConfigured }
    }

    private var todaySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompactSavingsSummary()
            Divider().opacity(0.65)
            HStack(alignment: .top, spacing: 12) {
                usageMetric
                Divider().frame(height: 48)
                OverviewDevelopmentMetric(model: workTime)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(radius: 15, padding: 12)
    }

    private var usageMetric: some View {
        let data = model.concurrentUsage.widget
        let fresh = model.hasFreshConcurrentUsage()
        let value = model.agentLogCollectionEnabled && fresh ? data.today : nil
        let detail: String
        if !model.agentLogCollectionEnabled {
            detail = "로그 집계 꺼짐"
        } else if data.providers.isEmpty {
            detail = "집계 준비 중"
        } else if !fresh {
            detail = "최신 집계 확인 중"
        } else {
            detail = data.health
        }
        return OverviewMetric(title: "오늘 AI 관측 토큰", value: UsageNumbers.compact(value), detail: detail,
                              fullValue: value.map(String.init) ?? "확인 가능한 집계 없음")
    }

    private var overviewActions: some View {
        HStack(spacing: 8) {
            Button { ui.navigate(to: .history) } label: {
                overviewAction("기록", symbol: "calendar")
            }
            .buttonStyle(PanelPressStyle())
            .help("달력, 프로젝트, 최적화 기록")
            .accessibilityHint("달력과 프로젝트 및 최적화 기록 보기")
            Button { ui.showConnections = true } label: {
                overviewAction(hasConfiguredAgent ? "AI 연결" : "AI 연결하기",
                               symbol: "link", emphasized: !hasConfiguredAgent)
            }
            .buttonStyle(PanelPressStyle())
            .help("AI 도구와 ContextOS 연결 설정")
        }
    }

    private func overviewAction(_ title: String, symbol: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(emphasized ? Brand.accent : .primary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(emphasized ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private var historyPage: some View {
        ScrollView {
            VStack(spacing: 10) {
                CalendarCard()
                PanelTabBar(selection: $ui.tab)
                ZStack(alignment: .top) {
                    switch ui.tab {
                    case .files: ProjectsList()
                    case .activity: ActivityList()
                    }
                }
                .animation(PanelMotion.feedback(reduced: reduced), value: ui.tab)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var logConsent: some View {
        Button { ui.openSettings(at: .privacy) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI 로그 집계 설정")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("AI 사용량과 작업 상태를 보려면 로컬 로그 읽기를 허용해 주세요. 대화와 도구 출력이 포함될 수 있어요.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
    }
}

/// Keeping the work clock in this small view avoids invalidating the whole overview.
private struct OverviewDevelopmentMetric: View {
    @ObservedObject var model: WorkTimeController

    var body: some View {
        let activity = model.estimatedActivity
        OverviewMetric(title: "오늘 개발 활동 추정", value: activity.formatted, detail: activity.label,
                       fullValue: activity.estimatedNanoseconds == nil ? "관측 없음" : activity.formatted)
    }
}

private struct OverviewMetric: View {
    let title: String
    let value: String
    let detail: String
    let fullValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(fullValue) · \(detail)")
    }
}

// MARK: - Shared surfaces

extension View {
    /// A content card: a faint fill and a hairline on the panel's own vibrancy.
    /// `Color.primary` flips with the appearance, so one recipe serves both.
    func dashboardCard(radius: CGFloat = 16, padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Brand.surface,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1))
    }
}
