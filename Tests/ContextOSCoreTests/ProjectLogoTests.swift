import Foundation
import Testing
@testable import ContextOSCore

@Suite("ProjectLogo")
struct ProjectLogoTests {

    private func project(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-logo-\(UUID().uuidString)")
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data([0x89]).write(to: url)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a conventional path wins, best first")
    func conventional() throws {
        let root = try project(["src/app/favicon.ico", "assets/icon.png", "README.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectLogo.find(in: root)?.lastPathComponent == "icon.png")
    }

    @Test("a monorepo's icon is found a few levels down, the big icon over the favicon")
    func nested() throws {
        let root = try project(["frontend/public/favicon.ico",
                                "frontend/public/apple-touch-icon.png",
                                "backend/main.py"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectLogo.find(in: root)?.lastPathComponent == "apple-touch-icon.png")
    }

    @Test("dependencies and build output are never searched")
    func skipsDependencies() throws {
        let root = try project(["node_modules/some-lib/logo.png", ".build/icon.png", "dist/favicon.ico"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectLogo.find(in: root) == nil)
    }

    @Test("an Xcode app icon set gives its largest image")
    func xcodeIconSet() throws {
        let root = try project(["App/Assets.xcassets/AppIcon.appiconset/Contents.json"])
        defer { try? FileManager.default.removeItem(at: root) }
        let set = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
        try Data(count: 10).write(to: set.appendingPathComponent("small.png"))
        try Data(count: 500).write(to: set.appendingPathComponent("large.png"))
        #expect(ProjectLogo.find(in: root)?.lastPathComponent == "large.png")
    }

    @Test("a project with no logo has none")
    func none() throws {
        let root = try project(["src/main.swift", "README.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectLogo.find(in: root) == nil)
    }
}
