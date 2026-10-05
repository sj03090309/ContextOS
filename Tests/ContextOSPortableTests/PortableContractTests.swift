import Foundation
import XCTest
@testable import ContextOSCore

final class PortableContractTests: XCTestCase {
    func testWindowsProtectedOperationsAreExplicitlyUnavailable() {
        for operation in [ProtectedOperation.projectFiles, .settingsChanges, .fileWatching] {
            XCTAssertFalse(RuntimeSupport.permits(operation, on: .windows))
            XCTAssertThrowsError(try RuntimeSupport.require(operation, on: .windows)) {
                XCTAssertEqual($0 as? PlatformSupportError, PlatformSupportError(platform: .windows, operation: operation))
            }
        }
    }

    func testWindowsDoctorFailsBeforeLookingForBinariesOrTouchingHome() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let report = RuntimeDoctor.inspect(executable: root.appendingPathComponent("contextos.exe"), home: root,
                                           platform: .windows) { _ in
            XCTFail("A blocked platform must not launch a binary")
            return ContextOSVersion.current
        }
        XCTAssertFalse(report.readyToConnect)
        XCTAssertFalse(report.agentToolCallVerified)
        XCTAssertEqual(report.checks.first?.name, "platform_security")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testWindowsRuntimeUsesExeSiblingsWithoutMacFallback() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("contextos.exe")
        try makeBinary(cli)
        XCTAssertNil(RuntimeBinaries.resolve(executable: cli, home: root, platform: .windows))
        let mcp = root.appendingPathComponent("contextos-mcp.exe")
        try makeBinary(mcp)
        XCTAssertEqual(RuntimeBinaries.resolve(executable: cli, home: root, platform: .windows)?.mcp, mcp)
    }

    func testMacDoctorDetectsMissingPeerAndMixedVersions() throws {
        guard RuntimeSupport.permits(.projectFiles, on: .macOS) else { throw XCTSkip("macOS security adapter is excluded from this profile") }
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("contextos"), mcp = root.appendingPathComponent("contextos-mcp")
        try makeBinary(cli)
        let missing = RuntimeDoctor.inspect(executable: cli, home: root) { _ in ContextOSVersion.current }
        XCTAssertFalse(missing.readyToConnect)
        try makeBinary(mcp)
        let mixed = RuntimeDoctor.inspect(executable: cli, home: root) { $0 == mcp ? "2.0.0" : ContextOSVersion.current }
        XCTAssertFalse(mixed.readyToConnect)
        let matching = RuntimeDoctor.inspect(executable: cli, home: root) { _ in ContextOSVersion.current }
        XCTAssertTrue(matching.readyToConnect)
        XCTAssertFalse(matching.agentToolCallVerified)
    }

    func testSharedSlicingPreservesNeededBodyAndElidesUnrelatedBody() {
        let source = "def login():\n    return 'NEEDED_BODY'\n\ndef unrelated():\n" + String(repeating: "    print('NOISE_BODY')\n", count: 100)
        let slice = CodeSlicer().slice(source: source, language: .python, terms: ["login"])
        XCTAssertTrue(slice.sliced)
        XCTAssertTrue(slice.content.contains("NEEDED_BODY"))
        XCTAssertFalse(slice.content.contains("NOISE_BODY"))
        XCTAssertLessThan(TokenEstimator().estimate(text: slice.content), TokenEstimator().estimate(text: source))
    }

    func testSharedSessionMemoryDoesNotHideChangedBodyOrAnotherProject() {
        let memory = SessionMemory(ttl: 10), now = Date()
        memory.markServed(project: "one", path: "login.py", bodyHash: "first", now: now)
        XCTAssertTrue(memory.isUnchanged(project: "one", path: "login.py", bodyHash: "first", now: now))
        XCTAssertFalse(memory.isUnchanged(project: "one", path: "login.py", bodyHash: "edited", now: now))
        XCTAssertFalse(memory.isUnchanged(project: "two", path: "login.py", bodyHash: "first", now: now))
        XCTAssertFalse(memory.isUnchanged(project: "one", path: "login.py", bodyHash: "first", now: now.addingTimeInterval(11)))
    }

    func testSharedIgnoreRulesOperateOnSuppliedTextWithoutFileLoading() {
        let matcher = GitignoreMatcher(patterns: ["*.env", "!example.env", "cache/", "a/**/private.py"])
        XCTAssertTrue(matcher.isIgnored("nested/private.env", isDirectory: false))
        XCTAssertFalse(matcher.isIgnored("example.env", isDirectory: false))
        XCTAssertTrue(matcher.isIgnored("cache", isDirectory: true))
        XCTAssertTrue(matcher.isIgnored("a/nested/private.py", isDirectory: false))
        XCTAssertFalse(matcher.isIgnored("Sources/login.py", isDirectory: false))
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-portable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBinary(_ file: URL) throws {
        #if os(Windows)
        // Windows checks executable image validity, not Unix mode bits. Use
        // our own test runner's PE bytes; no fixture is launched by this test.
        let runningImage = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try FileManager.default.copyItem(at: runningImage, to: file)
        #else
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        #endif
    }
}
