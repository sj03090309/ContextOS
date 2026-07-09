import Foundation
import Testing
@testable import ContextOSCore

@Suite("ClaudeIntegration")
struct ClaudeIntegrationTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-claude-\(UUID().uuidString)")
            .appendingPathComponent("CLAUDE.md")
    }

    @Test("adds the instruction block to a new file")
    func addsBlock() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let wasUpdate = try ClaudeIntegration.installInstruction(at: url)
        #expect(!wasUpdate) // freshly added
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("get_relevant_context"))
        #expect(content.contains(ClaudeIntegration.beginMarker))
        #expect(content.contains(ClaudeIntegration.endMarker))
    }

    @Test("is idempotent — reinstalling doesn't duplicate")
    func idempotent() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try ClaudeIntegration.installInstruction(at: url)
        let wasUpdate = try ClaudeIntegration.installInstruction(at: url)
        #expect(wasUpdate) // updated existing block
        let content = try String(contentsOf: url, encoding: .utf8)
        // Exactly one block.
        #expect(content.components(separatedBy: ClaudeIntegration.beginMarker).count == 2)
    }

    @Test("preserves the user's existing content")
    func preservesExisting() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# 내 규칙\n항상 한국어로 답하기\n".write(to: url, atomically: true, encoding: .utf8)

        try ClaudeIntegration.installInstruction(at: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("항상 한국어로 답하기"))
        #expect(content.contains("get_relevant_context"))
    }

    @Test("remove strips only the block")
    func removeStripsBlock() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# 내 규칙\n".write(to: url, atomically: true, encoding: .utf8)

        try ClaudeIntegration.installInstruction(at: url)
        try ClaudeIntegration.removeInstruction(at: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("내 규칙"))
        #expect(!content.contains("get_relevant_context"))
    }
}
