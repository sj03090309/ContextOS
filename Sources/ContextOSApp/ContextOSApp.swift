import SwiftUI
import AppKit

@main
struct ContextOSApp: App {
    @StateObject private var model = DashboardModel()

    init() {
        // Menu-bar-only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView().environmentObject(model)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
