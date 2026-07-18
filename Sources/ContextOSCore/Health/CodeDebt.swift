import Foundation

/// A kind of code debt ContextOS can measure **exactly, from local files**.
///
/// Every case here is a fact you could verify by hand. Things that only look
/// measurable are deliberately absent — see `CodeDebtReader`.
public enum DebtKind: String, Sendable, CaseIterable, Codable {
    /// No symbol declared in the file is ever named in a test.
    case untested
    /// A TODO/FIXME/HACK that has been sitting there for months.
    case staleTodo
    /// A function that is very long, or very branchy, or both.
    case largeFunction
    /// Two or more functions with an identical body.
    case duplicateFunction

    public var label: String {
        switch self {
        case .untested: return "테스트 없는 파일"
        case .staleTodo: return "오래된 TODO"
        case .largeFunction: return "거대 함수"
        case .duplicateFunction: return "중복 함수"
        }
    }

    /// The rule that produced the count, shown next to it. The user should never
    /// have to guess why something was flagged.
    public func rule(_ thresholds: DebtThresholds) -> String {
        switch self {
        case .untested: return "심볼이 테스트에 한 번도 안 나옴"
        case .staleTodo: return "\(thresholds.staleTodoDays / 30)개월 이상 방치"
        case .largeFunction: return "\(thresholds.largeFunctionLines)줄 초과 또는 분기 \(thresholds.complexBranches)개 초과"
        case .duplicateFunction: return "본문이 완전히 같음 (\(thresholds.minDuplicateLines)줄 이상)"
        }
    }

    public var symbolName: String {
        switch self {
        case .untested: return "testtube.2"
        case .staleTodo: return "clock.badge.exclamationmark"
        case .largeFunction: return "arrow.up.and.down.text.horizontal"
        case .duplicateFunction: return "doc.on.doc"
        }
    }
}

/// Where each detector draws its line.
///
/// These are judgement calls, not laws — which is exactly why they are named,
/// adjustable, and shown in the UI beside every count.
public struct DebtThresholds: Sendable {
    /// A function longer than this doesn't fit on a screen twice.
    public var largeFunctionLines: Int
    /// Approximate cyclomatic complexity above which a function is hard to hold
    /// in your head.
    public var complexBranches: Int
    /// A TODO older than this has stopped being a plan and become a comment.
    public var staleTodoDays: Int
    /// Shorter identical bodies (getters, `return nil`) are coincidence, not duplication.
    public var minDuplicateLines: Int

    public init(largeFunctionLines: Int = 80, complexBranches: Int = 15,
                staleTodoDays: Int = 180, minDuplicateLines: Int = 5) {
        self.largeFunctionLines = largeFunctionLines
        self.complexBranches = complexBranches
        self.staleTodoDays = staleTodoDays
        self.minDuplicateLines = minDuplicateLines
    }
}

/// One thing worth fixing, at a place you can open.
public struct DebtItem: Sendable, Identifiable, Equatable {
    public var kind: DebtKind
    /// Project-relative path.
    public var path: String
    public var line: Int
    public var title: String
    /// The measurement itself — "247줄 · 분기 34", "8개월 전". Never a grade.
    public var detail: String
    /// Ranking weight; larger is worse. Only meaningful within one kind.
    public var severity: Double

    public var id: String { "\(kind.rawValue):\(path):\(line)" }

