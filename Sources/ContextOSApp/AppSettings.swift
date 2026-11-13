import Foundation
import Combine
import ContextOSCore

/// The few choices the settings menu offers, kept in `UserDefaults`.
///
/// One observable object rather than scattered `@AppStorage` keys, because the
/// menu-bar item and 뭉치's renderer react to these too, and they live outside
/// any SwiftUI view.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    /// How much 뭉치 moves.
    enum MascotMotion: String, CaseIterable, Identifiable {
        /// Breathing at rest and during work, with activity transitions.
        case always
        /// Work breathing and activity transitions, with a still resting pose.
        case whileWorking
        /// Never moves.
        case off

        var id: String { rawValue }

        var label: String {
            switch self {
            case .always: return "항상"
            case .whileWorking: return "작업할 때만"
            case .off: return "멈춤"
            }
        }

        var hint: String {
            switch self {
            case .always: return "쉴 때와 작업 중에 천천히 숨을 쉬고, 최적화가 끝나면 한 번 끄덕여요."
            case .whileWorking: return "작업 중에는 천천히 숨을 쉬고, 최적화가 끝나면 한 번 끄덕여요."
            case .off: return "자세가 애니메이션 없이 바뀌어요."
            }
        }

        /// Whether 뭉치 breathes while nothing is happening.
        var breathes: Bool { self == .always }
    }

    /// Show today's savings next to 뭉치 in the menu bar.
    @Published var showMenuBarSavings: Bool {
        didSet { defaults.set(showMenuBarSavings, forKey: Keys.menuBarSavings) }
    }

    @Published var mascotMotion: MascotMotion {
        didSet { defaults.set(mascotMotion.rawValue, forKey: Keys.mascotMotion) }
    }

    @Published private(set) var mascotTint: String {
        didSet { defaults.set(mascotTint, forKey: Keys.mascotTint) }
    }

    @discardableResult
    func setMascotTint(_ value: String) -> Bool {
        guard let tint = Self.normalizedMascotTint(value) else { return false }
        if tint != mascotTint { mascotTint = tint }
        return true
    }

    static func normalizedMascotTint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.utf8.count == 6,
              hex.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return nil }
        return hex.uppercased()
    }

    /// Log files can contain conversations and tool output. A fresh install
    /// must wait for this choice even when an older build collected by default.
    @Published var agentLogsEnabled: Bool {
        didSet {
            // UserDefaults may consider numeric 1 equal to true and keep an
            // invalid legacy value. Persist the user's explicit Boolean choice.
            defaults.removeObject(forKey: AgentLogCollectionPolicy.preferenceKey)
            defaults.set(agentLogsEnabled, forKey: AgentLogCollectionPolicy.preferenceKey)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let menuBarSavings = "contextos.menuBar.showSavings"
        static let mascotMotion = "contextos.mascot.motion"
        static let mascotTint = "contextos.mascot.tint"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agentLogsEnabled = AgentLogCollectionPolicy.permits(defaults: defaults, applicationBundleIdentifier: "com.contextos.app")
        showMenuBarSavings = defaults.object(forKey: Keys.menuBarSavings) as? Bool ?? true
        mascotMotion = defaults.string(forKey: Keys.mascotMotion)
            .flatMap(MascotMotion.init(rawValue:)) ?? .whileWorking
        mascotTint = defaults.string(forKey: Keys.mascotTint)
            .flatMap(Self.normalizedMascotTint) ?? MascotColor.mint.hex
    }
}
