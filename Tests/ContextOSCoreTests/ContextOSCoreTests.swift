import Foundation
import Testing
@testable import ContextOSCore

@Suite("FileFilter")
struct FileFilterTests {
    let filter = FileFilter()

    @Test("skips well-known dependency & build directories")
    func skipsNoiseDirectories() {
        #expect(filter.shouldSkipDirectory(named: "node_modules"))
        #expect(filter.shouldSkipDirectory(named: "DerivedData"))
        #expect(filter.shouldSkipDirectory(named: ".git"))
        #expect(filter.shouldSkipDirectory(named: ".build"))
    }

    @Test("keeps ordinary source directories")
    func keepsSourceDirectories() {
        #expect(!filter.shouldSkipDirectory(named: "Sources"))
        #expect(!filter.shouldSkipDirectory(named: "auth"))
        #expect(!filter.shouldSkipDirectory(named: ".github"))
    }

    @Test("skips binaries, media, and lockfiles")
    func skipsNoiseFiles() {
        #expect(filter.shouldSkipFile(named: "logo.png"))
        #expect(filter.shouldSkipFile(named: "app.min.js"))
        #expect(filter.shouldSkipFile(named: "package-lock.json"))
        #expect(filter.shouldSkipFile(named: ".DS_Store"))
    }

    @Test("keeps ordinary source files")
    func keepsSourceFiles() {
        #expect(!filter.shouldSkipFile(named: "login.py"))
        #expect(!filter.shouldSkipFile(named: "Auth.swift"))
    }
}

@Suite("Language detection")
struct LanguageTests {
    @Test("detects languages from extensions")
    func detectsFromExtension() {
        #expect(Language.detect(fromExtension: "swift") == .swift)
        #expect(Language.detect(fromExtension: "py") == .python)
        #expect(Language.detect(fromExtension: "tsx") == .typescript)
        #expect(Language.detect(fromExtension: "xyz") == .unknown)
    }
}

@Suite("HeuristicParser")
struct HeuristicParserTests {
    let parser = HeuristicParser()

    @Test("extracts Swift symbols and imports")
    func parsesSwift() {
        let source = """
        import Foundation
        import ContextOSCore

        struct LoginService {
            func authenticate(user: String) -> Bool { true }
        }
        """
        let result = parser.parse(source: source, language: .swift)
        #expect(result.imports.map(\.module).contains("Foundation"))
        #expect(result.imports.map(\.module).contains("ContextOSCore"))
        #expect(result.symbols.contains(Symbol(name: "LoginService", kind: .type, line: 4)))
        #expect(result.symbols.contains(where: { $0.name == "authenticate" && $0.kind == .function }))
    }

    @Test("extracts Python symbols and imports")
    func parsesPython() {
        let source = """
        import os
        from auth import verify

        class User:
            def login(self):
                pass
        """
        let result = parser.parse(source: source, language: .python)
        #expect(result.imports.map(\.module).contains("os"))
        #expect(result.imports.map(\.module).contains("auth"))
        #expect(result.symbols.contains(where: { $0.name == "User" && $0.kind == .type }))
        #expect(result.symbols.contains(where: { $0.name == "login" && $0.kind == .function }))
    }
}

@Suite("IndexStore")
struct IndexStoreTests {
    @Test("persists files, symbols, and imports")
    func persists() throws {
        let store = try IndexStore(path: ":memory:")
        let file = IndexedFile(
            relativePath: "src/login.py",
            language: .python,
            byteSize: 100,
            lineCount: 10,
            contentHash: "abc",
            modifiedAt: 0
        )
        let id = try store.insertFile(file)
        try store.insertSymbol(Symbol(name: "login", kind: .function, line: 3), fileID: id)
        try store.insertImport(ImportEdge(module: "os", line: 1), fileID: id)

        #expect(try store.fileCount() == 1)
        #expect(try store.symbolCount() == 1)
        #expect(try store.importCount() == 1)
        #expect(try store.fileCountByLanguage()[.python] == 1)
    }

    @Test("symbols(forPaths:) returns only the requested files, ordered by line")
    func targetedSymbols() throws {
        let store = try IndexStore(path: ":memory:")
        func add(_ path: String, _ syms: [(String, Int)]) throws {
            let id = try store.insertFile(IndexedFile(
                relativePath: path, language: .swift, byteSize: 10,
                lineCount: 10, contentHash: path, modifiedAt: 0))
            for (n, l) in syms { try store.insertSymbol(Symbol(name: n, kind: .function, line: l), fileID: id) }
        }
        try add("a.swift", [("beta", 20), ("alpha", 5)])
        try add("b.swift", [("gamma", 1)])
        try add("c.swift", [("delta", 1)])

        let got = try store.symbols(forPaths: ["a.swift", "b.swift"])
        #expect(Set(got.keys) == ["a.swift", "b.swift"])       // c.swift excluded
        #expect(got["a.swift"]?.map(\.name) == ["alpha", "beta"]) // line-ordered
        #expect(got["b.swift"]?.map(\.name) == ["gamma"])
        #expect(try store.symbols(forPaths: []).isEmpty)
    }
}
