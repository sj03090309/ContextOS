import Foundation
import Testing
@testable import ContextOSCore

@Suite("TurnActivity")
struct TurnActivityTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    @Test("nothing heard from anyone: idle, and only an event can change that")
    func idle() {
        let v = TurnActivity.evaluate(now: now, lastActivity: .distantPast,
                                      lastStop: .distantPast, lastLogWrite: nil)
        #expect(v == TurnVerdict(working: false))
    }

    @Test("a heartbeat keeps the turn alive for the window, and says when it lapses")
    func heartbeat() {
        let v = TurnActivity.evaluate(now: now, lastActivity: ago(5),
                                      lastStop: .distantPast, lastLogWrite: nil)
        #expect(v == TurnVerdict(working: true, recheckAt: ago(5).addingTimeInterval(20)))
    }

    @Test("a fresh log write keeps the turn alive, rechecked when the log goes quiet")
    func freshLog() {
        let v = TurnActivity.evaluate(now: now, lastActivity: .distantPast,
                                      lastStop: .distantPast, lastLogWrite: ago(3))
        #expect(v == TurnVerdict(working: true, recheckAt: ago(3).addingTimeInterval(20)))
    }

    @Test("with two live signals, the recheck is the earlier deadline")
    func earliestDeadline() {
        let v = TurnActivity.evaluate(now: now, lastActivity: ago(15),
                                      lastStop: .distantPast, lastLogWrite: ago(2))
        #expect(v.working)
        #expect(v.recheckAt == ago(15).addingTimeInterval(20))
    }

    @Test("a Stop after the last activity ends the turn, even with the log still warm")
    func stopWins() {
        let v = TurnActivity.evaluate(now: now, lastActivity: ago(10),
                                      lastStop: ago(1), lastLogWrite: ago(1))
        #expect(v == TurnVerdict(working: false))
    }

    @Test("activity after a Stop reopens the turn")
    func activityAfterStop() {
        let v = TurnActivity.evaluate(now: now, lastActivity: ago(1),
                                      lastStop: ago(30), lastLogWrite: nil)
        #expect(v.working)
    }

    @Test("a quiet log asks whether a tool is still running")
    func quietLogNeedsPendingCheck() {
        let v = TurnActivity.evaluate(now: now, lastActivity: .distantPast,
                                      lastStop: .distantPast, lastLogWrite: ago(60))
        #expect(v.needsPendingCheck)
    }

    @Test("an unanswered tool call keeps a quiet log alive until the cap")
    func pendingToolCall() {
        let v = TurnActivity.evaluate(now: now, lastActivity: .distantPast,
                                      lastStop: .distantPast, lastLogWrite: ago(60),
                                      pendingToolCall: true)
        #expect(v == TurnVerdict(working: true,
                                 recheckAt: ago(60).addingTimeInterval(TurnActivity.pendingToolCap)))
    }

    @Test("an answered tool call lets a quiet log go idle, with no timer needed")
    func answeredToolCall() {
        let v = TurnActivity.evaluate(now: now, lastActivity: .distantPast,
                                      lastStop: .distantPast, lastLogWrite: ago(60),
                                      pendingToolCall: false)
        #expect(v == TurnVerdict(working: false))
    }

    @Test("past the cap a log is idle without even looking at it")
    func pastTheCap() {
        let v = TurnActivity.evaluate(now: now, lastActivity: .distantPast,
                                      lastStop: .distantPast, lastLogWrite: ago(20 * 60))
        #expect(v == TurnVerdict(working: false))
    }

    @Test("matches the polling monitor's tiers at the window's edge")
    func windowEdge() {
        let inside = TurnActivity.evaluate(now: now, lastActivity: .distantPast,
                                           lastStop: .distantPast, lastLogWrite: ago(20))
        #expect(inside.working)
        #expect(inside.recheckAt == now)     // due right away, not never
        let outside = TurnActivity.evaluate(now: now, lastActivity: .distantPast,
                                            lastStop: .distantPast, lastLogWrite: ago(20.5),
                                            pendingToolCall: false)
        #expect(!outside.working)
    }
}
