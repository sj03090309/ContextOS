import Foundation
import Testing
@testable import ContextOSCore

@Suite("ContextAdvisor")
struct ContextAdvisorTests {
    let advisor = ContextAdvisor()

    private func selection(included: Int, excluded: Int, score: Int, tokens: Int) -> ContextSelection {
        func files(_ n: Int, tk: Int) -> [ScoredFile] {
            (0..<n).map { ScoredFile(path: "f\($0).py", language: .python, score: 1, estimatedTokens: tk, reasons: []) }
        }
        return ContextSelection(
            query: "q", terms: ["q"],
            included: files(included, tk: tokens / max(1, included)),
            excluded: files(excluded, tk: 2000),
            tokenBudget: 8000, estimatedTokens: tokens, contextScore: score
        )
    }

    @Test("warns when budget cuts relevant files and score is low")
    func budgetCut() {
        let sel = selection(included: 1, excluded: 5, score: 40, tokens: 8000)
        let advice = advisor.advise(selection: sel, fullProjectTokens: 100_000)
        #expect(advice.contains { $0.message.contains("잘렸") })
    }

    @Test("flags over-broad prompts")
    func broadPrompt() {
        let sel = selection(included: 3, excluded: 0, score: 90, tokens: 3000)
        let findings = PromptLinter().lint("analyze the entire project")
        let advice = advisor.advise(selection: sel, fullProjectTokens: 100_000, promptFindings: findings)
        #expect(advice.contains { $0.message.contains("범위") })
    }

    @Test("flags context that is a large share of the project")
    func largeShare() {
        let sel = selection(included: 10, excluded: 0, score: 90, tokens: 7000)
        let advice = advisor.advise(selection: sel, fullProjectTokens: 10_000) // 70%
        #expect(advice.contains { $0.message.contains("%") })
    }

    @Test("clean, focused selection yields no advisories")
    func clean() {
        let sel = selection(included: 3, excluded: 0, score: 95, tokens: 3000)
        #expect(advisor.advise(selection: sel, fullProjectTokens: 100_000).isEmpty)
    }
}
