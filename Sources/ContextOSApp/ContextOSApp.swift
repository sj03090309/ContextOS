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
            // Bolt while MCP is actively optimizing; stack icon otherwise.
            Image(systemName: model.flashing ? "bolt.fill" : "square.stack.3d.up.fill")
            if model.todaySaved > 0 {
                Text(TokenEstimator.korean(model.todaySaved))
            }
        }
    }
}
