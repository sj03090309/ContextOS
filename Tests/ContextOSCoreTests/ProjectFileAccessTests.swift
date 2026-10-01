import XCTest
import Foundation
import Darwin
@testable import ContextOSCore

final class ProjectFileAccessTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ path: String, _ content: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    private func link(_ path: String, to target: URL, root: URL) throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(path), withDestinationURL: target)
    }

    func testRegularRulesRemainAvailableInOrder() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ContextService.ruleFileCandidates { try write(name, "public rule \(name)", root: root) }
        let rules = try XCTUnwrap(ContextService().projectRules(projectRoot: root))
        let headers = ContextService.ruleFileCandidates.map { "===== \($0) =====" }
        XCTAssertEqual(rules.components(separatedBy: "\n\n").map { String($0.split(separator: "\n")[0]) }, headers)
    }

    func testRuleLinksOutsidePrefixSiblingAndChainsAreNotRead() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        try write(".cursorrules", "PUBLIC_RULE", root: root)
        try write("project-other/rules.md", "DUMMY_OUTSIDE_RULE", root: base)
        try link("AGENTS.md", to: base.appendingPathComponent("project-other/rules.md"), root: root)
        try link("CLAUDE.md", to: root.appendingPathComponent("AGENTS.md"), root: root)
        XCTAssertEqual(ContextService().projectRules(projectRoot: root), "===== .cursorrules =====\nPUBLIC_RULE")
    }

    func testRuleLinksToSensitiveFilesAndNestedDirectoryAreNotRead() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        try write(".env", "DUMMY_PRIVATE_VALUE", root: root)
        try write("outside/rules.md", "DUMMY_PRIVATE_RULE", root: base)
        try link("AGENTS.md", to: root.appendingPathComponent(".env"), root: root)
        try link(".contextos", to: base.appendingPathComponent("outside"), root: root)
        XCTAssertNil(ContextService().projectRules(projectRoot: root))
        XCTAssertThrowsError(try Indexer().index(projectRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("outside/index.sqlite").path))
    }

    func testRuleSpecialAndOversizedFilesAreRejectedWithoutBlocking() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkfifo(root.appendingPathComponent("AGENTS.md").path, 0o600), 0)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("CLAUDE.md"), withIntermediateDirectories: true)
        try write(".cursorrules", String(repeating: "x", count: 2_000_001), root: root)
        XCTAssertNil(ContextService().projectRules(projectRoot: root))
    }

    func testCredentialDescendantAndRootAliasesProtectAllEntryPoints() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".aws/nested")
        try write("AGENTS.md", "DUMMY_PRIVATE_RULE", root: root)
        let alias = base.appendingPathComponent("alias")
        try link("alias", to: root, root: base)
        for candidate in [root, alias] {
            XCTAssertThrowsError(try Indexer().index(projectRoot: candidate))
            XCTAssertThrowsError(try Indexer.openStore(forProjectRoot: candidate))
            XCTAssertThrowsError(try ProjectScanner().scan(root: candidate))
            XCTAssertNil(ContextService().projectRules(projectRoot: candidate))
            XCTAssertEqual(ContextService().sessionSnapshot(projectRoot: candidate), "Project is unavailable or protected.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".contextos").path))
    }

    func testIndexDatabaseSidecarsAndIgnoreLinksFailWithoutChangingTargets() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try write("outside.txt", "DUMMY_UNCHANGED", root: base)
        let target = base.appendingPathComponent("outside.txt")
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "index.sqlite-journal", ".gitignore"] {
            let root = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".contextos"), withIntermediateDirectories: true)
            try link(".contextos/" + name, to: target, root: root)
            XCTAssertThrowsError(try Indexer().index(projectRoot: root))
            XCTAssertThrowsError(try Indexer.openStore(forProjectRoot: root))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "DUMMY_UNCHANGED")
        }
    }

    func testDescriptorReaderRejectsTraversalAndSwappedSourceLinks() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        try write("Sources/public.swift", "func publicLogin() {}", root: root)
        try write(".env", "DUMMY_PRIVATE_VALUE", root: root)
        let access = try ProjectFileAccess(root: root)
        XCTAssertEqual(try String(decoding: access.read("Sources/public.swift"), as: UTF8.self), "func publicLogin() {}")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/public.swift"))
        try link("Sources/public.swift", to: root.appendingPathComponent(".env"), root: root)
        for path in ["Sources/public.swift", "../.env", "/.env", ".env", "Sources/../.env"] {
            XCTAssertThrowsError(try access.read(path))
        }
        let result = try ContextService(useGitSignals: false).optimizedBundle(query: "public login", projectRoot: root, tokenBudget: 8000)
        XCTAssertFalse(result.bundle.contains("DUMMY_PRIVATE_VALUE"))
    }
}
