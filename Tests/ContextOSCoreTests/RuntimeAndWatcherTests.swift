import XCTest
import Foundation
@testable import ContextOSCore

final class RuntimeAndWatcherTests: XCTestCase {
    func testOwnBundlePathsTakePrecedenceOverOlderInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-runtime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["new/ContextOS.app/Contents/Resources", "Applications/ContextOS.app/Contents/Resources"] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["contextos", "contextos-mcp"] {
                let file = directory.appendingPathComponent(name)
                try Data("fixture".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
        }
        let executable = root.appendingPathComponent("new/ContextOS.app/Contents/MacOS/ContextOSApp")
        let resolved = try XCTUnwrap(RuntimeBinaries.resolve(executable: executable, home: root))
        XCTAssertEqual(resolved.mcp, root.appendingPathComponent("new/ContextOS.app/Contents/Resources/contextos-mcp"))
        XCTAssertEqual(RuntimeBinaries.resolve(executable: resolved.cli, home: root), resolved)
    }

    func testWatcherIgnoresIndexRootAndNoiseButSeesIgnoreChanges() {
        let root = "/audit/project"
        for path in [".contextos", ".contextos/index.sqlite-wal", "node_modules/pkg/main.js", ".build/tmp.swift", "private.pem", ".env", "dist/main.js"] {
            XCTAssertFalse(FileWatcher.shouldReindex(path: root + "/" + path, roots: [root]), path)
        }
        for path in ["Sources/Login.swift", ".gitignore", "nested/.gitignore", ".github/workflows/ci.yml"] {
            XCTAssertTrue(FileWatcher.shouldReindex(path: root + "/" + path, roots: [root]), path)
        }
        XCTAssertFalse(FileWatcher.shouldReindex(path: root + "-other/Login.swift", roots: [root]))
        XCTAssertFalse(FileWatcher.shouldReindex(path: root + "/.build", roots: [root], isDirectory: true))
        XCTAssertTrue(FileWatcher.shouldReindex(path: root, roots: [root], isDirectory: true))
    }

    func testLiveWatcherSeesSourceWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-watch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = expectation(description: "source save reported")
        seen.assertForOverFulfill = false
        let watcher = FileWatcher(paths: [root.path], latency: 0.1) { seen.fulfill() }
        XCTAssertTrue(watcher.start())
        XCTAssertTrue(watcher.start()) // repeated start does not add another stream
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        try "func login() {}".write(to: root.appendingPathComponent("Login.swift"), atomically: true, encoding: .utf8)
        wait(for: [seen], timeout: 10)
    }
}
