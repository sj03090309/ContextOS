import Foundation
import CryptoKit

/// One query's bounded working set. Required implementations are assembled as
/// a group before optional ranked files or outlines can spend their budget.
final class ContextBundleBuilder {
    struct Request: Equatable {
        var names: Set<String> = []
        var primary = false
        mutating func merge(_ other: Request) { names.formUnion(other.names); primary = primary || other.primary }
    }
    struct Entry {
        var file: ScoredFile
        var body: String
        var section: String
        var hash: String?
        var dedup: Bool
        var fullCharacters: Int
    }
    struct Plan {
        var requests: [String: Request] = [:]
        var entries: [String: Entry] = [:]
        var order: [String] = []
        var issues: [String] = []
        var text: String { order.compactMap { entries[$0]?.section }.joined() }
    }

    let service: ContextService
    let selection: ContextSelection
    let access: ProjectFileAccess
    let store: IndexStore
    let resolver: SourceDependencyResolver
    let memory: SessionMemory?
    let queryNames: Set<String>
    let ranked: [String: ScoredFile]
    var documents: [String: CodeSlicer.PreparedSource] = [:]
    var implementationNames: [String: Set<String>] = [:]
    var readBytes = 0
    // Bounds apply per delivery, not per imported file. Index and file-access
    // policy remain authoritative for all dependency reads.
    let maximumReadBytes = 4 * 1024 * 1024
    let maximumFiles = 32

