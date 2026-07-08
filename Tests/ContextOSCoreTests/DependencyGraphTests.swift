import Foundation
import Testing
@testable import ContextOSCore

@Suite("DependencyGraph")
struct DependencyGraphTests {

    private func makeStore() throws -> IndexStore {
        let store = try IndexStore(path: ":memory:")
        func add(_ path: String, imports: [String]) throws {
            let id = try store.insertFile(IndexedFile(
                relativePath: path, language: .python, byteSize: 100,
                lineCount: 5, contentHash: "h", modifiedAt: 0
            ))
            for (i, m) in imports.enumerated() {
                try store.insertImport(ImportEdge(module: m, line: i + 1), fileID: id)
            }
        }
        try add("src/login.py", imports: ["auth"])
        try add("src/auth.py", imports: ["jwt", "database"])
        try add("src/jwt.py", imports: [])
        try add("src/database.py", imports: [])
        return store
    }

    @Test("resolves import edges to file paths")
    func resolvesEdges() throws {
        let graph = try DependencyGraph.build(from: makeStore())
        #expect(graph.adjacency["src/login.py"]?.contains("src/auth.py") == true)
        #expect(graph.adjacency["src/auth.py"]?.contains("src/jwt.py") == true)
        #expect(graph.adjacency["src/auth.py"]?.contains("src/database.py") == true)
        #expect(graph.nodes.count == 4)
        #expect(graph.edgeCount == 3)
    }

    @Test("text tree renders nested dependencies")
    func textTree() throws {
        let graph = try DependencyGraph.build(from: makeStore())
        let tree = graph.textTree(root: "src/login.py")
        #expect(tree.contains("src/login.py"))
        #expect(tree.contains("src/auth.py"))
        #expect(tree.contains("src/jwt.py"))
    }

    @Test("dot output is valid-ish Graphviz")
    func dotOutput() throws {
        let graph = try DependencyGraph.build(from: makeStore())
        let dot = graph.dot()
        #expect(dot.hasPrefix("digraph"))
        #expect(dot.contains("\"src/login.py\" -> \"src/auth.py\";"))
    }
}
