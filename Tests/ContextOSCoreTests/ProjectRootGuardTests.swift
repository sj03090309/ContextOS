import XCTest
@testable import ContextOSCore

final class ProjectRootGuardTests: XCTestCase {

    private func makeDir(_ files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testGitRepoIsAProjectRoot() throws {
        let dir = try makeDir([".git"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ContextService.looksLikeProjectRoot(dir))
    }

    func testManifestIsAProjectRoot() throws {
        for marker in ["package.json", "Package.swift", "go.mod", "Cargo.toml", "pyproject.toml"] {
            let dir = try makeDir([marker])
            defer { try? FileManager.default.removeItem(at: dir) }
            XCTAssertTrue(ContextService.looksLikeProjectRoot(dir), "\(marker) should mark a project root")
        }
    }

    func testPlainFolderIsNotAProjectRoot() throws {
        // A home-dir-like folder with docs/photos but no project markers.
        let dir = try makeDir(["notes.txt", "photo.jpg", "todo.md"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(ContextService.looksLikeProjectRoot(dir),
                       "the hook must not index a non-project folder")
    }
}
