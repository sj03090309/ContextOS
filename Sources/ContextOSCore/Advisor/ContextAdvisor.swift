import Foundation

/// Rule-based advice about a context selection (no AI). Warns when a request is
/// too broad, when the budget cut relevant files, or when the selected context
/// is a large share of the whole project — and suggests what to do.
public struct ContextAdvisor: Sendable {

    public enum Severity: String, Sendable {
        case info
        case warning
    }

    public struct Advisory: Sendable, Equatable {
        public var severity: Severity
        public var message: String
        public init(severity: Severity, message: String) {
            self.severity = severity
            self.message = message
        }
    }

    /// Fraction of the whole project above which context is "large".
    public var largeShareThreshold: Double
    /// Context score below which a budget-cut warning fires.
    public var lowScoreThreshold: Int

    public init(largeShareThreshold: Double = 0.6, lowScoreThreshold: Int = 70) {
        self.largeShareThreshold = largeShareThreshold
        self.lowScoreThreshold = lowScoreThreshold
    }

    public func advise(
        selection: ContextSelection,
        fullProjectTokens: Int?,
        promptFindings: [PromptLinter.Finding] = []
    ) -> [Advisory] {
        var advisories: [Advisory] = []

        // 1. Prompt was flagged as over-broad.
        if promptFindings.contains(where: { $0.rule == "too-broad" }) {
            advisories.append(Advisory(
                severity: .warning,
                message: "요청 범위가 넓습니다. 특정 모듈로 좁히면 더 적은 토큰으로 정확해집니다."
            ))
        }

        // 2. Relevant files were cut by the budget.
        if !selection.excluded.isEmpty, selection.contextScore < lowScoreThreshold {
            let overflow = selection.excluded.reduce(0) { $0 + $1.estimatedTokens }
            advisories.append(Advisory(
                severity: .warning,
                message: "관련 파일 \(selection.excluded.count)개(\(TokenEstimator.humanReadable(overflow)))가 예산에 잘렸습니다. 예산을 늘리거나 쿼리를 좁혀보세요."
            ))
        }

        // 3. Selected context is a large share of the whole project.
        if let full = fullProjectTokens, full > 0 {
            let share = Double(selection.estimatedTokens) / Double(full)
            if share >= largeShareThreshold {
                advisories.append(Advisory(
                    severity: .info,
                    message: "선택된 컨텍스트가 프로젝트 전체의 \(Int(share * 100))%입니다. 범위를 좁히면 더 효율적입니다."
                ))
            }
        }

        return advisories
    }
}
