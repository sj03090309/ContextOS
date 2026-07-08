import Foundation

/// Rule-based prompt checker (no AI). It never rewrites the prompt — it only
/// flags issues that tend to make Claude Code burn context or miss the target,
/// and suggests what to add.
public struct PromptLinter: Sendable {

    public enum Severity: String, Sendable {
        case info
        case warning
    }

    public struct Finding: Sendable, Equatable {
        public var rule: String
        public var severity: Severity
        public var message: String
        public var suggestion: String

        public init(rule: String, severity: Severity, message: String, suggestion: String) {
            self.rule = rule
            self.severity = severity
            self.message = message
            self.suggestion = suggestion
        }
    }

    public init() {}

    /// Words signalling an over-broad request (EN + KO).
    private static let broadScope: Set<String> = [
        "everything", "entire", "whole", "all", "full", "complete",
        "전체", "모든", "다", "전부", "통째로"
    ]

    /// Imperative "do something" words that, alone, carry no target.
    private static let vagueVerbs: Set<String> = [
        "fix", "update", "change", "improve", "refactor", "help", "review",
        "고쳐", "고쳐줘", "수정", "해줘", "바꿔", "개선", "도와줘"
    ]

    /// Analyze a prompt, returning findings (empty = looks good).
    public func lint(_ prompt: String) -> [Finding] {
        var findings: [Finding] = []
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerWords = Set(TextTokens.subwords(of: trimmed))
        let signalTerms = TextTokens.queryTerms(trimmed)

        // 1. Empty / trivially short.
        if trimmed.count < 3 {
            findings.append(Finding(
                rule: "too-short",
                severity: .warning,
                message: "프롬프트가 너무 짧아 작업을 특정할 수 없습니다.",
                suggestion: "무엇을 어디서 바꿀지 설명하세요. 예: “auth의 로그인 토큰 만료 시간 수정”."
            ))
            return findings
        }

        // 2. No concrete target: only stopwords / vague verbs survived.
        let hasVagueVerb = !lowerWords.isDisjoint(with: Self.vagueVerbs)
        if signalTerms.isEmpty {
            findings.append(Finding(
                rule: "no-target",
                severity: .warning,
                message: hasVagueVerb
                    ? "무엇을 할지는 있지만 어떤 기능인지 입력하면 더 정확합니다."
                    : "구체적인 기능·파일·함수명이 없습니다.",
                suggestion: "기능/파일/함수 이름을 추가하면 ContextOS가 올바른 파일을 선택할 수 있습니다."
            ))
        }

        // 3. Over-broad scope.
        if !lowerWords.isDisjoint(with: Self.broadScope) {
            findings.append(Finding(
                rule: "too-broad",
                severity: .warning,
                message: "전체 프로젝트 범위를 요청해 컨텍스트가 커집니다.",
                suggestion: "모듈이나 디렉토리로 범위를 좁혀보세요. 예: “Backend만”, “auth 모듈만”."
            ))
        }

        return findings
    }
}
