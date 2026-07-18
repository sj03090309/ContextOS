import Foundation
import Testing
@testable import ContextOSCore

@Suite("ActivityHeartbeat")
struct ActivityHeartbeatTests {

    // The bug: Claude Code sends a keepalive `ping` on an idle MCP connection.
    // Treating every message as activity made the mascot eat whenever a session
    // was merely open — "터미널만 켜놨는데 먹음".
    @Test("protocol housekeeping is not agent activity")
    func housekeepingIsNotActivity() {
        #expect(!UsageStore.isAgentActivity(method: "ping"))
        #expect(!UsageStore.isAgentActivity(method: "initialize"))
        #expect(!UsageStore.isAgentActivity(method: "tools/list"))
        #expect(!UsageStore.isAgentActivity(method: "notifications/initialized"))
        #expect(!UsageStore.isAgentActivity(method: "initialized"))
        #expect(!UsageStore.isAgentActivity(method: ""))
        #expect(!UsageStore.isAgentActivity(method: "unknown/method"))
    }

    @Test("only a tool call means the agent is working")
    func toolCallIsActivity() {
        // A tool call is the one message that means the agent is actually doing
        // something on the user's behalf.
        #expect(UsageStore.isAgentActivity(method: "tools/call"))
    }
}
