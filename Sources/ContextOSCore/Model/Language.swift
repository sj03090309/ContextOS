import Foundation

/// A source language ContextOS knows how to index.
///
/// M1 uses this only for detection + display. The parser layer keys off it to
/// pick a `LanguageParser` implementation.
public enum Language: String, Sendable, CaseIterable {
    case swift
    case python
    case javascript
    case typescript
    case go
    case rust
    case java
    case kotlin
    case c
    case cpp
    case ruby
    case objectiveC
    case unknown

    /// Best-effort detection from a file extension (without the leading dot).
    public static func detect(fromExtension ext: String) -> Language {
        switch ext.lowercased() {
        case "swift": return .swift
        case "py", "pyi": return .python
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "c": return .c
        case "h", "hpp", "hh", "cc", "cpp", "cxx": return .cpp
        case "rb": return .ruby
        case "m", "mm": return .objectiveC
        default: return .unknown
        }
    }

    /// Whether this is source code (denser tokenization) vs prose/markup.
    public var isCode: Bool {
        self != .unknown
    }

    public var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .go: return "Go"
        case .rust: return "Rust"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .c: return "C"
        case .cpp: return "C++"
        case .ruby: return "Ruby"
        case .objectiveC: return "Objective-C"
        case .unknown: return "Unknown"
        }
    }
}
