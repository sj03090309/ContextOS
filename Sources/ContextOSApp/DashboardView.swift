import SwiftUI
import AppKit
import ContextOSCore

/// The ContextOS brand palette — the ink + cream of the app icon (뭉치 in cream
/// on a charcoal tile), used consistently across the dashboard.
enum Brand {
    static let cream = Color(red: 0.937, green: 0.906, blue: 0.839)      // #EFE7D6
    static let ink = Color(red: 0.090, green: 0.090, blue: 0.106)        // #17171B

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

    /// The mascot inverts with the appearance like the accent does — a static
    /// cream blob would vanish on the light popover material. Dark: cream blob
    /// with ink eyes (the icon). Light: ink blob with cream eyes (its negative).
    static let blobTop = adaptive(
        dark: NSColor(calibratedRed: 0.953, green: 0.925, blue: 0.867, alpha: 1),   // #F3ECDD
        light: NSColor(calibratedRed: 0.180, green: 0.180, blue: 0.212, alpha: 1))  // #2E2E36
    static let blobBottom = adaptive(
        dark: NSColor(calibratedRed: 0.894, green: 0.851, blue: 0.765, alpha: 1),   // #E4D9C3
        light: inkNS)                                                                // #17171B
    static let mascotEye = adaptive(
        dark: NSColor(calibratedWhite: 0.12, alpha: 1),
        light: creamNS)
    /// The warmth around 뭉치 while it eats: a cream aura on the dark panel, and
    /// only a faint shade on the light one, where a dark glow reads as a smudge.
    static let mascotGlow = adaptive(
        dark: NSColor(calibratedRed: 0.953, green: 0.925, blue: 0.867, alpha: 1),
        light: NSColor(calibratedWhite: 0.1, alpha: 0.35))

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

/// Which "screen" the segmented control shows — keeps the panel short by
/// showing one system at a time instead of stacking every section.
enum DashboardTab: Hashable, CaseIterable {
    case files, activity, ai

    var label: String {
        switch self {
        case .files: return "프로젝트"
        case .activity: return "활동"
        case .ai: return "AI 연결"
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
    @Published var tab: DashboardTab = .files
    @Published var expanded: Set<String> = []   // expanded project cards
    /// Months back from the current one.
    @Published var monthOffset = 0
    @Published var selectedDay: String?
    @Published var showSettings = false
}

/// The menu-bar monitor: 뭉치 melting into the top of a translucent panel, a
/// live line saying who is working where, the savings hero, the month in AI
/// tokens, and three tabs — projects, activity, AI connections.
struct DashboardView: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject private var ui: DashboardUIState

    var body: some View {
        VStack(spacing: 0) {
            // 뭉치 is *not* in this tree — it is a sibling hosting view laid over
            // this space by `PopoverContentController`. Sharing one SwiftUI tree
            // with a 20fps animation made every mascot frame re-run the whole
            // panel's view graph (calendar cells, project cards and all), which
            // cost 16% of a core; split apart, each redraws on its own.
            Color.clear.frame(height: PopoverContentController.mascotHeight)

            LiveHeader(live: model.live,
                       configured: model.agents.filter { $0.connection.isConfigured }.count)
                .padding(.horizontal, 18)

            HeroSection()
                .padding(.horizontal, 18)
                .padding(.top, 12)

            CalendarCard()
                .padding(.horizontal, 14)
                .padding(.top, 12)

            PanelTabBar(selection: $ui.tab)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            // Fixed height: a card expanding or a tab switching must not change
            // the content height, or NSPopover resizes the whole window in an
            // unanimated jump. Long lists scroll inside instead.
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch ui.tab {
                    case .files: ProjectsList()
                    case .activity: ActivityList()
                    case .ai: AgentsList()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
            }
            .frame(height: 188)
            .padding(.top, 8)

            FooterBar()
        }
        .frame(width: 340)
        .tint(Brand.accent)
        // Pin the background to a single, constant vibrancy so its color doesn't
        // deepen when the popover becomes key (e.g. after a click).
        .background(VisualEffectBackground())
        .overlay {
            if ui.showSettings {
                SettingsOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.22), value: ui.showSettings)
    }
}

// MARK: - Shared surfaces

extension View {
    /// A content card: a faint fill and a hairline on the panel's own vibrancy.
    /// `Color.primary` flips with the appearance, so one recipe serves both.
    func dashboardCard(radius: CGFloat = 16, padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

/// A translucent panel background pinned to the `.active` state, so its color
/// stays constant instead of deepening when the popover window gains/loses key
/// focus (which is what made a click "darken" the dashboard).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}
