import Foundation
import Combine

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
        /// Breathes while idle, chews while an agent works — the original.
        case always
        /// Holds still while idle and only chews while an agent works: the
        /// idle breath is what keeps the menu bar redrawing all day long.
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
            case .always: return "쉴 때는 숨 쉬고, AI가 일할 때는 먹어요."
            case .whileWorking: return "쉴 때는 가만히 있고, AI가 일할 때만 먹어요. 배터리를 가장 아끼는 움직임이에요."
            case .off: return "항상 가만히 있어요."
            }
        }

        /// Whether 뭉치 breathes while nothing is happening.
        var breathes: Bool { self == .always }
        /// Whether 뭉치 chews while an agent works.
        var chews: Bool { self != .off }
    }

    /// Show today's savings next to 뭉치 in the menu bar.
    @Published var showMenuBarSavings: Bool {
        didSet { defaults.set(showMenuBarSavings, forKey: Keys.menuBarSavings) }
    }

    @Published var mascotMotion: MascotMotion {
        didSet { defaults.set(mascotMotion.rawValue, forKey: Keys.mascotMotion) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let menuBarSavings = "contextos.menuBar.showSavings"
        static let mascotMotion = "contextos.mascot.motion"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarSavings = defaults.object(forKey: Keys.menuBarSavings) as? Bool ?? true
        mascotMotion = defaults.string(forKey: Keys.mascotMotion)
            .flatMap(MascotMotion.init(rawValue:)) ?? .always
    }
}
