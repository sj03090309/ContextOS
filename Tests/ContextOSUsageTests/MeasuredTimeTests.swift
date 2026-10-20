import Testing
import ContextOSUsage

struct MeasuredTimeTests {
    @Test func concurrentAISessionsAreAUnion() {
        var ledger = MeasuredTimeLedger()
        ledger.begin(.aiRun, id: "a", at: 0); ledger.begin(.aiRun, id: "b", at: 5)
        ledger.end(.aiRun, id: "a", at: 10); ledger.end(.aiRun, id: "b", at: 20)
        #expect(ledger.value(for: .aiRun).nanoseconds == 20)
        #expect(ledger.rangeCount == 1)
    }
    @Test func gapsAreNotFilled() {
        var ledger = MeasuredTimeLedger()
        ledger.begin(.manualTimer, id: "a", at: 0); ledger.end(.manualTimer, id: "a", at: 3)
        ledger.begin(.manualTimer, id: "b", at: 10); ledger.end(.manualTimer, id: "b", at: 14)
        #expect(ledger.value(for: .manualTimer).nanoseconds == 7)
    }
    @Test func differentMeasurementsStaySeparateAndEditsAddNoTime() {
        var ledger = MeasuredTimeLedger()
        ledger.begin(.manualTimer, id: "a", at: 0); ledger.end(.manualTimer, id: "a", at: 3)
        ledger.begin(.editorForeground, id: "b", at: 0); ledger.end(.editorForeground, id: "b", at: 10)
        ledger.observeEdit(); ledger.observeEdit()
        #expect(ledger.value(for: .manualTimer).nanoseconds == 3)
        #expect(ledger.value(for: .editorForeground).nanoseconds == 10)
        #expect(ledger.value(for: .aiRun).nanoseconds == nil)
        #expect(ledger.editEventCount == 2)
    }
    @Test func boundaryDiscardsOpenCoverageAndNeverAutoResumes() {
        var ledger = MeasuredTimeLedger()
        ledger.begin(.editorForeground, id: "a", at: 0); ledger.interrupt()
        let missingEnd = ledger.end(.editorForeground, id: "a", at: 100)
        #expect(!missingEnd)
        #expect(ledger.value(for: .editorForeground).nanoseconds == nil)
        #expect(ledger.value(for: .editorForeground).partial)
        ledger.begin(.editorForeground, id: "b", at: 110); ledger.end(.editorForeground, id: "b", at: 120)
        #expect(ledger.value(for: .editorForeground).nanoseconds == 10)
        #expect(MeasuredTimeLedger().value(for: .editorForeground).nanoseconds == nil)
    }
    @Test func replayedStartDoesNotResetAndZeroIsNotMissing() {
        var ledger = MeasuredTimeLedger()
        ledger.begin(.aiRun, id: "a", at: 10)
        let replay = ledger.begin(.aiRun, id: "a", at: 20)
        #expect(!replay)
        ledger.end(.aiRun, id: "a", at: 30)
        #expect(ledger.value(for: .aiRun).nanoseconds == 20)
        ledger.begin(.manualTimer, id: "z", at: 100); ledger.end(.manualTimer, id: "z", at: 100)
        #expect(ledger.value(for: .manualTimer).nanoseconds == 0)
    }
    @Test func backwardsClockAndLimitsAreExplicitlyPartial() {
        var ledger = MeasuredTimeLedger(maximumActive: 1, maximumRangesPerMeasurement: 2)
        ledger.begin(.aiRun, id: "a", at: 10)
        let overLimit = ledger.begin(.aiRun, id: "b", at: 11)
        let backwardsEnd = ledger.end(.aiRun, id: "a", at: 9)
        #expect(!overLimit)
        #expect(!backwardsEnd)
        #expect(ledger.value(for: .aiRun).nanoseconds == nil)
        for start: UInt64 in [20, 30, 40] {
            ledger.begin(.aiRun, id: "a", at: start); ledger.end(.aiRun, id: "a", at: start + 1)
        }
        #expect(ledger.value(for: .aiRun).nanoseconds == 2)
        #expect(ledger.value(for: .aiRun).partial)
        #expect(ledger.rangeCount == 2)
        #expect(ledger.activeCount == 0)
    }
}