    public init(kind: DebtKind, path: String, line: Int, title: String,
                detail: String, severity: Double) {
        self.kind = kind
        self.path = path
        self.line = line
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

/// What a project owes, as counted facts.
public struct CodeDebt: Sendable {
    public var items: [DebtItem] = []
    public var counts: [DebtKind: Int] = [:]
    /// Change since the oldest snapshot in the trend window. `nil` means there is
    /// no baseline yet — snapshots only start accumulating once you run this.
    public var deltas: [DebtKind: Int] = [:]
    public var filesScanned = 0
    public var thresholds = DebtThresholds()

    public init() {}

    /// Items of one kind, worst first.
    public func items(_ kind: DebtKind) -> [DebtItem] {
        items.filter { $0.kind == kind }.sorted { $0.severity > $1.severity }
    }

    public var isClean: Bool { items.isEmpty }
}

/// Measures code debt from the project's own files.
///
/// ## No score
/// There is deliberately no "health: 87/100". Any such number needs weights —
/// why is test coverage 30% and TODOs 10%? — and there is no honest answer, so
/// the number would be invented precision. Worse, it doesn't tell you what to
/// do: 87 → 84 is not an instruction, while "PathResolution.swift has no tests"
/// is. Counts of specific, clickable facts are strictly more useful and strictly
/// more honest.
///
/// ## No dependency freshness
/// "Outdated dependency" is not measurable offline, and not by a little. A
/// lockfile pins a version; knowing a *newer* one exists means asking the
/// registry. The local SPM checkout is no help — its newest tag is always the
/// resolved version, because it was fetched at resolution time. So the only way
/// to answer is a network call that (a) breaks ContextOS's local-only promise
/// and (b) ships your dependency list to someone else's server. Dependabot and
/// Renovate already do this well, with the network access it actually requires.
///
/// ## What the numbers are not
/// Every detector here is a heuristic with a visible rule, not a verdict. An
/// untested file may be exercised indirectly; a long function may be a lookup
/// table. The point is to surface candidates you can look at, not to grade.
public enum CodeDebtReader {

    // MARK: - Entry point

    /// Analyze a project. Results are memoized briefly — this reads every source
    /// file, so it is far too heavy for the dashboard's polling loop and is only
    /// run when someone actually looks at it.
    public static func analyze(root: URL,
                               thresholds: DebtThresholds = DebtThresholds(),
                               maxAge: Double = 60,
                               force: Bool = false) -> CodeDebt {
        let now = Date().timeIntervalSince1970
        if !force {
            memoLock.lock()
            let hit = memo[root.path]
            memoLock.unlock()
            if let hit, now - hit.at < maxAge { return hit.debt }
        }
        var debt = build(root: root, thresholds: thresholds)
        debt.deltas = recordAndCompareSnapshot(root: root, counts: debt.counts)
        memoLock.lock()
        memo[root.path] = Memo(debt: debt, at: now)
        memoLock.unlock()
        return debt
    }

    private struct Memo { var debt: CodeDebt; var at: Double }
    nonisolated(unsafe) private static var memo: [String: Memo] = [:]
    private static let memoLock = NSLock()

    public static func invalidate() {
        memoLock.lock()
        memo.removeAll()
        memoLock.unlock()
    }

    // MARK: - Analysis

    /// What reading one file tells us. Produced in parallel, merged afterwards.
    struct FileFindings: Sendable {
        var path = ""
        var isTest = false
        /// Every identifier in the file — only collected for test files, to
        /// answer "is this symbol ever named in a test?".
        var identifiers: Set<String> = []
        /// Symbol names the file declares.
        var declared: Set<String> = []
        var todos: [(line: Int, text: String)] = []
        var large: [DebtItem] = []
        var bodies: [(hash: String, line: Int, name: String, lines: Int)] = []
    }

    static func build(root: URL, thresholds: DebtThresholds) -> CodeDebt {
        var debt = CodeDebt()
        debt.thresholds = thresholds

        guard let scanned = try? ProjectScanner().scan(root: root) else { return debt }
        let parser = HeuristicParser()
        let candidates = scanned.filter { parser.supports($0.language) }
        guard !candidates.isEmpty else { return debt }

        // Reading and parsing every source file is the whole cost here, and each
        // file is independent — so do them at once. Serially this is ~4ms/file,
        // which a large repo turns into an unusable wait.
        let collected = Collector()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            guard let finding = examine(candidates[index], parser: parser, thresholds: thresholds)
            else { return }
            collected.add(finding)
        }
        merge(collected.all, root: root, thresholds: thresholds, into: &debt)
        return debt
    }

    /// Gathers per-file results off the parallel workers. The lock is held only
    /// for the append, so the file reads and parses still run concurrently.
    private final class Collector: @unchecked Sendable {
        private var storage: [FileFindings] = []
        private let lock = NSLock()

        func add(_ finding: FileFindings) {
            lock.lock()
            storage.append(finding)
            lock.unlock()
        }

        /// Path-ordered, so the report doesn't reshuffle between runs.
        var all: [FileFindings] {
            lock.lock()
            defer { lock.unlock() }
            return storage.sorted { $0.path < $1.path }
        }
    }

    /// Everything one file contributes, computed from a single read.
    static func examine(_ file: ScannedFile, parser: HeuristicParser,
                        thresholds: DebtThresholds) -> FileFindings? {
        guard let source = try? String(contentsOf: file.absoluteURL, encoding: .utf8) else { return nil }
        var findings = FileFindings()
        findings.path = file.relativePath
        findings.todos = markers(in: source)

        if isTestPath(file.relativePath) {
            findings.isTest = true
            findings.identifiers = identifiers(in: source)
            return findings
        }

        let parsed = parser.parse(source: source, language: file.language)
        findings.declared = Set(parsed.symbols.map(\.name))
        let lines = source.components(separatedBy: "\n")

        for symbol in parsed.symbols
        where symbol.kind == .function || symbol.kind == .method {
            guard symbol.endLine <= lines.count, symbol.endLine >= symbol.line else { continue }
            let span = symbol.endLine - symbol.line + 1
            let body = lines[(symbol.line - 1)..<symbol.endLine].joined(separator: "\n")
            let branches = branchCount(in: body, language: file.language)

            if span > thresholds.largeFunctionLines || branches > thresholds.complexBranches {
                findings.large.append(DebtItem(
                    kind: .largeFunction, path: file.relativePath, line: symbol.line,
                    title: symbol.name, detail: "\(span)줄 · 분기 \(branches)",
                    // Rank by whichever limit it blows through hardest, so a
                    // short-but-gnarly function isn't buried under long ones.
                    severity: max(Double(span) / Double(thresholds.largeFunctionLines),
                                  Double(branches) / Double(thresholds.complexBranches))))
            }
            if let hash = normalizedBodyHash(body, language: file.language,
                                             minLines: thresholds.minDuplicateLines) {
                findings.bodies.append((hash, symbol.line, symbol.name, span))
            }
        }
        return findings
    }

    /// Fold per-file findings into the answers that need the whole project:
    /// which symbols tests mention, and which bodies repeat across files.
    static func merge(_ findings: [FileFindings], root: URL,
                      thresholds: DebtThresholds, into debt: inout CodeDebt) {
        debt.filesScanned = findings.count
        // nil = no manifest to ask, so nothing is ruled out.
        let testableRoots = testableRoots(root: root)

        var testIdentifiers: Set<String> = []
        for finding in findings where finding.isTest { testIdentifiers.formUnion(finding.identifiers) }

        var bodyHashes: [String: [(path: String, line: Int, name: String, lines: Int)]] = [:]
        var todosByFile: [String: [(line: Int, text: String)]] = [:]

        for finding in findings {
            if !finding.todos.isEmpty { todosByFile[finding.path] = finding.todos }
            guard !finding.isTest else { continue }
            debt.items += finding.large
            for body in finding.bodies {
                bodyHashes[body.hash, default: []].append(
                    (finding.path, body.line, body.name, body.lines))
            }
            // Untested: nothing this file declares is ever named in a test. Only
            // asked of files the project declares as library code — a script no
            // target owns has no module to import, so "untested" would be a
            // complaint the user could never act on.
            let isLibraryCode = testableRoots.map { roots in
                roots.contains { finding.path.hasPrefix($0) }
            } ?? true
            guard isLibraryCode,
                  !finding.declared.isEmpty,
                  finding.declared.isDisjoint(with: testIdentifiers) else { continue }
            debt.items.append(DebtItem(
                kind: .untested, path: finding.path, line: 1,
                title: (finding.path as NSString).lastPathComponent,
                detail: "심볼 \(finding.declared.count)개 · 어떤 테스트에도 안 나옴",
                severity: Double(finding.declared.count)))
        }

        debt.items += duplicateItems(bodyHashes)
        debt.items += staleTodoItems(root: root, todos: todosByFile, thresholds: thresholds)

        for kind in DebtKind.allCases {
            debt.counts[kind] = debt.items.filter { $0.kind == kind }.count
        }
    }

    // MARK: - Untested

    /// Paths that look like tests. Covers the conventions of the languages the
    /// parser supports; anything unrecognized is treated as source, which is the
    /// safe direction (a missed test file can only cause a false "untested").
    static func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        for directory in ["tests/", "test/", "spec/", "__tests__/", "testing/"]
        where lower.hasPrefix(directory) || lower.contains("/" + directory) {
            return true
        }
        if name.hasSuffix("test.swift") || name.hasSuffix("tests.swift") { return true }
        if name.hasPrefix("test_") || name.hasSuffix("_test.py") { return true }
        if name.hasSuffix("_test.go") { return true }
        if name.hasSuffix("_spec.rb") || name.hasSuffix("_test.rb") { return true }
        for suffix in [".test.js", ".test.ts", ".test.jsx", ".test.tsx",
                       ".spec.js", ".spec.ts", ".spec.jsx", ".spec.tsx"]
        where name.hasSuffix(suffix) {
            return true
        }
        return false
    }

