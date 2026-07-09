import SwiftUI
import AppKit
import ContextOSCore

@main
struct ContextOSApp: App {
    @StateObject private var model = DashboardModel()

    init() {
        // Menu-bar agent: no Dock icon, no standalone window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The live menu-bar label: icon + today's saved tokens, flashing on activity.
struct MenuBarLabel: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        HStack(spacing: 3) {
            // Bolt while MCP is actively optimizing; sparkles otherwise. Rendered
            // monochrome (template) so it adapts to the light/dark menu bar.
            Image(systemName: model.flashing ? "bolt.fill" : "sparkles")
            if model.todaySaved > 0 {
                Text(TokenEstimator.korean(model.todaySaved))
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }
}
