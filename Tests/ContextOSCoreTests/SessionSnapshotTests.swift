import Foundation
import Testing
@testable import ContextOSCore

@Suite("SessionSnapshot")
struct SessionSnapshotTests {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("save/load round-trips")
    func roundTrip() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = SessionSnapshot(
            project: root.path, branch: "main",
            recentCommits: ["abc login fix"], changedFiles: ["src/auth.py"],
            rules: "Language: Python", note: "wip"
        )
        try SessionSnapshotStore.save(snapshot, projectRoot: root)
        #expect(SessionSnapshotStore.load(projectRoot: root) == snapshot)
    }

    @Test("rendered block includes the key state")
    func rendered() {
        let snapshot = SessionSnapshot(
            project: "/p/app", branch: "feature/login",
            recentCommits: ["abc123 add jwt"], changedFiles: ["src/auth.py", "src/login.py"],
            rules: "Language: Python\nFramework: FastAPI", note: "half-done"
        )
        let text = snapshot.rendered()
        #expect(text.contains("feature/login"))
        #expect(text.contains("abc123 add jwt"))
        #expect(text.contains("src/auth.py"))
        #expect(text.contains("FastAPI"))
        #expect(text.contains("half-done"))
    }
}
