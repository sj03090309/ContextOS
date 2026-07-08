import Foundation

/// Extracts symbols + import edges from a file's source.
///
/// This is the seam that keeps Tree-sitter out of M1's critical path. M1 ships
/// `HeuristicParser`; a `TreeSitterParser` can be dropped in later behind the
/// same protocol without touching the Indexer or Store.
public protocol LanguageParser: Sendable {
    /// Languages this parser can handle.
    func supports(_ language: Language) -> Bool
    /// Parse source text for the given language.
    func parse(source: String, language: Language) -> ParsedFile
}
