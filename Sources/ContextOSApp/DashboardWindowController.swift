import AppKit

/// The same compact, live dashboard in a normal movable window. Available to
/// everyone through the footer, app menu and reopening ContextOS from Finder.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let model: DashboardModel
    private let ui: DashboardUIState
    private var window: NSWindow?

    init(model: DashboardModel, ui: DashboardUIState) {
        self.model = model
        self.ui = ui
    }

    func show(preferredScreen: NSScreen?) {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            didOpen()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = PopoverContentController(model: model, ui: ui, surface: .window)
        content.prepare(for: preferredScreen)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.preferredContentSize),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ContextOS"
        window.identifier = NSUserInterfaceItemIdentifier("contextos-dashboard")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = content
        window.setFrameAutosaveName("ContextOSDashboard")
        if !window.setFrameUsingName("ContextOSDashboard") {
            if let screen = preferredScreen ?? NSScreen.main {
                let frame = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                              y: frame.midY - window.frame.height / 2))
            } else { window.center() }
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        didOpen()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func didOpen() {
        model.panelDidOpen(.window)
        NotificationCenter.default.post(name: .contextOSPopoverOpened, object: DashboardSurface.window)
    }

    private func didClose() {
        model.panelDidClose(.window)
        NotificationCenter.default.post(name: .contextOSPopoverClosed, object: DashboardSurface.window)
    }

    func windowWillClose(_ notification: Notification) { didClose() }
    func windowDidMiniaturize(_ notification: Notification) { didClose() }
    func windowDidDeminiaturize(_ notification: Notification) { didOpen() }
}