    /// Source roots the project itself declares as **library** code — the only
    /// files a unit test could ever import and exercise.
    ///
    /// This is an inclusion rule read from the manifest, not a blocklist of
    /// folder names, because the project already knows the answer. A build
    /// script, a sample, a loose `.swift` file in `scripts/` — none of them
    /// belong to a target, so no test can reach them. They aren't untested
    /// library code; they aren't library code at all. Executable targets are out
    /// for the same reason: there's no module to `@testable import`.
    ///
    /// Returns nil when there is no manifest to ask. Then everything is in
    /// scope — the honest default is to admit we don't know rather than invent
    /// a rule about which directories "look like" tooling.
    static func testableRoots(root: URL) -> [String]? {
        guard let manifest = try? String(contentsOf: root.appendingPathComponent("Package.swift"),
                                         encoding: .utf8) else { return nil }
        // `.target` and `.macro` produce importable modules. `.executableTarget`,
        // `.testTarget`, `.binaryTarget`, `.systemLibrary` and `.plugin` do not.
        var roots: [String] = []
        for kind in ["target", "macro"] {
            for declaration in declarations(of: kind, in: manifest) {
                guard let name = value(of: "name", in: declaration) else { continue }
                if let declared = value(of: "path", in: declaration) {
                    roots.append(trailingSlash(declared))
                } else if let conventional = conventionalSourceDir(name: name, root: root) {
                    roots.append(conventional)
                }
            }
        }
        // A manifest with no library targets at all (an app-only package) would
        // otherwise silently put every file out of scope. Say "no manifest" and
        // let the caller analyze everything instead.
        return roots.isEmpty ? nil : roots
    }

