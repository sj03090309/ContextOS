import XCTest
@testable import ContextOSCore

final class IndexHygieneTests: XCTestCase {

    func testIndexDirSelfIgnores() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-hygiene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "def f():\n    pass\n"
            .write(to: root.appendingPathComponent("src/a.py"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try Indexer().index(projectRoot: root)

        // A `.gitignore` of "*" must sit inside .contextos so its sqlite/-wal/-shm
        // never pollute the host project's git status.
        let ignore = root.appendingPathComponent(".contextos/.gitignore")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignore.path))
        XCTAssertEqual(try String(contentsOf: ignore, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "*")
    }
}
