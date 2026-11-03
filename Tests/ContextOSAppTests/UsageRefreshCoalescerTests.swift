import Foundation
import Testing
@testable import ContextOSApp

@Suite("Usage refresh event coalescing", .serialized)
@MainActor
struct UsageRefreshCoalescerTests {
    @Test("A write burst runs once; later writes cannot postpone the pending refresh")
    func burst() async throws {
        let coalescer = UsageRefreshCoalescer()
        var calls = 0
        for _ in 0..<500 { coalescer.schedule(after: 0.01) { calls += 1 } }
        // A slow background request must not replace an earlier deadline.
        coalescer.schedule(after: 60) { calls += 1000 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
        #expect(!coalescer.isPending)
        coalescer.schedule(after: 0.01) { calls += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 2)
    }

    @Test("Opening or suspension cancels a deferred background read")
    func cancellation() async throws {
        let coalescer = UsageRefreshCoalescer()
        var calls = 0
        coalescer.schedule(after: 0.01) { calls += 1 }
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 0)
        #expect(!coalescer.isPending)
        coalescer.schedule(after: 0.01) { calls += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }
}
