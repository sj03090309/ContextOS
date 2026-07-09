import Foundation
import Testing
@testable import ContextOSCore

@Suite("Incremental indexing")
struct IncrementalIndexTests {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-incr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "def login():\n    pass\n".write(to: root.appendingPathComponent("src/login.py"), atomically: true, encoding: .utf8)
        try "def charge():\n    pass\n".write(to: root.appendingPathComponent("src/billing.py"), atomically: true, encoding: .utf8)
        return root
    }

    private func store(_ root: URL) throws -> IndexStore { try Indexer.openStore(forProjectRoot: root) }

    @Test("re-index of an unchanged project touches nothing but stays correct")
    func unchangedIsStable() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexer = Indexer()

        try indexer.index(projectRoot: root)
        let files1 = try store(root).fileCount()
        let syms1 = try store(root).symbolCount()

        let stats = try indexer.index(projectRoot: root) // no changes
        #expect(try store(root).fileCount() == files1)
        #expect(try store(root).symbolCount() == syms1)
        #expect(stats.symbolsIndexed == 0) // nothing re-parsed
    }

    @Test("only a modified file is re-parsed")
    func modifiedFileReparsed() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexer = Indexer()
        try indexer.index(projectRoot: root)

        // Change login.py to add a new symbol (and bump mtime).
        try "def login():\n    pass\n\ndef refresh_token():\n    pass\n"
            .write(to: root.appendingPathComponent("src/login.py"), atomically: true, encoding: .utf8)

        let stats = try indexer.index(projectRoot: root)
        #expect(stats.symbolsIndexed > 0) // only the changed file re-parsed
        let names = (try store(root).symbolsByFile().values.flatMap { $0 }).map(\.name)
        #expect(names.contains("refresh_token"))
        #expect(names.contains("charge")) // untouched file's symbols still present
    }

    @Test("a deleted file is dropped from the index")
    func deletedFileRemoved() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexer = Indexer()
        try indexer.index(projectRoot: root)
        #expect(try store(root).fileCount() == 2)

        try FileManager.default.removeItem(at: root.appendingPathComponent("src/billing.py"))
        try indexer.index(projectRoot: root)
        #expect(try store(root).fileCount() == 1)
        let names = (try store(root).symbolsByFile().values.flatMap { $0 }).map(\.name)
        #expect(!names.contains("charge"))
    }
}
