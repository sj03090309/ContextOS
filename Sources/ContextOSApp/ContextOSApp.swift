import SwiftUI
import AppKit

@main
struct ContextOSApp: App {
    @StateObject private var model = DashboardModel()

    init() {
        // Menu-bar agent: no Dock icon, no standalone window. Clicking the
        // menu-bar icon drops the full dashboard down as a panel.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardWindow().environmentObject(model)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
