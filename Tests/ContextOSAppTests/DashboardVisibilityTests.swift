import Testing
@testable import ContextOSApp

@Suite("Dashboard presentation lifecycle")
struct DashboardVisibilityTests {
    @Test("closing the popover keeps a live dashboard window visible")
    func twoPresentations() {
        var visibility = DashboardVisibility()
        #expect(!visibility.isVisible)
        let transition1 = visibility.open(.popover)
        #expect(transition1)
        let transition2 = visibility.open(.window)
        #expect(!transition2)
        let transition3 = visibility.close(.popover)
        #expect(!transition3)
        #expect(visibility.isVisible)
        let transition4 = visibility.close(.window)
        #expect(transition4)
        #expect(!visibility.isVisible)
    }

    @Test("reopen and duplicate close events do not duplicate refresh transitions")
    func idempotentEvents() {
        var visibility = DashboardVisibility()
        let transition5 = visibility.close(.window)
        #expect(!transition5)
        let transition6 = visibility.open(.window)
        #expect(transition6)
        let transition7 = visibility.open(.window)
        #expect(!transition7)
        let transition8 = visibility.close(.popover)
        #expect(!transition8)
        #expect(visibility.isVisible)
        let transition9 = visibility.close(.window)
        #expect(transition9)
        let transition10 = visibility.close(.window)
        #expect(!transition10)
    }

    @Test("minimize and restore resume only when the last visible presentation changes")
    func minimizeRestore() {
        var visibility = DashboardVisibility()
        let transition11 = visibility.open(.window)
        #expect(transition11)
        let transition12 = visibility.close(.window)
        #expect(transition12)
        let transition13 = visibility.open(.popover)
        #expect(transition13)
        let transition14 = visibility.open(.window)
        #expect(!transition14)
        let transition15 = visibility.close(.window)
        #expect(!transition15)
        let transition16 = visibility.open(.window)
        #expect(!transition16)
        let transition17 = visibility.close(.popover)
        #expect(!transition17)
        let transition18 = visibility.close(.window)
        #expect(transition18)
    }
}
