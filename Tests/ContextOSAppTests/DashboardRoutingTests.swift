import Testing
@testable import ContextOSApp

@Suite("Dashboard public navigation", .serialized)
@MainActor
struct DashboardRoutingTests {
    @Test("Widget and menu routes dismiss overlays even when the destination is already selected")
    func samePageRevealsDestination() {
        let ui = DashboardUIState()
        ui.page = .usage
        ui.showConnections = true
        ui.openSettings(at: .privacy)
        #expect(ui.showSettings && !ui.showConnections)
        #expect(ui.settingsDestination == .privacy)
        ui.navigate(to: .usage)
        #expect(ui.page == .usage)
        #expect(!ui.showSettings && !ui.showConnections)
        #expect(ui.settingsDestination == nil)
    }

    @Test("The secondary history route preserves calendar, project and privacy state")
    func routePreservesOtherUIState() {
        let ui = DashboardUIState()
        #expect(DashboardUIState.Page.primary == [.overview, .usage, .time])
        ui.monthOffset = -3
        ui.selectedDay = "2026-08-17"
        ui.tab = .activity
        ui.expanded = ["fixture-project"]
        ui.usageExpanded = true
        ui.hidePrivateDetails = false
        ui.showSettings = true
        ui.navigate(to: .history)
        #expect(ui.page == .history)
        #expect(ui.navigatingForward)
        ui.showConnections = true
        ui.navigate(to: .overview)
        #expect(!ui.navigatingForward)
        #expect(!ui.showSettings && !ui.showConnections)
        #expect(ui.monthOffset == -3 && ui.selectedDay == "2026-08-17")
        #expect(ui.tab == .activity && ui.expanded == ["fixture-project"] && ui.usageExpanded)
        #expect(!ui.hidePrivateDetails)
        ui.navigate(to: .history)
        #expect(ui.page == .history && ui.selectedDay == "2026-08-17" && ui.tab == .activity)
    }
}
