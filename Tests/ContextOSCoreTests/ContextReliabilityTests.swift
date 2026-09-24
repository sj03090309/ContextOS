import Foundation
import Testing
@testable import ContextOSCore

@Suite("Context reliability regressions")
struct ContextReliabilityTests {
    private func project(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-audit-\(UUID())")
        for (path, body) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("explicit filenames outrank incidental symbol matches and extensions")
    func explicitFilename() throws {
        let root = try project([
            "Package.swift": "let package = 1\n",
            "Tests/PackageTests.swift": "func package() {}\n",
            "Sources/Noise.swift": "func unrelated() {}\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService(useGitSignals: false)
        let result = try service.relevantContext(query: "Package.swift", projectRoot: root, tokenBudget: 8000)
        #expect(result.included.map(\.path) == ["Package.swift"])
    }

    @Test("qualified paths disambiguate duplicate basenames")
    func explicitPath() throws {
        let root = try project([
            "a/handler.py": "def handler():\n    return 1\n",
            "b/handler.py": "def handler():\n    return 2\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ContextService(useGitSignals: false).relevantContext(
            query: "read `b/handler.py`", projectRoot: root, tokenBudget: 8000)
        #expect(result.included.first?.path == "b/handler.py")
        let absolute = try ContextService(useGitSignals: false).relevantContext(
            query: root.appendingPathComponent("b/handler.py").path, projectRoot: root, tokenBudget: 8000)
        #expect(absolute.included.map(\.path) == ["b/handler.py"])
    }

    @Test("file vocabulary is not replaced by unrelated typo corrections")
    func fileVocabulary() throws {
        let root = try project(["README.md": "# Setup\n", "reader.py": "def read():\n    pass\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ContextService(useGitSignals: false).relevantContext(
            query: "README", projectRoot: root, tokenBudget: 8000)
        #expect(result.included.first?.path == "README.md")
        #expect(result.refinement?.corrections.isEmpty == true)
    }

    @Test("acronyms split at the following capitalized word")
    func acronyms() {
        #expect(TextTokens.subwords(of: "MCPServer HTTPClient projectID") == ["mcp", "server", "http", "client", "project", "id"])
    }

    @Test("dotted symbols remain searchable and explicit files ignore unrelated Git signals")
    func symbolAndGitSignals() throws {
        let root = try project(["memory.py": "def isUnchanged():\n    pass\n", "other.py": "def other():\n    pass\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService(useGitSignals: false)
        let result = try service.relevantContext(query: "SessionMemory.isUnchanged", projectRoot: root, tokenBudget: 8000)
        #expect(result.included.first?.path == "memory.py")
        let store = try Indexer.openStore(forProjectRoot: root)
        let exact = try ContextOptimizer().selectContext(query: "memory.py", from: store, tokenBudget: 8000,
            signals: GitSignals(changedPaths: ["other.py"], recentPaths: []))
        #expect(exact.included.map(\.path) == ["memory.py"])
    }

    @Test("a large relevant file is sliced before applying the budget")
    func largeFileSlice() throws {
        let body = "def target():\n    return 'NEEDED_BODY'\n\ndef unrelated():\n"
            + String(repeating: "    print('unrelated payload')\n", count: 600)
        let root = try project(["large.py": body])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ContextService(useGitSignals: false).optimizedBundle(
            query: "target", projectRoot: root, tokenBudget: 250)
        #expect(result.bundle.contains("NEEDED_BODY"))
        #expect(result.selection.included.map(\.path) == ["large.py"])
        #expect(TokenEstimator().estimate(text: result.bundle) <= 250)
    }

    @Test("braces in strings and comments never truncate a relevant function")
    func literalBraces() {
        let source = """
        func target() -> String {
            let literal = "}"
            // } not the end of the function
            /* } */
            return "NEEDED_BODY" + literal
        }
        func unrelated() {
        """ + "\n" + String(repeating: "    print(1)\n", count: 100) + "}\n"
        let result = CodeSlicer().slice(source: source, language: .swift, terms: ["target"])
        #expect(result.sliced)
        #expect(result.content.contains("NEEDED_BODY"))
    }

    @Test("Rust lifetimes and Swift interpolation preserve relevant bodies")
    func lifetimeAndInterpolation() {
        let rust = "fn target(value: &'static str) {\n    println!(\"NEEDED_BODY\");\n}\nfn unrelated() {\n"
            + String(repeating: "    println!(\"noise\");\n", count: 100) + "}\n"
        #expect(CodeSlicer().slice(source: rust, language: .rust, terms: ["target"]).content.contains("NEEDED_BODY"))
        let swift = #"func target() { print("\(table["}"])")"# + "\n    print(\"NEEDED_BODY\")\n}\nfunc unrelated() {\n"
            + String(repeating: "    print(1)\n", count: 100) + "}\n"
        #expect(CodeSlicer().slice(source: swift, language: .swift, terms: ["target"]).content.contains("NEEDED_BODY"))
    }

    @Test("the complete response and telemetry include outline overhead")
    func completeBudget() throws {
        let files = Dictionary(uniqueKeysWithValues: (0..<10).map { i in
            ("module\(i).py", "def target\(i)():\n" + String(repeating: "    print('payload')\n", count: 10))
        })
        let root = try project(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService(useGitSignals: false)
        for budget in [0, 1, 30, 100, 250, 500] {
            let result = try service.optimizedBundle(query: "target", projectRoot: root, tokenBudget: budget)
            let actual = TokenEstimator().estimate(text: result.bundle)
            #expect(actual <= budget, "budget \(budget), delivered \(actual)")
            #expect(result.deliveredTokens == actual)
            #expect(result.selection.estimatedTokens == actual)
        }
    }

    @Test("whole Unicode files cannot claim savings from byte and character mismatch")
    func honestWholeFileAccounting() throws {
        let root = try project(["login.py": "def login():\n    return '" + String(repeating: "로그인에 성공했습니다", count: 100) + "'\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ContextService(useGitSignals: false, useSlicing: false).optimizedBundle(
            query: "login", projectRoot: root, tokenBudget: 8000)
        #expect(result.deliveredFullTokens == result.deliveredTokens)
    }

    @Test("a rejected body is not remembered as already delivered")
    func rejectedBodyNotRemembered() throws {
        let root = try project(["login.py": "def login():\n    return 'NEEDED_BODY'\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService(useGitSignals: false)
        let memory = SessionMemory()
        _ = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 1, memory: memory)
        #expect(memory.count == 0)
        let result = try service.optimizedBundle(query: "login", projectRoot: root, tokenBudget: 8000, memory: memory)
        #expect(result.bundle.contains("NEEDED_BODY"))
    }

    @Test("forced reindex detects same size edits with preserved modification time")
    func forceReindex() throws {
        let root = try project(["entry.py": "def before():\n    pass\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService(useGitSignals: false)
        try service.ensureIndexed(projectRoot: root)
        let url = root.appendingPathComponent("entry.py")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        try "def after_():\n    pass\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: url.path)
        try service.ensureIndexed(projectRoot: root, forceReindex: true)
        let names = try Indexer.openStore(forProjectRoot: root).symbolNames()
        #expect(names.contains("after_"))
        #expect(!names.contains("before"))
    }

    @Test("file symlinks never pull source from outside the project")
    func externalSymlink() throws {
        let root = try project(["local.py": "def local():\n    pass\n"])
        let outside = try project(["external.py": "def external():\n    return 'OUTSIDE_ROOT'\n"])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.py"),
            withDestinationURL: outside.appendingPathComponent("external.py"))
        let result = try ContextService(useGitSignals: false).optimizedBundle(
            query: "external", projectRoot: root, tokenBudget: 8000)
        #expect(!result.bundle.contains("OUTSIDE_ROOT"))
        #expect(try Indexer.openStore(forProjectRoot: root).fileCount() == 1)
    }

    @Test("ambiguous typo corrections keep the original term")
    func ambiguousTypo() {
        let result = QueryRefiner().refine("cot", vocabulary: ["cat", "cut"])
        #expect(result.terms == ["cot"])
        #expect(result.corrections.isEmpty)
    }

    @Test("invalid roots fail without creating a phantom project")
    func missingRoot() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-missing-\(UUID())")
        #expect(throws: (any Error).self) { try Indexer().index(projectRoot: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("force reindex reparses even unchanged source")
    func forceReparses() throws {
        let root = try project(["entry.py": "def entry():\n    pass\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService(useGitSignals: false)
        _ = try service.reindex(projectRoot: root)
        #expect(try service.reindex(projectRoot: root).symbolsIndexed == 1)
        #expect(try service.indexer.index(projectRoot: root).symbolsIndexed == 0)
    }

    @Test("concurrent indexers serialize snapshots and keep every symbol")
    func concurrentIndexing() throws {
        let root = try project(["entry.py": "def entry():\n    pass\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try Indexer().index(projectRoot: root)
        for i in 0..<40 {
            try "def item\(i)():\n    pass\n".write(to: root.appendingPathComponent("item\(i).py"), atomically: true, encoding: .utf8)
        }
        let failures = LockedFailures()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do { try Indexer().index(projectRoot: root) }
            catch { failures.add(String(describing: error)) }
        }
        #expect(failures.messages.isEmpty)
        let store = try Indexer.openStore(forProjectRoot: root)
        #expect(try store.fileCount() == 41)
        #expect(try store.symbolCount() == 41)
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(message)
    }
    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
