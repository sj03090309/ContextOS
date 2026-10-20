import Foundation
import Testing
import ContextOSUsage

@Suite struct ModelUsageSummaryTests {
    private func session(_ id: String, model: String, provider: String = "Codex", date: Date? = nil, state: WorkState = .idle) -> ObservedSession {
        .init(id: id, agent: provider, project: "private fixture", model: model, state: state,
              lastEvent: date, todayTokens: 10, totalTokens: 100)
    }
    @Test func repeatedModelsAndUnknownNamesStayCompactWithoutDeletingSessions() {
        let names = Array(repeating: "gpt-test", count: 80) + ["unknown", " Unknown ", "", "모델 미상", "unknown-model"]
        let input = names.enumerated().map { index, name in session(String(index), model: name) }
        let groups = ModelSessionGroup.groups(input, provider: "Codex")
        #expect(groups.count == 2)
        #expect(groups.first { $0.key.model == "gpt-test" }?.sessions.count == 80)
        #expect(groups.first { $0.key.model == "모델 미상" }?.sessions.count == 5)
        #expect(groups.reduce(0) { $0 + $1.sessions.count } == input.count)
        #expect(input.count == 85)
    }
    @Test func providerIdentityAndExactKnownNamesDoNotMergeByGuessing() {
        let input = [session("a", model: "same"), session("b", model: "same", provider: "Claude Code"), session("c", model: "same-version-2")]
        #expect(ModelSessionGroup.groups(input, provider: "Codex").count == 2)
        #expect(ModelSessionGroup.groups(input, provider: "Claude Code").count == 1)
        #expect(UsageModelKey(provider: "Codex", model: "same") != UsageModelKey(provider: "Claude Code", model: "same"))
    }
    @Test func repeatedSessionIdentityCannotInflateStatusCounts() {
        let now = Date()
        let old = session("same-id", model: "old", date: now.addingTimeInterval(-5))
        let latest = session("same-id", model: "new", date: now, state: .working)
        let input = [old, old, latest, latest]
        let groups = ModelSessionGroup.groups(input, provider: "Codex")
        #expect(groups.count == 1)
        #expect(groups.first?.working == 1)
        #expect(groups.first?.sessions.count == 1)
        #expect(groups.first?.key.model == "new")
    }
    @Test func previewRetainsFullTotalsAndExactHiddenCounts() {
        let models = (1...20).map { TodayModelUsage(provider: "Codex", model: "model-\($0)", tokens: Int64($0)) }
        let preview = ModelUsagePreview(models)
        #expect(preview.visible.count == 3 && preview.hiddenCount == 17)
        #expect(preview.totalTokens == 210)
        #expect(preview.hiddenTokens + preview.visible.map(\.tokens).reduce(0, UsageNumbers.add) == 210)
        let all = ModelUsagePreview(models, expanded: true)
        #expect(all.visible.count == 20 && all.hiddenCount == 0 && all.hiddenTokens == 0)
        #expect(all.totalTokens == preview.totalTokens)
    }
    @Test func emptyLongNamesAndSaturationAreStable() {
        #expect(ModelUsagePreview([]).hiddenCount == 0)
        #expect(ModelSessionGroup.groups([], provider: "Codex").isEmpty)
        let long = String(repeating: "very-long-model-", count: 100)
        #expect(UsageModelKey(provider: "Codex", model: long).model == long)
        let models = [TodayModelUsage(provider: "Codex", model: "b", tokens: .max), .init(provider: "Codex", model: "a", tokens: .max)]
        #expect(ModelUsagePreview(models).totalTokens == .max)
        #expect(TodayModelUsage.ordered(models).first?.key.model == "a")
    }
}