    init(service: ContextService, selection: ContextSelection, projectRoot: URL, memory: SessionMemory?) throws {
        self.service = service; self.selection = selection; self.memory = memory
        access = try ProjectFileAccess(root: projectRoot)
        store = try Indexer.openStore(forProjectRoot: projectRoot)
        let files = Dictionary(uniqueKeysWithValues: try store.allFiles().map { ($0.relativePath, $0) })
        resolver = SourceDependencyResolver(files: files, store: store,
            wantsTests: !Set(selection.terms).isDisjoint(with: ["test", "tests", "testing", "spec", "specs", "테스트"]))
        queryNames = Set(selection.query.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }.map { $0.lowercased() })
        ranked = Dictionary(uniqueKeysWithValues: (selection.included + selection.excluded).map { ($0.path, $0) })
    }

    private func document(_ path: String) -> CodeSlicer.PreparedSource? {
        if let cached = documents[path] { return cached }
        guard let file = resolver.files[path], !SensitiveFilePolicy.isSensitivePath(path),
              file.byteSize <= maximumReadBytes - readBytes,
              let data = try? access.read(path, maximumBytes: min(service.indexer.scanner.filter.maxFileSize, maximumReadBytes - readBytes)),
              let source = String(data: data, encoding: .utf8) else { return nil }
        readBytes += data.count
        let prepared = service.slicer.prepare(source: source, language: file.language)
        documents[path] = prepared
        return prepared
    }

    private static let defaultExport = try! NSRegularExpression(pattern: #"\bexport\s+default\s+(?:async\s+)?(?:function\s+)?([A-Za-z_$][A-Za-z0-9_$]*)"#)

    private func slice(_ document: CodeSlicer.PreparedSource, request: Request, compact: Bool, includeLocalHelpers: Bool = true) -> CodeSlicer.SliceResult {
        var names = Set(request.names.map { $0.lowercased() })
        if request.primary { names.formUnion(queryNames) }
        if names.remove("default") != nil {
            let code = document.lexicon.codeLines.joined(separator: "\n")
            let string = code as NSString
            if let match = Self.defaultExport.firstMatch(in: code, range: NSRange(location: 0, length: string.length)) {
                names.insert(string.substring(with: match.range(at: 1)).lowercased())
            }
        }
        if !service.useSlicing || selection.terms.isEmpty {
            var result = CodeSlicer.SliceResult(content: document.source, sliced: false,
                                               keptLines: document.lexicon.lines.count, totalLines: document.lexicon.lines.count)
            if !selection.query.isEmpty { result.dependencyCode = document.lexicon.codeLines.joined(separator: "\n") }
            return result
        }
        return service.slicer.slice(document, terms: request.primary ? selection.terms : [], exactNames: names,
                                    compact: compact, collectReferences: true, includeLocalHelpers: includeLocalHelpers,
                                    requireAllNames: !request.names.isEmpty)
    }

    private func entry(path: String, document: CodeSlicer.PreparedSource, slice: CodeSlicer.SliceResult,
                       compact: Bool, caller: String) -> Entry {
        let body = slice.content
        var note = ""
        if slice.sliced && !compact { note = "  (\(slice.totalLines)줄 중 \(slice.keptLines)줄, 관련 심볼만)" }
        if !slice.omittedLocalNames.isEmpty { note = "  (부분 코드; 필수 본문 미포함)" }
        func section(_ text: String, note: String = "") -> String {
            "// ===== FILE: \(path)\(note) =====\n" + text + (text.hasSuffix("\n") ? "\n" : "\n\n")
        }
        let hash = memory.map { _ in SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined() }
        let marker = "// FILE: \(path) (이미 전달됨; fresh=true로 재요청)\n\n"
        let fullSection = section(body, note: note)
        let dedup = hash.map { memory?.isUnchanged(project: access.root.path, path: path, bodyHash: $0) == true } == true && marker.count < fullSection.count
        var file = ranked[path] ?? ScoredFile(path: path, language: document.language,
            score: (ranked[caller]?.score ?? 1) * service.optimizer.linkDecay,
            estimatedTokens: 0, reasons: [])
        if path != caller { file.reasons.insert("required implementation from \(caller)", at: 0) }
        let output = dedup ? marker : fullSection
        file.estimatedTokens = service.optimizer.estimator.estimate(text: output)
        return Entry(file: file, body: body, section: output, hash: hash, dedup: dedup, fullCharacters: section(document.source).count)
    }

    private func expand(_ committed: Plan, root: ScoredFile, compact: Bool) -> Plan {
        var plan = committed
        plan.issues = []
        var pending = [(root.path, Request(primary: true), root.path)]
        if committed.entries.isEmpty {
            // Explicitly named implementations belong to the same required
            // group. A second named file must not be treated as optional fill.
            for candidate in selection.included + selection.excluded where candidate.path != root.path {
                if candidate.reasons.contains(where: { $0.hasPrefix("requested file ") || $0.hasPrefix("named implementation ") }) {
                    pending.append((candidate.path, Request(primary: true), root.path))
                }
            }
        }
        var expanded = committed.requests
        while !pending.isEmpty {
            let (path, request, caller) = pending.removeFirst()
            var merged = plan.requests[path] ?? Request()
            merged.merge(request)
            if expanded[path] == merged { continue }
            guard plan.order.contains(path) || plan.order.count < maximumFiles else {
                plan.issues.append("의존 파일 수 한도: \(path)"); continue
            }
            guard let document = document(path) else {
                plan.issues.append("의존 코드 읽기 불가/한도: \(path)"); continue
            }
            if document.lexicon.uncertain { plan.issues.append("문법 경계/의존 코드 확인 필요: \(path)") }
            plan.requests[path] = merged; expanded[path] = merged
            if !plan.order.contains(path) { plan.order.append(path) }
            let sliced = slice(document, request: merged, compact: compact)
            plan.entries[path] = entry(path: path, document: document, slice: sliced, compact: compact, caller: caller)
            do {
                var unavailable = Set<String>()
                let dependencies = try resolver.resolve(path: path, document: document, code: sliced.dependencyCode, requested: merged.names) { target in
                    if let cached = implementationNames[target] { return cached }
                    guard let source = self.document(target) else { unavailable.insert(target); return [] }
                    let names = service.slicer.implementationNames(source)
                    implementationNames[target] = names
                    return names
                }
                plan.issues += dependencies.issues
                plan.issues += unavailable.sorted().map { "의존 코드 확인 불가/한도: " + $0 }
                for target in dependencies.files.keys.sorted() {
                    pending.append((target, Request(names: dependencies.files[target] ?? []), path))
                }
            } catch { plan.issues.append("의존 이름 조회 실패: \(path)") }
        }
        return plan
    }

    func build() -> (selection: ContextSelection, bundle: String, skipped: Int, deliveredFull: Int) {
        let estimator = service.optimizer.estimator
        let candidates = selection.included + selection.excluded
        var plan = Plan()
        var requiredFailure: [String] = []
        var requiredPaths = Set<String>()
        var failureNotice = ""
        var optionalMisses = 0
        for root in candidates {
            if plan.requests[root.path]?.primary == true { continue }
            if !plan.entries.isEmpty && !selection.query.isEmpty && !root.reasons.contains(where: {
                $0.hasPrefix("requested file ") || $0.hasPrefix("named implementation ") || $0.contains(" → ")
            }) { continue }
            let framing = "// ===== FILE: \(root.path) =====\n\n"
            if estimator.estimate(text: plan.text + framing) > selection.tokenBudget {
                if plan.entries.isEmpty {
                    requiredFailure = ["필수 코드 예산 부족: \(root.path)"]
                    failureNotice = "// " + requiredFailure[0] + "\n"
                    break
                }
                continue
            }
            let normal = expand(plan, root: root, compact: false)
            var proposed = normal
            if !proposed.issues.isEmpty || estimator.estimate(text: proposed.text) > selection.tokenBudget {
                proposed = expand(plan, root: root, compact: true)
            }
            if proposed.issues.isEmpty && estimator.estimate(text: proposed.text) <= selection.tokenBudget {
                plan = proposed
                optionalMisses = 0
            } else if plan.entries.isEmpty {
                requiredPaths.formUnion(proposed.order)
                requiredFailure = proposed.issues
                let needed = estimator.estimate(text: proposed.text)
                if needed > selection.tokenBudget {
                    let names = proposed.order.map { path in
                        let symbols = proposed.requests[path]?.names.sorted().joined(separator: ",") ?? ""
                        return path + (symbols.isEmpty ? "" : "#" + symbols)
                    }.joined(separator: ", ")
                    requiredFailure.append("필수 코드 예산 부족 (약 \(needed) 필요): \(names)")
                }
                // Keep complete units that fit, with an explicit missing-code
                // notice. Optional files cannot displace a required helper.
                let status = needed > selection.tokenBudget ? "예산 부족" : "탐색 미완료"
                let notice = "// 필수 코드 \(status) (약 \(needed) 토큰 필요): "
                    + proposed.order.prefix(3).joined(separator: ", ") + "\n"
                failureNotice = notice
                if let source = documents[root.path], let request = proposed.requests[root.path],
                   let original = proposed.entries[root.path], estimator.estimate(text: original.section + notice) > selection.tokenBudget {
                    let minimal = slice(source, request: request, compact: true, includeLocalHelpers: false)
                    proposed.entries[root.path] = entry(path: root.path, document: source, slice: minimal, compact: true, caller: root.path)
                    if !minimal.omittedLocalNames.isEmpty {
                        requiredFailure.append("같은 파일의 미포함 구현: \(root.path)#" + minimal.omittedLocalNames.sorted().joined(separator: ","))
                    }
                }
                for path in proposed.order {
                    guard let entry = proposed.entries[path], estimator.estimate(text: plan.text + entry.section + notice) <= selection.tokenBudget else { continue }
                    plan.order.append(path); plan.entries[path] = entry; plan.requests[path] = proposed.requests[path]
                }
                break
            } else {
                optionalMisses += 1
                // Do not scan hundreds of weaker candidates after the useful
                // implementation group already consumed the available budget.
                if optionalMisses >= 8 { break }
            }
            // Rejected source is not retained for the rest of the query.
            documents = documents.filter { plan.entries[$0.key] != nil }
            implementationNames = implementationNames.filter { documents[$0.key] != nil }
        }
        var result = selection
        result.included = plan.order.compactMap { plan.entries[$0]?.file }
        result.excluded = candidates.filter { plan.entries[$0.path] == nil }
        for path in requiredPaths.sorted() where plan.entries[path] == nil && !result.excluded.contains(where: { $0.path == path }) {
            if let file = resolver.files[path] {
                result.excluded.append(ScoredFile(path: path, language: file.language, score: 0, estimatedTokens: 0, reasons: ["required implementation did not fit"]))
            }
        }
        result.omissions = requiredFailure
        var bundle = plan.text
        if !requiredFailure.isEmpty {
            if estimator.estimate(text: bundle + failureNotice) <= selection.tokenBudget { bundle += failureNotice }
            else if estimator.estimate(text: bundle + "// 필수 코드 누락: 예산/탐색 한도\n") <= selection.tokenBudget { bundle += "// 필수 코드 누락: 예산/탐색 한도\n" }
        }
        bundle += service.signatureOutline(for: result.excluded, projectRoot: access.root,
            tokenBudget: max(0, selection.tokenBudget - estimator.estimate(text: bundle)))
        var fullCharacters = 0, skipped = 0
        for path in plan.order {
            guard let entry = plan.entries[path] else { continue }
            if entry.dedup { skipped += 1 }
            else {
                fullCharacters += entry.fullCharacters
                if let hash = entry.hash { memory?.markServed(project: access.root.path, path: path, bodyHash: hash) }
            }
        }
        result.estimatedTokens = estimator.estimate(text: bundle)
        result.contextScore = ContextOptimizer.contextScore(included: result.included, excluded: result.excluded)
        // Missing required code is not a successful token saving.
        let baseline = requiredFailure.isEmpty ? estimator.estimate(characterCount: fullCharacters, language: .unknown) : 0
        return (result, bundle, skipped, baseline)
    }
}
