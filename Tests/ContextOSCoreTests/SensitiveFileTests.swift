import XCTest
import Foundation
@testable import ContextOSCore

final class SensitiveFileTests: XCTestCase {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-private-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ path: String, _ content: String, root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func testCredentialFilesCannotBeReincludedByIgnoreNegations() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root) }
        let sensitive = [".env", ".env.production", "prod.env", "private.pem", "private.key", "id_rsa", "credentials.json", "secrets.yml", "service-account-test.json"]
        for path in sensitive { try write(path, "DUMMY_PRIVATE_VALUE", root: root) }
        try write(".gitignore", sensitive.map { "!" + $0 }.joined(separator: "\n"), root: root)
        try write("credentials.swift", "func login() {}", root: root)
        let scanned = try ProjectScanner().scan(root: root).map(\.relativePath)
        XCTAssertEqual(scanned, ["credentials.swift"])
    }

    func testNestedRulesAreScopedAndOverrideMatchingParentFileRules() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root) }
        try write(".gitignore", "*.txt\n", root: root)
        try write("nested/.gitignore", "!keep.txt\n/private.py\n", root: root)
        for file in ["nested/keep.txt", "nested/drop.txt", "nested/private.py", "other/private.py", "other/keep.txt"] {
            try write(file, "audit", root: root)
        }
        XCTAssertEqual(try ProjectScanner().scan(root: root).map(\.relativePath), ["nested/keep.txt", "other/private.py"])
    }

    func testIgnoredParentDirectoryCannotBeUnignoredFromInside() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root) }
        try write(".gitignore", "private/\n", root: root)
        try write("private/.gitignore", "!keep.py\n", root: root)
        try write("private/keep.py", "DUMMY_PRIVATE_VALUE", root: root)
        XCTAssertTrue(try ProjectScanner().scan(root: root).isEmpty)
    }

    func testIndexAndOptimizedBundleNeverIncludeSensitiveFixtures() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root) }
        try write("Package.swift", "let package = 1", root: root)
        try write("public.swift", "func publicLogin() { print(\"public\") }", root: root)
        try write(".env", "DUMMY_PRIVATE_VALUE", root: root)
        try write("credentials.json", "DUMMY_PRIVATE_VALUE", root: root)
        try write("nested/.gitignore", "secret.py\n", root: root)
        try write("nested/secret.py", "def privateLogin():\n    return 'DUMMY_PRIVATE_VALUE'", root: root)
        let service = ContextService(useGitSignals: false)
        let result = try service.optimizedBundle(query: "login .env credentials.json", projectRoot: root, tokenBudget: 8000)
        let files = try Indexer.openStore(forProjectRoot: root).allFiles().map(\.relativePath)
        XCTAssertFalse(files.contains(".env")); XCTAssertFalse(files.contains("credentials.json")); XCTAssertFalse(files.contains("nested/secret.py"))
        XCTAssertFalse(result.bundle.contains("DUMMY_PRIVATE_VALUE"))
        XCTAssertFalse(result.bundle.contains("credentials.json"))
        XCTAssertFalse(result.bundle.contains(".env"))
    }

    func testPreviouslyIndexedSensitiveRowsArePrunedOnQuery() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root) }
        try write(".env", "DUMMY_PRIVATE_VALUE", root: root)
        try Indexer().index(projectRoot: root)
        let store = try Indexer.openStore(forProjectRoot: root)
        _ = try store.insertFile(IndexedFile(relativePath: ".env", language: .unknown, byteSize: 19, lineCount: 1, contentHash: "old", modifiedAt: 0))
        let result = try ContextService(useGitSignals: false).optimizedBundle(query: ".env", projectRoot: root, tokenBudget: 8000)
        XCTAssertFalse(try store.allFiles().contains(where: { $0.relativePath == ".env" }))
        XCTAssertFalse(result.bundle.contains("DUMMY_PRIVATE_VALUE"))
    }

    func testUsageLogRedactsSensitiveReferences() throws {
        let store = try UsageStore(path: ":memory:")
        try store.record(UsageEvent(project: "/audit/project", query: "inspect config/.env.production and private.pem", selectedTokens: 1, fullTokens: 10, contextScore: 1, fileCount: 1))
        let event = try XCTUnwrap(store.recentEvents(limit: 1).first)
        XCTAssertFalse(event.query.contains(".env.production"))
        XCTAssertFalse(event.query.contains("private.pem"))
        XCTAssertTrue(event.query.contains("[민감 파일]"))
    }

    func testCredentialRootAliasCannotCreateAnIndex() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = root.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: credentials)
        XCTAssertThrowsError(try Indexer().index(projectRoot: alias))
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentials.appendingPathComponent(".contextos").path))
    }
}
