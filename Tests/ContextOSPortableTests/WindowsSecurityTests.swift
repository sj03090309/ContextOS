import Foundation
import XCTest
@testable import ContextOSCore

final class WindowsPathPolicyTests: XCTestCase {
    func testNamespaceEscapesAndDeviceNamesAreRefused() {
        for path in ["", ".", "..", "../secret", "a/../secret", "/absolute", "C:/other", "\\\\server\\share", "a//b",
                     "a\\..\\b", "file:stream", "NUL.txt", "con", "COM1.py", "LPT9", "COM¹.txt", "CON .txt",
                     "CONOUT$", "trailing.", "trailing ", "a\0b", "a\nb", "a?b", "a*b"] {
            XCTAssertThrowsError(try WindowsPathPolicy.relative(path), path)
        }
        XCTAssertThrowsError(try WindowsPathPolicy.singleName("directory/file"))
    }
    func testNormalRelativePathsKeepTheirCaseAndUnicode() throws {
        XCTAssertEqual(try WindowsPathPolicy.relative("Sources\\Auth\\로그인.swift"), "Sources/Auth/로그인.swift")
        XCTAssertEqual(try WindowsPathPolicy.relative("foo..bar/file name.txt"), "foo..bar/file name.txt")
        XCTAssertEqual(try WindowsPathPolicy.relative("com10.swift"), "com10.swift")
    }
    func testOnlyExplicitLocalDriveRootsAreAccepted() throws {
        XCTAssertEqual(try WindowsPathPolicy.localRoot("C:\\Users\\me\\project"), "C:/Users/me/project")
        XCTAssertEqual(try WindowsPathPolicy.localRoot("/C:/Users/me/project"), "C:/Users/me/project")
        for path in ["C:", "C:/", "C:relative", "/tmp/project", "//server/share/project", "\\\\?\\C:\\project", "D:/a/../b"] {
            XCTAssertThrowsError(try WindowsPathPolicy.localRoot(path), path)
        }
    }
    func testNativePresenceDoesNotEnableProtectedOperations() {
        for operation in [ProtectedOperation.projectFiles, .settingsChanges, .fileWatching] {
            XCTAssertFalse(RuntimeSupport.permits(operation, on: .windows))
        }
    }
    func testOtherHostsHaveNoFilesystemOrHashFallback() throws {
        #if !os(Windows)
        XCTAssertFalse(WindowsNativeRoot.compiledForHost)
        XCTAssertThrowsError(try WindowsNativeRoot(localPath: "C:/contextos-missing-fixture")) {
            XCTAssertEqual($0 as? WindowsNativeError, .unavailable)
        }
        XCTAssertThrowsError(try WindowsNativeRoot.sha256(Data("abc".utf8))) {
            XCTAssertEqual($0 as? WindowsNativeError, .unavailable)
        }
        #else
        throw XCTSkip("Windows native branch is tested separately with disposable fixtures")
        #endif
    }
}

/// Requires an explicit disposable fixture prepared by check_windows.ps1.
/// No project, home directory or real agent configuration is used implicitly.
final class WindowsNativeFixtureTests: XCTestCase {
    private func fixturePath() throws -> String {
        #if os(Windows)
        guard let path = ProcessInfo.processInfo.environment["CONTEXTOS_WINDOWS_NATIVE_TEST_ROOT"],
              FileManager.default.fileExists(atPath: path + "/project/Sources/valid.swift") else {
            throw XCTSkip("Provide the disposable native fixture through check_windows.ps1")
        }
        return path
        #else
        throw XCTSkip("Requires Windows SDK execution; Mac stubs do not verify native protection")
        #endif
    }

    func testRootReadRejectsJunctionHardlinkAndBudgetOverflow() throws {
        let fixture = try fixturePath(), root = try WindowsNativeRoot(localPath: fixture + "/project")
        XCTAssertEqual(try root.read(relativePath: "Sources/valid.swift"), Data("FIXTURE_BODY\n".utf8))
        XCTAssertThrowsError(try root.read(relativePath: "junction/secret.txt"))
        XCTAssertThrowsError(try root.read(relativePath: "hardlinked.txt"))
        XCTAssertThrowsError(try WindowsNativeRoot(localPath: fixture + "/project/junction"))
        XCTAssertThrowsError(try root.read(relativePath: "Sources/valid.swift", byteLimit: 3)) {
            XCTAssertEqual($0 as? WindowsNativeError, .tooLarge)
        }
    }
    func testPrivateCreationPreservesExistingFilesAndLockExcludesAnotherHolder() throws {
        let root = try WindowsNativeRoot(localPath: try fixturePath() + "/project")
        XCTAssertThrowsError(try root.writeNewPrivateFile(name: "not-private.txt", data: Data())) {
            XCTAssertEqual($0 as? WindowsNativeError, .privateACLRequired)
        }
        let privateRoot = try root.createPrivateDirectory(name: "private-" + UUID().uuidString)
        let first = Data("FIRST_PRIVATE_BODY".utf8)
        try privateRoot.writeNewPrivateFile(name: "backup", data: first)
        XCTAssertThrowsError(try privateRoot.writeNewPrivateFile(name: "backup", data: Data("NEW".utf8))) {
            XCTAssertEqual($0 as? WindowsNativeError, .alreadyExists)
        }
        XCTAssertEqual(try privateRoot.read(relativePath: "backup"), first)
        let lock = try privateRoot.acquirePrivateLock(name: "transaction.lock")
        XCTAssertThrowsError(try privateRoot.acquirePrivateLock(name: "transaction.lock")) {
            XCTAssertEqual($0 as? WindowsNativeError, .locked)
        }
        lock.release()
        try privateRoot.acquirePrivateLock(name: "transaction.lock").release()
    }
    func testCNGHashesKnownEmptyAndABCInputs() throws {
        _ = try fixturePath()
        let vectors = [("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
                       ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")]
        for (body, expected) in vectors {
            let digest = try WindowsNativeRoot.sha256(Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, expected)
        }
    }
}
