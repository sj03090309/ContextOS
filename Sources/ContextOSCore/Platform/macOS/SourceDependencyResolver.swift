import Foundation

/// Resolves source-level references against indexed, allowed project files.
/// Relative imports use their actual directory, never a project-wide stem hit.
final class SourceDependencyResolver {
    struct Resolution {
        var files: [String: Set<String>] = [:]
        var issues: [String] = []
    }

    let files: [String: IndexedFile]
    private lazy var modules = ProjectModuleResolver(paths: Array(files.keys))
    let store: IndexStore
    let wantsTests: Bool

    init(files: [String: IndexedFile], store: IndexStore, wantsTests: Bool) {
        self.files = files; self.store = store; self.wantsTests = wantsTests
    }

    private static let jsFrom = try! NSRegularExpression(pattern: #"^\s*(import|export)\s+([\s\S]*?)\s+from\s*['"]([^'"]+)['"]"#)
    private static let pythonFrom = try! NSRegularExpression(pattern: #"^\s*from\s+([.A-Za-z_][.A-Za-z0-9_]*)\s+import\s+([\s\S]+)"#)
    private static let pythonImport = try! NSRegularExpression(pattern: #"^\s*import\s+(.+)"#)
    private static let member = try! NSRegularExpression(pattern: #"\b[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)+"#)
    private static let call = try! NSRegularExpression(pattern: #"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:<[^;\n{}]*>)?\s*\("#)
    private static let typedValue = try! NSRegularExpression(pattern: #"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*([A-Za-z_][A-Za-z0-9_]*)|=\s*(?:try[?!]?\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\()"#)

    private func captures(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        let string = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: string.length)) else { return nil }
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : string.substring(with: match.range(at: $0)) }
    }

    func resolve(path: String, document: CodeSlicer.PreparedSource, code: String,
                 requested: Set<String>, availableNames: (String) -> Set<String>) throws -> Resolution {
        guard !code.isEmpty else { return Resolution() }
        var depth = 0
        let activeCode = code.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isImport = trimmed.hasPrefix("import ") || trimmed.hasPrefix("from ")
            let skip = isImport || depth > 0
            if skip {
                for c in line.utf8 {
                    if c == 123 || c == 40 { depth += 1 }
                    if c == 125 || c == 41 { depth -= 1 }
                }
            }
            return !skip
        }.joined(separator: "\n")
        let used = SourceLexicon.identifiers(activeCode).union(requested)
        let text = code as NSString
        var members: [String: Set<String>] = [:]
        for match in Self.member.matches(in: code, range: NSRange(location: 0, length: text.length)) {
            let parts = text.substring(with: match.range).split(separator: ".").map(String.init)
            for i in 1..<parts.count { members[parts[..<i].joined(separator: "."), default: []].insert(parts[i]) }
        }
        var result = Resolution()
        var bound = Set<String>()
        func add(_ module: String, names: Set<String>) {
            if let target = resolveModule(module, from: path, language: document.language), target != path {
                result.files[target, default: []].formUnion(names)
            } else if module.hasPrefix(".") || module.hasPrefix("@/") || module.hasPrefix("~/") {
                result.issues.append("로컬 의존 파일 확인 필요: \(path) → \(module)")
            }
        }
        func bindings(_ list: String, separator: String) -> [(remote: String, local: String)] {
            list.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                .split(separator: ",").compactMap { item in
                    let words = item.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: separator)
                    let remote = words[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let local = (words.last ?? remote).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remote.isEmpty else { return nil }
                    return (remote, local)
                }
        }

        if document.language == .typescript || document.language == .javascript || document.language == .python {
            let lines = document.lexicon.lines
            for index in lines.indices {
                let masked = document.lexicon.codeLines[index].trimmingCharacters(in: .whitespaces)
                guard masked.hasPrefix("import ") || masked.hasPrefix("export ") || masked.hasPrefix("from ") else { continue }
                if masked.hasPrefix("export ") && !masked.hasPrefix("export {") && !masked.hasPrefix("export *") { continue }
                var statement = lines[index]
                // Multiline named imports are bounded independently of file size.
                if !statement.contains("from") && (statement.contains("{") || statement.hasSuffix("(")) {
                    for next in (index + 1)..<min(lines.count, index + 32) {
                        statement += "\n" + lines[next]
                        if statement.contains("from") || lines[next].contains(")") { break }
                    }
                } else if document.language == .python && statement.contains("(") && !statement.contains(")") {
                    for next in (index + 1)..<min(lines.count, index + 32) {
                        statement += "\n" + lines[next]
                        if lines[next].contains(")") { break }
                    }
                }
                if document.language == .python {
                    if let values = captures(Self.pythonFrom, statement) {
                        for binding in bindings(values[1], separator: " as ") {
                            bound.insert(binding.local)
                            if binding.remote == "*" {
                                if !requested.isEmpty { add(values[0], names: requested) }
                            } else if used.contains(binding.local) {
                                if let submodule = resolveModule(values[0] + (values[0].hasSuffix(".") ? "" : ".") + binding.remote,
                                                                 from: path, language: .python), let fields = members[binding.local] {
                                    result.files[submodule, default: []].formUnion(fields)
                                } else { add(values[0], names: [binding.remote]) }
                            }
                        }
                    } else if let values = captures(Self.pythonImport, statement) {
                        for binding in bindings(values[0], separator: " as ") {
                            bound.insert(binding.local)
                            if let fields = members[binding.local] { add(binding.remote, names: fields) }
                        }
                    }
                } else if let values = captures(Self.jsFrom, statement) {
                    let isExport = values[0] == "export"
                    let list = values[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if list == "*" {
                        if isExport && !requested.isEmpty { add(values[2], names: requested) }
                    } else if list.hasPrefix("* as ") {
                        let local = String(list.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                        bound.insert(local)
                        if let fields = members[local] { add(values[2], names: fields) }
                    } else {
                        var named = list
                        if let brace = list.firstIndex(of: "{"), list[..<brace].contains(",") {
                            let local = list[..<brace].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
                            bound.insert(local)
                            if used.contains(local) { add(values[2], names: ["default"]) }
                            named = String(list[brace...])
                        }
                        if named.hasPrefix("type ") { named = String(named.dropFirst(5)) }
                        for binding in bindings(named, separator: " as ") {
                            bound.insert(binding.local)
                            if isExport ? requested.contains(binding.local) : used.contains(binding.local) {
                                let remote = named.contains("{") ? binding.remote : "default"
                                add(values[2], names: [remote])
                            }
                        }
                    }
                }
            }
        }

        // Swift files in a module do not import one another. Resolve unique
        // free calls and explicit `Type.member` uses using targeted index lookups.
        if document.language == .swift {
            let local = Set(document.parsed.symbols.map(\.name))
            var calls = Set<String>()
            for match in Self.call.matches(in: code, range: NSRange(location: 0, length: text.length)) {
                let range = match.range(at: 1)
                if range.location > 0 && text.substring(with: NSRange(location: range.location - 1, length: 1)) == "." { continue }
                let name = text.substring(with: range)
                if !local.contains(name) && !bound.contains(name) { calls.insert(name) }
            }
            // Track straightforward local/property type annotations and
            // constructor bindings. Do not guess the type of arbitrary values.
            var aliases: [String: Set<String>] = [:]
            for match in Self.typedValue.matches(in: code, range: NSRange(location: 0, length: text.length)) {
                let typeRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
                aliases[text.substring(with: match.range(at: 1)), default: []].insert(text.substring(with: typeRange))
            }
            for (alias, types) in aliases where types.count == 1 {
                if let type = types.first {
                    let fields = (members[alias] ?? []).union(members["self." + alias] ?? [])
                    members[type, default: []].formUnion(fields)
                }
            }
            let qualifiers = Set(members.keys.filter { !$0.contains(".") && !local.contains($0) })
            let sourceParts = path.split(separator: "/")
            let targetPrefix = files["Package.swift"] != nil && sourceParts.count > 2 && sourceParts[0] == "Sources" ? "Sources/\(sourceParts[1])/" : nil
            let importedTargets = Set(document.parsed.imports.map { "Sources/" + $0.module + "/" })
            let definitions = try store.definitions(named: calls.union(qualifiers))
                .filter { definition in
                    definition.path != path && files[definition.path]?.language == .swift
                        && (wantsTests || !Self.isTest(definition.path))
                        && (targetPrefix == nil || definition.path.hasPrefix(targetPrefix!) || importedTargets.contains(where: { definition.path.hasPrefix($0) }))
                }
            for name in calls.union(qualifiers).sorted() {
                let matches = definitions.filter { $0.name == name }
                let typePaths = Set(matches.filter { $0.kind == .type }.map(\.path))
                if !typePaths.isEmpty {
                    for target in typePaths.sorted() {
                        let declared = availableNames(target)
                        var wanted = Set((members[name] ?? []).map { name + "." + $0 })
                        if calls.contains(name) { wanted.insert(name + ".init") }
                        let actual = wanted.intersection(declared)
                        if !actual.isEmpty { result.files[target, default: []].formUnion(actual) }
                    }
                } else {
                    let paths = Set(matches.map(\.path)).filter { availableNames($0).contains(name) }
                    if paths.count == 1, let target = paths.first { result.files[target, default: []].insert(name) }
                    else if paths.count > 1 { result.issues.append("동명 의존 구현 확인 필요: \(name) (\(paths.sorted().joined(separator: ", ")))") }
                }
            }
        }
        return result
    }

    private func resolveModule(_ module: String, from path: String, language: Language) -> String? {
        modules.resolve(module, from: path, language: language)
    }

    static func isTest(_ path: String) -> Bool {
        let words = Set(TextTokens.subwords(of: path))
        return !words.isDisjoint(with: ["test", "tests", "spec", "specs"])
    }
}