    /// The bodies of every `.<kind>( … )` call in the manifest, paren-balanced so
    /// nested arrays and `.product(…)` entries don't end the match early.
    static func declarations(of kind: String, in manifest: String) -> [Substring] {
        var out: [Substring] = []
        var search = manifest.startIndex
        // `.target(` is not a substring of `.executableTarget(` or `.testTarget(`,
        // so a literal search already distinguishes the kinds.
        while let found = manifest.range(of: ".\(kind)(", range: search..<manifest.endIndex) {
            search = found.upperBound
            var depth = 1
            var index = found.upperBound
            var inString = false
            while index < manifest.endIndex, depth > 0 {
                let character = manifest[index]
                if inString {
                    if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
                index = manifest.index(after: index)
            }
            guard depth == 0 else { break }        // unbalanced manifest; stop
            out.append(manifest[found.upperBound..<manifest.index(before: index)])
            search = index
        }
        return out
    }

    /// `label: "value"` from a declaration body, ignoring nested calls.
    static func value(of label: String, in declaration: Substring) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(label)\\s*:\\s*\"([^\"]+)\"") else {
            return nil
        }
        let text = String(declaration)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    /// SPM's default locations for a target's sources, resolved against disk so
    /// the layout the project actually uses is the one we trust.
    static func conventionalSourceDir(name: String, root: URL) -> String? {
        for parent in ["Sources", "Source", "src", "srcs"] {
            let candidate = "\(parent)/\(name)"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path,
                                              isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate + "/"
            }
        }
        return nil
    }

    private static func trailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// Every identifier-looking token in a source text.
    static func identifiers(in source: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for character in source.unicodeScalars {
            if CharacterSet.alphanumerics.contains(character) || character == "_" {
                current.unicodeScalars.append(character)
            } else if !current.isEmpty {
                out.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { out.insert(current) }
        return out
    }

    // MARK: - TODOs

    static let markerPattern = "TODO|FIXME|HACK|XXX"

    /// TODO-style markers, as (line, text). Matches the marker as a whole word so
    /// a variable named `todoCount` doesn't register.
    static func markers(in source: String) -> [(line: Int, text: String)] {
        guard source.contains("TODO") || source.contains("FIXME")
                || source.contains("HACK") || source.contains("XXX") else { return [] }
        guard let regex = try? NSRegularExpression(pattern: "\\b(\(markerPattern))\\b") else { return [] }

        var out: [(Int, String)] = []
        var number = 0
        source.enumerateLines { line, _ in
            number += 1
            let range = NSRange(line.startIndex..., in: line)
            guard regex.firstMatch(in: line, range: range) != nil else { return }
            out.append((number, line.trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    /// Age each marker via `git blame`, and keep the ones that have gone stale.
    ///
    /// Age is the whole point: 143 TODOs is not a finding, but a TODO nobody has
    /// touched in eight months is.
    static func staleTodoItems(root: URL, todos: [String: [(line: Int, text: String)]],
                               thresholds: DebtThresholds) -> [DebtItem] {
        guard !todos.isEmpty else { return [] }
        let now = Date().timeIntervalSince1970
        let cutoff = Double(thresholds.staleTodoDays) * 86_400
        var out: [DebtItem] = []

        for (path, markers) in todos {
            let ages = blameTimes(root: root, path: path)
            for marker in markers {
                // No blame entry means the line is uncommitted — brand new, so
                // by definition not stale.
                guard let authored = ages[marker.line] else { continue }
                let age = now - authored
                guard age >= cutoff else { continue }
                out.append(DebtItem(
                    kind: .staleTodo, path: path, line: marker.line,
                    title: String(marker.text.prefix(90)),
                    detail: humanAge(age) + " 전",
                    severity: age))
            }
        }
        return out
    }

    /// line → author time, from one `git blame` per file.
    static func blameTimes(root: URL, path: String) -> [Int: Double] {
        guard let out = GitRunner.run(["blame", "--porcelain", "--", path], in: root) else { return [:] }
        var times: [Int: Double] = [:]
        var pending: [Int] = []
        out.enumerateLines { line, _ in
            // Header: "<sha> <origLine> <finalLine> [<count>]"
            if line.count > 40, let first = line.split(separator: " ").first,
               first.count == 40, first.allSatisfy({ $0.isHexDigit }) {
                let parts = line.split(separator: " ")
                if parts.count >= 3, let final = Int(parts[2]) { pending = [final] }
            } else if line.hasPrefix("author-time "),
                      let seconds = Double(line.dropFirst("author-time ".count)) {
                for number in pending { times[number] = seconds }
                pending = []
            }
        }
        return times
    }

    static func humanAge(_ seconds: Double) -> String {
        let days = Int(seconds / 86_400)
        if days >= 365 { return "\(days / 365)년" }
        if days >= 30 { return "\(days / 30)개월" }
        if days >= 1 { return "\(days)일" }
        return "오늘"
    }

    // MARK: - Complexity

    /// Branch keywords that each add a path through a function — a standard
    /// approximation of cyclomatic complexity, good enough to rank by.
    private static let branchWords = ["if", "for", "while", "case", "catch",
                                      "guard", "elif", "except", "rescue", "when"]

    /// Roughly how many decisions a function body makes.
    static func branchCount(in body: String, language: Language) -> Int {
        let code = stripLiteralsAndComments(body, language: language)
        var count = 0
        // `&&`, `||`, and `?:` each fork the flow too.
        for operatorText in ["&&", "||", " ? "] {
            count += code.components(separatedBy: operatorText).count - 1
        }
        let words = code.split(whereSeparator: { !$0.isLetter && $0 != "_" })
        for word in words where branchWords.contains(String(word)) { count += 1 }
        return count
    }

    /// Blank out string literals and comments so their contents can't be counted
    /// as code — a `"if you see this"` message is not a branch.
    static func stripLiteralsAndComments(_ source: String, language: Language) -> String {
        let hashComments = (language == .python || language == .ruby)
        var out = ""
        var inString: Character?
        var inLineComment = false
        var inBlockComment = false
        var previous: Character = " "

        for character in source {
            if inLineComment {
                if character == "\n" { inLineComment = false; out.append(character) }
                continue
            }
            if inBlockComment {
                if previous == "*" && character == "/" { inBlockComment = false }
                previous = character
                continue
            }
            if let quote = inString {
                if character == quote && previous != "\\" { inString = nil }
                previous = character
                continue
            }
            if character == "\"" || character == "'" { inString = character; previous = character; continue }
            if hashComments, character == "#" { inLineComment = true; continue }
            if !hashComments, previous == "/", character == "/" {
                inLineComment = true
                out.removeLast()          // drop the first slash already emitted
                continue
            }
            if !hashComments, previous == "/", character == "*" {
                inBlockComment = true
                out.removeLast()
                continue
            }
            out.append(character)
            previous = character
        }
        return out
    }

    // MARK: - Duplicates

    /// A stable hash of a function body with formatting and comments removed, or
    /// nil if the body is too short to be meaningful duplication.
    ///
    /// This finds only exact (Type-1) clones: identical logic, possibly
    /// reformatted. Copies with renamed variables slip through — catching those
    /// needs real clone detection, which is a different project.
    static func normalizedBodyHash(_ body: String, language: Language, minLines: Int) -> String? {
        let code = stripLiteralsAndComments(body, language: language)
        let meaningful = code.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard meaningful.count >= minLines else { return nil }
        // Drop the signature line: two functions with different names but the
        // same body are exactly what we're looking for.
        let normalized = meaningful.dropFirst()
            .joined(separator: "\n")
            .replacingOccurrences(of: " ", with: "")
        guard normalized.count >= 40 else { return nil }
        return "\(meaningful.count):\(normalized.hashValue)"
    }

    static func duplicateItems(
        _ hashes: [String: [(path: String, line: Int, name: String, lines: Int)]]
    ) -> [DebtItem] {
        hashes.values.compactMap { group in
            guard group.count > 1 else { return nil }
            let sorted = group.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
            let first = sorted[0]
            let others = sorted.dropFirst()
                .map { "\(($0.path as NSString).lastPathComponent):\($0.line)" }
                .joined(separator: ", ")
            return DebtItem(
                kind: .duplicateFunction, path: first.path, line: first.line,
                title: first.name,
                detail: "\(first.lines)줄 · \(group.count)곳 동일 — \(others)",
                // Duplicated lines saved by de-duping: how much it's actually worth.
                severity: Double(first.lines * (group.count - 1)))
        }
    }

    // MARK: - Snapshots

    /// Store today's counts and report the change since the window's oldest
    /// snapshot. Returns an empty map when there is no baseline yet — the trend
    /// only exists once history has accumulated, and a fabricated 0 would read
    /// as "nothing changed".
    static func recordAndCompareSnapshot(root: URL, counts: [DebtKind: Int]) -> [DebtKind: Int] {
        guard let store = try? UsageStore(path: UsageStore.defaultURL().path) else { return [:] }
        let project = ProjectAITokenReader.canonicalProject(root.path).key
        let today = TimeKeys.localDay(Date().timeIntervalSince1970)
        let baseline = store.oldestDebtSnapshot(project: project, since: today, days: 30)
        try? store.recordDebtSnapshot(project: project, day: today,
                                      counts: counts.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value })
        guard !baseline.isEmpty else { return [:] }
        var deltas: [DebtKind: Int] = [:]
        for kind in DebtKind.allCases {
            guard let was = baseline[kind.rawValue] else { continue }
            deltas[kind] = (counts[kind] ?? 0) - was
        }
        return deltas
    }
}
