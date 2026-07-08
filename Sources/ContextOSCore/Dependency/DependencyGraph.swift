import Foundation

/// The project's import/dependency graph, resolved to file paths.
///
/// Directed edge `from → to` means "file `from` imports file `to`". Built from
/// the same index + resolution rules the optimizer uses (`PathResolution`).
public struct DependencyGraph: Sendable {

    /// path → set of imported paths.
    public let adjacency: [String: Set<String>]
    /// All file paths in the project (including leaves with no edges).
    public let nodes: [String]

    public var edgeCount: Int { adjacency.values.reduce(0) { $0 + $1.count } }

    public init(adjacency: [String: Set<String>], nodes: [String]) {
        self.adjacency = adjacency
        self.nodes = nodes
    }

    /// Build the graph from an index store.
    public static func build(from store: IndexStore) throws -> DependencyGraph {
        let files = try store.allFiles()
        let importsByFile = try store.importsByFile()

        // stem → paths, to resolve import modules back to files.
        var stemToPaths: [String: [String]] = [:]
        var pathByID: [Int64: String] = [:]
        for file in files {
            guard let id = file.id else { continue }
            pathByID[id] = file.relativePath
            stemToPaths[PathResolution.stem(of: file.relativePath).lowercased(), default: []].append(file.relativePath)
        }

        var adjacency: [String: Set<String>] = [:]
        for file in files {
            guard let id = file.id else { continue }
            let from = file.relativePath
            for edge in importsByFile[id] ?? [] {
                let stem = PathResolution.moduleStem(edge.module)
                for target in stemToPaths[stem] ?? [] where target != from {
                    adjacency[from, default: []].insert(target)
                }
            }
        }
        return DependencyGraph(adjacency: adjacency, nodes: files.map(\.relativePath).sorted())
    }

    /// An indented dependency tree rooted at `root` (or the highest-degree node).
    public func textTree(root: String? = nil, maxDepth: Int = 4) -> String {
        guard !nodes.isEmpty else { return "(empty)" }
        let start = root ?? highestOutDegreeNode() ?? nodes[0]
        var out = ""
        var visited: Set<String> = []
        render(node: start, depth: 0, maxDepth: maxDepth, visited: &visited, into: &out)
        return out
    }

    private func render(node: String, depth: Int, maxDepth: Int, visited: inout Set<String>, into out: inout String) {
        let indent = String(repeating: "  ", count: depth)
        if visited.contains(node) {
            out += "\(indent)\(node) …\n"
            return
        }
        out += "\(indent)\(node)\n"
        visited.insert(node)
        guard depth < maxDepth else { return }
        for child in (adjacency[node] ?? []).sorted() {
            render(node: child, depth: depth + 1, maxDepth: maxDepth, visited: &visited, into: &out)
        }
    }

    private func highestOutDegreeNode() -> String? {
        adjacency.max { $0.value.count < $1.value.count }?.key
    }

    /// Graphviz DOT source, for `dot -Tpng` or online viewers.
    public func dot() -> String {
        var out = "digraph contextos {\n  rankdir=LR;\n  node [shape=box, fontname=\"SF Mono\"];\n"
        for (from, tos) in adjacency.sorted(by: { $0.key < $1.key }) {
            for to in tos.sorted() {
                out += "  \"\(from)\" -> \"\(to)\";\n"
            }
        }
        out += "}\n"
        return out
    }
}
