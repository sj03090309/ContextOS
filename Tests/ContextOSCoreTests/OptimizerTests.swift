import Foundation
import Testing
@testable import ContextOSCore

@Suite("TokenEstimator")
struct TokenEstimatorTests {
    let estimator = TokenEstimator()

    @Test("code estimates denser than prose")
    func codeDenserThanProse() {
        let code = estimator.estimate(characterCount: 3600, language: .swift)
        let prose = estimator.estimate(characterCount: 3600, language: .unknown)
        #expect(code == 1000)   // 3600 / 3.6
        #expect(prose == 900)   // 3600 / 4.0
        #expect(code > prose)
    }

    @Test("human readable uses ~ and K")
    func humanReadable() {
        #expect(TokenEstimator.humanReadable(11_200) == "~11.2K")
        #expect(TokenEstimator.humanReadable(42) == "~42")
    }
}

@Suite("TextTokens")
struct TextTokensTests {
    @Test("splits camelCase, snake_case, and paths")
    func splitsIdentifiers() {
        #expect(TextTokens.subwords(of: "LoginService") == ["login", "service"])
        #expect(TextTokens.subwords(of: "auth/jwt_helper.py") == ["auth", "jwt", "helper", "py"])
    }

    @Test("query terms drop stopwords and short tokens")
    func queryTerms() {
        let terms = TextTokens.queryTerms("fix the login flow")
        #expect(terms.contains("login"))
        #expect(terms.contains("flow"))
        #expect(!terms.contains("fix"))
        #expect(!terms.contains("the"))
    }
}

@Suite("ContextOptimizer")
struct ContextOptimizerTests {

    /// Builds an in-memory index resembling a small auth-flow project.
    private func makeStore() throws -> IndexStore {
        let store = try IndexStore(path: ":memory:")

        func add(_ path: String, _ lang: Language, symbols: [Symbol], imports: [ImportEdge]) throws {
            let id = try store.insertFile(IndexedFile(
                relativePath: path, language: lang, byteSize: 1200,
                lineCount: 40, contentHash: "h", modifiedAt: 0
            ))
            for s in symbols { try store.insertSymbol(s, fileID: id) }
            for i in imports { try store.insertImport(i, fileID: id) }
        }

        try add("src/login.py", .python,
                symbols: [Symbol(name: "login", kind: .function, line: 1)],
                imports: [ImportEdge(module: "auth", line: 1)])
        try add("src/auth.py", .python,
                symbols: [Symbol(name: "authenticate", kind: .function, line: 1)],
                imports: [ImportEdge(module: "jwt", line: 1)])
        try add("src/jwt.py", .python,
                symbols: [Symbol(name: "encode", kind: .function, line: 1)],
                imports: [ImportEdge(module: "database", line: 1)])
        try add("src/database.py", .python,
                symbols: [Symbol(name: "connect", kind: .function, line: 1)],
                imports: [])
        try add("src/billing.py", .python,
                symbols: [Symbol(name: "charge", kind: .function, line: 1)],
                imports: [])
        return store
    }

    @Test("directly-matched file ranks first")
    func directMatchWins() throws {
        let store = try makeStore()
        let selection = try ContextOptimizer().selectContext(
            query: "fix login", from: store, tokenBudget: 100_000
        )
        #expect(selection.included.first?.path == "src/login.py")
    }

    @Test("import graph pulls in related files, not unrelated ones")
    func graphExpansion() throws {
        let store = try makeStore()
        let selection = try ContextOptimizer().selectContext(
            query: "login", from: store, tokenBudget: 100_000
        )
        let paths = Set(selection.included.map(\.path))
        // login → auth → jwt should be reachable within 2 hops.
        #expect(paths.contains("src/login.py"))
        #expect(paths.contains("src/auth.py"))
        #expect(paths.contains("src/jwt.py"))
        // billing has no link to login and shouldn't appear.
        #expect(!paths.contains("src/billing.py"))
    }

    @Test("token budget caps included files and surfaces the rest")
    func budgetCaps() throws {
        let store = try makeStore()
        // Each file ≈ 1200/3.6 ≈ 334 tokens; budget of 400 fits only one.
        let selection = try ContextOptimizer().selectContext(
            query: "login", from: store, tokenBudget: 400
        )
        #expect(selection.included.count == 1)
        #expect(!selection.excluded.isEmpty)
        #expect(selection.estimatedTokens <= 400)
    }

    @Test("empty query yields empty selection")
    func emptyQuery() throws {
        let store = try makeStore()
        let selection = try ContextOptimizer().selectContext(
            query: "the a to", from: store, tokenBudget: 8000
        )
        #expect(selection.isEmpty)
    }
}
