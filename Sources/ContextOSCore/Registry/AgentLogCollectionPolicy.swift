import Foundation
import CoreFoundation

/// The menu-bar app requires an explicit choice before it reads agent logs.
/// CLI/MCP calls are explicit operations and do not inherit the GUI's consent.
public enum AgentLogCollectionPolicy {
    public static let preferenceKey = "contextos.agentLogs.enabled"

    public static var isEnabled: Bool {
        permits(defaults: .standard, applicationBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    public static func permits(defaults: UserDefaults, applicationBundleIdentifier: String?) -> Bool {
        guard applicationBundleIdentifier == "com.contextos.app" else { return true }
        guard let stored = defaults.object(forKey: preferenceKey) as? NSNumber,
              CFGetTypeID(stored) == CFBooleanGetTypeID() else { return false }
        return stored.boolValue
    }
}
