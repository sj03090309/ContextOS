import Testing
@testable import ContextOSApp

@Suite("Dashboard public navigation", .serialized)
@MainActor
struct DashboardRoutingTests {
    @Test("Widget and menu routes dismiss overlays even when the destination is already selected")
    func samePageRevealsDestination() {
        let ui = DashboardUIState()
        ui.page = .usage
        ui.showSettings = true
        ui.showConnections = true
        ui.navigate(to: .usage)
        #expect(ui.page == .usage)
        #expect(!ui.showSettings && !ui.showConnections)
    }

    @Test("Public routes preserve history selections, disclosures and privacy choices")
    func routePreservesOtherUIState() {
        let ui = DashboardUIState()
        ui.monthOffset = -3
        ui.selectedDay = "2026-08-17"
        ui.historyExpanded = true
        ui.expanded = ["fixture-project"]
        ui.usageExpanded = true
        ui.hidePrivateDetails = false
        ui.showSettings = true
        ui.navigate(to: .time)
        #expect(ui.navigatingForward)
        ui.showConnections = true
        ui.navigate(to: .overview)
        #expect(!ui.navigatingForward)
        #expect(!ui.showSettings && !ui.showConnections)
        #expect(ui.monthOffset == -3 && ui.selectedDay == "2026-08-17")
        #expect(ui.historyExpanded && ui.expanded == ["fixture-project"] && ui.usageExpanded)
        #expect(!ui.hidePrivateDetails)
    }
}
