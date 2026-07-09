import Foundation
import Testing
@testable import ContextOSCore

@Suite("IDF ranking")
struct IDFRankingTests {

    /// A store where `handle` is a ubiquitous symbol and `checkout` is rare.
    private func makeStore() throws -> IndexStore {
        let store = try IndexStore(path: ":memory:")
        func add(_ path: String, symbol: String) throws {
            let id = try store.insertFile(IndexedFile(
                relativePath: path, language: .python, byteSize: 400,
                lineCount: 20, contentHash: "h", modifiedAt: 0))
            try store.insertSymbol(Symbol(name: symbol, kind: .function, line: 1), fileID: id)
        }
        // 8 files all define `handle` → very common.
        for i in 0..<8 { try add("src/common\(i).py", symbol: "handle") }
        // 1 file defines `checkout` → rare/distinctive.
        try add("src/payments.py", symbol: "checkout")
        return store
    }

    @Test("a rare-symbol match outranks a common-symbol match")
    func rareBeatsCommon() throws {
        let store = try makeStore()
        // Query hits both a common term and a rare term; the rare one should win.
        let selection = try ContextOptimizer().selectContext(
            query: "handle checkout", from: store, tokenBudget: 100_000
        )
        #expect(selection.included.first?.path == "src/payments.py")
    }

    @Test("still selects the common-symbol files too, just lower")
    func commonStillIncluded() throws {
        let store = try makeStore()
        let selection = try ContextOptimizer().selectContext(
            query: "handle checkout", from: store, tokenBudget: 100_000
        )
        let paths = Set(selection.included.map(\.path))
        #expect(paths.contains("src/payments.py"))
        #expect(paths.contains("src/common0.py"))
    }
}
