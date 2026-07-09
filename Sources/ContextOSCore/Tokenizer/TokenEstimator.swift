import Foundation

/// Local, **approximate** token counter.
///
/// Anthropic ships no local tokenizer for current Claude models, and the
/// `count_tokens` API would violate ContextOS's no-network rule. So this is a
/// calibrated character-density estimate — good to roughly ±5-8% for typical
/// source, and always shown to users with a `~` prefix (never as exact).
///
/// The heart of it: token count correlates with character count, but code packs
/// more distinct tokens per character than prose (punctuation, short idents), so
/// code uses a smaller divisor.
public struct TokenEstimator: Sendable {

    /// Average characters per token for source code.
    public var charsPerTokenCode: Double
    /// Average characters per token for prose / markup.
    public var charsPerTokenProse: Double

    public init(charsPerTokenCode: Double = 3.6, charsPerTokenProse: Double = 4.0) {
        self.charsPerTokenCode = charsPerTokenCode
        self.charsPerTokenProse = charsPerTokenProse
    }

    private func divisor(for language: Language) -> Double {
        language.isCode ? charsPerTokenCode : charsPerTokenProse
    }

    /// Estimate tokens from full text.
    public func estimate(text: String, language: Language = .unknown) -> Int {
        estimate(characterCount: text.count, language: language)
    }

    /// Estimate tokens directly from a byte/char count — lets the optimizer rank
    /// files using only their indexed size, without re-reading them.
    public func estimate(characterCount: Int, language: Language) -> Int {
        guard characterCount > 0 else { return 0 }
        return Int((Double(characterCount) / divisor(for: language)).rounded(.up))
    }

    /// Abbreviated count with K/M/B suffixes, e.g. `97.6M`.
    public static func abbrev(_ tokens: Int) -> String {
        let t = Double(tokens)
        if t >= 1_000_000_000 { return String(format: "%.1fB", t / 1_000_000_000) }
        if t >= 1_000_000 { return String(format: "%.1fM", t / 1_000_000) }
        if t >= 1_000 { return String(format: "%.1fK", t / 1_000) }
        return "\(tokens)"
    }

    /// Human display for an **estimate**, e.g. `~11.2K`. The `~` signals it is
    /// approximate (used for ContextOS's own token estimates).
    public static func humanReadable(_ tokens: Int) -> String {
        "~" + abbrev(tokens)
    }
}
