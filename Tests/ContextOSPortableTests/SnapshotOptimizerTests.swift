import Foundation
import XCTest
@testable import ContextOSCore

/// Fixed, supplied index data only. No project scan, Git process or agent setup.
private enum RankingFixtures {
    struct Case {
        let name: String
        let query: String
        let budget: Int
        var signals: GitSignals = .empty
        var terms: [String]? = nil
    }

    static let files: [IndexedFile] = [
        file(1, "src/login.py", .python, 1200),
        file(2, "src/auth.py", .python, 1200),
        file(3, "src/jwt.py", .python, 1200),
        file(4, "src/database.py", .python, 1200),
        file(5, "src/billing.py", .python, 1200),
        file(6, "src/로그인.swift", .swift, 720),
        file(7, "src/a.py", .python, 360),
        file(8, "src/b.py", .python, 360)
    ]
    static let symbols: [Int64: [Symbol]] = [
        1: [Symbol(name: "login", kind: .function, line: 1)],
        2: [Symbol(name: "authenticate", kind: .function, line: 1)],
        3: [Symbol(name: "encode", kind: .function, line: 1)],
        4: [Symbol(name: "connect", kind: .function, line: 1)],
        5: [Symbol(name: "charge", kind: .function, line: 1)],
        6: [Symbol(name: "로그인", kind: .function, line: 1)],
        7: [Symbol(name: "target", kind: .function, line: 1)],
        8: [Symbol(name: "target", kind: .function, line: 1)]
    ]
    static let imports: [Int64: [ImportEdge]] = [
        1: [ImportEdge(module: "auth", line: 1)],
        2: [ImportEdge(module: "jwt", line: 1)],
        3: [ImportEdge(module: "database", line: 1)]
    ]
    static var cases: [Case] {
        let signal = GitSignals(changedPaths: ["src/billing.py"], recentPaths: ["src/database.py"])
        return [
            Case(name: "english-import-chain", query: "fix login", budget: 8000),
            Case(name: "tight-budget", query: "login", budget: 400),
            Case(name: "zero-budget", query: "login", budget: 0),
            Case(name: "korean-symbol", query: "로그인", budget: 8000),
            Case(name: "refined-korean-query", query: "로그인 확인", budget: 8000, terms: ["login"]),
            Case(name: "stable-ties", query: "target", budget: 8000),
            Case(name: "git-only", query: "", budget: 8000, signals: signal),
            Case(name: "explicit-file", query: "src/jwt.py 설명", budget: 400, signals: signal),
            Case(name: "multiple-seeds", query: "encode connect", budget: 8000),
            Case(name: "no-match", query: "wombat", budget: 8000)
        ]
    }

    private static func file(_ id: Int64, _ path: String, _ language: Language, _ bytes: Int) -> IndexedFile {
        IndexedFile(id: id, relativePath: path, language: language, byteSize: bytes,
                    lineCount: 40, contentHash: "fixture", modifiedAt: 0)
    }

    static func record(_ selection: ContextSelection, name: String) -> [String: Any] {
        func rows(_ files: [ScoredFile]) -> [[String: Any]] {
            files.map { ["path": $0.path, "language": $0.language.rawValue, "score": $0.score,
                         "estimated_tokens": $0.estimatedTokens, "reasons": $0.reasons.sorted()] }
        }
        // Linked reasons historically follow randomized Dictionary iteration.
        // Preserve production order; canonicalize only the comparison report.
        return ["case": name, "query": selection.query, "terms": selection.terms,
                "included": rows(selection.included), "excluded": rows(selection.excluded),
                "token_budget": selection.tokenBudget, "estimated_tokens": selection.estimatedTokens,
                "context_score": selection.contextScore]
    }

    #if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
    static func store() throws -> IndexStore {
        let store = try IndexStore(path: ":memory:")
        for var file in files {
            let expected = file.id!; file.id = nil
            let id = try store.insertFile(file)
            XCTAssertEqual(id, expected)
            for symbol in symbols[expected] ?? [] { try store.insertSymbol(symbol, fileID: id) }
            for edge in imports[expected] ?? [] { try store.insertImport(edge, fileID: id) }
        }
        return store
    }
    #endif
}

final class SnapshotOptimizerTests: XCTestCase {
    private func records(files: [IndexedFile] = RankingFixtures.files) -> [[String: Any]] {
        let snapshot = IndexSnapshot(files: files, symbolsByFile: RankingFixtures.symbols,
                                     importsByFile: RankingFixtures.imports)
        return RankingFixtures.cases.map { fixture in
            RankingFixtures.record(ContextOptimizer().selectContext(query: fixture.query, from: snapshot,
                tokenBudget: fixture.budget, signals: fixture.signals, overrideTerms: fixture.terms), name: fixture.name)
        }
    }

    func testSnapshotsPreserveCapturedMacSelections() throws {
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SnapshotOptimizerBaseline.json.utf8)) as? [[String: Any]])
        let actual = records()
        guard NSArray(array: actual).isEqual(to: expected) else {
            XCTFail("Shared snapshot ranking differs from the captured Mac selection order, scores, budgets or reason membership")
            return
        }
        let report: [String: Any] = ["snapshot_ranking_matches_mac_baseline": true,
            "baseline_commit": "ce795e7", "fixture_count": expected.count,
            "platform": RuntimePlatform.current.rawValue, "version": ContextOSVersion.current,
            "windows_product_ready": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("CONTEXTOS_RANKING_PARITY " + String(decoding: data, as: UTF8.self))
    }

    func testSnapshotInputOrderDoesNotChangeFileRanking() {
        XCTAssertTrue(NSArray(array: records()).isEqual(to: records(files: Array(RankingFixtures.files.reversed()))))
    }

    func testExactBudgetBoundaryPreservesPathTieOrder() {
        let snapshot = IndexSnapshot(files: RankingFixtures.files, symbolsByFile: RankingFixtures.symbols,
                                     importsByFile: RankingFixtures.imports)
        for budget in [0, 99, 100, 199, 200] {
            let result = ContextOptimizer().selectContext(query: "target", from: snapshot, tokenBudget: budget)
            let expectedCount = min(2, budget / 100)
            XCTAssertEqual(result.included.map(\.path), Array(["src/a.py", "src/b.py"].prefix(expectedCount)))
            XCTAssertEqual(result.estimatedTokens, expectedCount * 100)
            XCTAssertLessThanOrEqual(result.estimatedTokens, budget)
        }
    }

    func testMacStoreAdapterMatchesSuppliedSnapshot() throws {
        #if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
        let store = try RankingFixtures.store()
        let stored = try RankingFixtures.cases.map { fixture in
            RankingFixtures.record(try ContextOptimizer().selectContext(query: fixture.query, from: store,
                tokenBudget: fixture.budget, signals: fixture.signals, overrideTerms: fixture.terms), name: fixture.name)
        }
        XCTAssertTrue(NSArray(array: stored).isEqual(to: records()))
        #else
        throw XCTSkip("Only the native Mac profile includes the SQLite store adapter")
        #endif
    }

    func testRankingAvailabilityDoesNotEnableWindowsProtectedOperations() {
        for operation in [ProtectedOperation.projectFiles, .settingsChanges, .fileWatching] {
            XCTAssertFalse(RuntimeSupport.permits(operation, on: .windows))
        }
    }
}
