import Foundation
import Testing
@testable import ContextOSCore

@Suite("ProjectRules")
struct ProjectRulesTests {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("saves and reloads rules round-trip")
    func roundTrip() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let rules = ProjectRules(language: "Python 3.12", framework: "FastAPI", style: ["PEP8"], notes: ["no prints"])
        try ProjectRulesStore.save(rules, projectRoot: root)
        #expect(ProjectRulesStore.load(projectRoot: root) == rules)
    }

    @Test("rendered block includes all set fields")
    func rendered() {
        let rules = ProjectRules(language: "Swift", framework: "SwiftUI", style: ["MVVM"], notes: ["CamelCase"])
        let text = rules.rendered()
        #expect(text.contains("Language: Swift"))
        #expect(text.contains("Framework: SwiftUI"))
        #expect(text.contains("Style: MVVM"))
        #expect(text.contains("Note: CamelCase"))
    }

    @Test("effective() infers dominant language from the index when no rules saved")
    func inferredDefault() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "def f():\n    pass\n".write(to: root.appendingPathComponent("src/a.py"), atomically: true, encoding: .utf8)
        try "def g():\n    pass\n".write(to: root.appendingPathComponent("src/b.py"), atomically: true, encoding: .utf8)

        try ContextService().ensureIndexed(projectRoot: root)
        let effective = ProjectRulesStore.effective(projectRoot: root)
        #expect(effective.language == "Python")
    }
}
