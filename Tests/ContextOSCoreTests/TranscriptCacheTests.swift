import Foundation
import Testing
@testable import ContextOSCore

@Suite("TranscriptCache")
struct TranscriptCacheTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-transcripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func claudeLine(input: Int) -> String {
        """
        {"type":"assistant","timestamp":"2026-07-01T10:00:00.000Z","cwd":"/tmp/proj","message":\
        {"usage":{"input_tokens":\(input),"cache_read_input_tokens":0,"cache_creation_input_tokens":0,\
        "output_tokens":10}}}
        """
    }

    private func setMTime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test("a transcript touched without growing is re-parsed once, then served from the cache")
    func touchedTranscriptIsWrittenBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("session.jsonl")
        let db = dir.appendingPathComponent("usage.sqlite").path
        try (claudeLine(input: 100) + "\n").write(to: log, atomically: true, encoding: .utf8)
        try setMTime(log, Date(timeIntervalSince1970: 1_800_000_000))
        let files = [(url: log, agent: "Claude Code")]

        #expect(TranscriptCache(storePath: db).snapshot(of: files).totalTokens == 110)

        // Touched: same bytes, same size, newer mtime.
        let touched = Date(timeIntervalSince1970: 1_800_000_500)
        try setMTime(log, touched)
        #expect(TranscriptCache(storePath: db).snapshot(of: files).totalTokens == 110)

        // The new mtime must have been saved. When it wasn't, the stale row sent
        // every later pass down the full re-parse path — forever.
        let row = try #require(try UsageStore(path: db).sessionCache()[log.path])
        #expect(row.mtime == touched.timeIntervalSince1970)

        // Prove the next pass trusts the row: change the content behind the
        // cache's back (same size), keep the saved mtime. A re-parse would see 910.
        try (claudeLine(input: 900) + "\n").write(to: log, atomically: true, encoding: .utf8)
        try setMTime(log, touched)
        #expect(TranscriptCache(storePath: db).snapshot(of: files).totalTokens == 110)
    }

    @Test("rows are kept in memory: an unchanged pass never re-reads the database")
    func unchangedPassUsesMemory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("session.jsonl")
        let db = dir.appendingPathComponent("usage.sqlite").path
        try (claudeLine(input: 100) + "\n").write(to: log, atomically: true, encoding: .utf8)
        // Whole seconds, so setting it again later reproduces it exactly.
        let mtime = Date(timeIntervalSince1970: 1_800_000_000)
        try setMTime(log, mtime)
        let files = [(url: log, agent: "Claude Code")]

        let cache = TranscriptCache(storePath: db)
        #expect(cache.snapshot(of: files).totalTokens == 110)

        // Same size, new content, original mtime — and no database to fall back
        // on. A pass that re-read the table would find it empty and re-parse (910);
        // one working from its rows in memory trusts the unchanged size and mtime.
        try (claudeLine(input: 900) + "\n").write(to: log, atomically: true, encoding: .utf8)
        try setMTime(log, mtime)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db + suffix) }
        #expect(cache.snapshot(of: files).totalTokens == 110)
    }

    @Test("appended lines are folded in, and a deleted transcript's row is dropped")
    func appendsAndDeletes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jsonl")
        let b = dir.appendingPathComponent("b.jsonl")
        let db = dir.appendingPathComponent("usage.sqlite").path
        try (claudeLine(input: 100) + "\n").write(to: a, atomically: true, encoding: .utf8)
        try (claudeLine(input: 200) + "\n").write(to: b, atomically: true, encoding: .utf8)
        let cache = TranscriptCache(storePath: db)
        #expect(cache.snapshot(of: [(a, "Claude Code"), (b, "Claude Code")]).totalTokens == 320)

        let handle = try FileHandle(forWritingTo: a)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((claudeLine(input: 50) + "\n").utf8))
        try handle.close()
        try setMTime(a, Date().addingTimeInterval(5))
        try FileManager.default.removeItem(at: b)

        #expect(cache.snapshot(of: [(a, "Claude Code")]).totalTokens == 170)
        let rows = try UsageStore(path: db).sessionCache()
        #expect(rows.keys.sorted() == [a.path])
        #expect(rows[a.path]?.tokens == 170)
    }
}
